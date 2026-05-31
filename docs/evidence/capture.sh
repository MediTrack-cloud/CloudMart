#!/usr/bin/env bash
# CloudMart — automated evidence capture (CLI-based items only).
# Screenshots (.png console views) are listed in README.md and taken by hand.
#
# Usage:
#   export ENV=prod AWS_REGION=us-east-1
#   ./docs/evidence/capture.sh
#
# Best-effort: each step prints OK/FAIL and continues so a missing tool/permission
# never aborts the whole run.

set -uo pipefail

ENV="${ENV:-prod}"
NS="cloudmart-${ENV}"
REGION="${AWS_REGION:-us-east-1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> CloudMart evidence capture  (env=$ENV  ns=$NS  region=$REGION)"
mkdir -p "$DIR"/{infra,security,cicd,observability,cost,dr}

# run <outfile> <description> <command...>
run() {
  local out="$1"; local desc="$2"; shift 2
  printf '  - %-44s' "$desc"
  if "$@" >"$out" 2>&1; then echo "OK   -> ${out#$DIR/}"; else echo "FAIL (see ${out#$DIR/})"; fi
}

# ---------------------------------------------------------------- INFRA
echo "[INFRA]"
run "$DIR/infra/EV-INFRA-01-kubectl-get-nodes.txt" "nodes"            kubectl get nodes -o wide
run "$DIR/infra/EV-INFRA-02-pods-prod.txt"         "pods ($NS)"       kubectl get pods -n "$NS" -o wide
run "$DIR/infra/EV-INFRA-04-subnets.txt"           "subnets (cli)" \
    aws ec2 describe-subnets --region "$REGION" \
      --filters Name=tag:Project,Values=cloudmart \
      --query 'Subnets[].{CIDR:CidrBlock,AZ:AvailabilityZone,Tier:Tags[?Key==`Tier`]|[0].Value}' --output table
run "$DIR/infra/EV-INFRA-05-ingress-alb.txt"       "ingress / ALB"    kubectl get ingress -n "$NS" -o wide

# DB-is-private proof: nc from here should TIME OUT (that failure IS the evidence)
RDS_EP="$(aws rds describe-db-instances --region "$REGION" \
          --db-instance-identifier "cloudmart-${ENV}" \
          --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null)"
if [ -n "${RDS_EP:-}" ] && [ "$RDS_EP" != "None" ]; then
  printf '  - %-44s' "db private (nc 5432 must fail)"
  { echo "# Probing $RDS_EP:5432 from outside the VPC — TIMEOUT/REFUSED = private (good)"; \
    nc -zv -w 5 "$RDS_EP" 5432; echo "# exit=$?"; } \
    >"$DIR/infra/EV-INFRA-06-db-private-nc.txt" 2>&1
  echo "captured -> infra/EV-INFRA-06-db-private-nc.txt"
else
  echo "  - db private (nc 5432 must fail)            SKIP (no RDS endpoint found)"
fi

# ---------------------------------------------------------------- SECURITY
echo "[SECURITY]"
run "$DIR/security/EV-SEC-01-networkpolicy.txt"    "networkpolicies"  kubectl get networkpolicy -n "$NS"
run "$DIR/security/EV-SEC-02-irsa-binding.txt"     "IRSA sa annotation" \
    kubectl get sa product-service -n "$NS" -o yaml

# GuardDuty: emit a sample finding so there is something to screenshot
DET="$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null)"
if [ -n "${DET:-}" ] && [ "$DET" != "None" ]; then
  run "$DIR/security/EV-SEC-03-guardduty-sample.txt" "guardduty sample finding" \
      aws guardduty create-sample-findings --region "$REGION" --detector-id "$DET" \
        --finding-types "UnauthorizedAccess:EKS/MaliciousIPCaller.Custom"
else
  echo "  - guardduty sample finding                  SKIP (no detector)"
fi

# ---------------------------------------------------------------- OBSERVABILITY
echo "[OBSERVABILITY]"
run "$DIR/observability/EV-OBS-00-hpa-current.txt" "hpa (snapshot)"   kubectl get hpa -n "$NS"
echo "  ! EV-OBS-01 (scaling) is interactive: run 'kubectl get hpa -n $NS -w' while load-testing (see README)."

# ---------------------------------------------------------------- COST
echo "[COST]"
ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
if [ -n "${ACCT:-}" ]; then
  run "$DIR/cost/EV-COST-02-budget.txt" "budget config" \
      aws budgets describe-budgets --account-id "$ACCT" \
        --query 'Budgets[?starts_with(BudgetName, `cloudmart`)]'
else
  echo "  - budget config                             SKIP (no credentials)"
fi

# ---------------------------------------------------------------- DR
echo "[DR]"
run "$DIR/dr/EV-DR-01-rds-backups.txt" "rds backup retention" \
    aws rds describe-db-instances --region "$REGION" \
      --db-instance-identifier "cloudmart-${ENV}" \
      --query 'DBInstances[0].{Retention:BackupRetentionPeriod,Window:PreferredBackupWindow,MultiAZ:MultiAZ}'
run "$DIR/dr/EV-DR-03-velero.txt" "velero schedule"  kubectl get schedule -n velero

echo "==> done. Now grab the console screenshots flagged .png in README.md."
