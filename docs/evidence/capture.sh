#!/usr/bin/env bash
# CloudMart — automated evidence capture (CLI-based items only).
# Every output file embeds the exact command that produced it, so you can
# re-run any capture yourself at any time. Screenshots (.png) are listed in
# README.md and taken by hand.
#
# Usage:
#   export AWS_PROFILE=cims ENV=prod AWS_REGION=us-east-1
#   ./docs/evidence/capture.sh

set -uo pipefail

ENV="${ENV:-prod}"
NS="cloudmart-${ENV}"
REGION="${AWS_REGION:-us-east-1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"

echo "==> CloudMart evidence capture  (env=$ENV  ns=$NS  region=$REGION)"
mkdir -p "$DIR"/{infra,security,cicd,observability,cost,dr}

# emit <outfile> <title> <command-string>
# Writes a header (title + the exact command) then runs the command and appends output.
emit() {
  local out="$1" title="$2" cmd="$3"
  {
    echo "# ──────────────────────────────────────────────────────────────────"
    echo "# $title"
    echo "#"
    echo "# Command (re-run any time with: export AWS_PROFILE=cims AWS_REGION=$REGION):"
    printf '%s\n' "$cmd" | sed 's/^/#   /'
    echo "#"
    echo "# Captured: $(date -u '+%Y-%m-%d %H:%M:%SZ')   account=$ACCT  env=$ENV"
    echo "# ──────────────────────────────────────────────────────────────────"
    echo ""
    eval "$cmd"
  } > "$out" 2>&1
  printf '  %-44s -> %s\n' "$title" "${out#"$DIR"/}"
}

# ──────────────────────────────────────────────────────────────── INFRA
echo "[INFRA]"
emit "$DIR/infra/EV-INFRA-01-kubectl-get-nodes.txt" "EV-INFRA-01  Cluster nodes (2+ Ready)" \
  "kubectl get nodes -o wide"

emit "$DIR/infra/EV-INFRA-02-pods-prod.txt" "EV-INFRA-02  Pods in $NS" \
  "kubectl get pods -n $NS -o wide"

emit "$DIR/infra/EV-INFRA-04-subnets.txt" "EV-INFRA-04  Three-tier subnets across 2 AZ" \
  "aws ec2 describe-subnets --region $REGION --filters Name=tag:Project,Values=cloudmart --query 'sort_by(Subnets,&AvailabilityZone)[].{Name:Tags[?Key==\`Name\`]|[0].Value,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table"

emit "$DIR/infra/EV-INFRA-05-ingress-alb.txt" "EV-INFRA-05  Frontend Ingress / ALB" \
  "kubectl get ingress -n $NS -o wide"

emit "$DIR/infra/EV-INFRA-06-db-private-nc.txt" "EV-INFRA-06  RDS not reachable from internet (timeout = private)" \
  "nc -zv -w 5 \$(aws rds describe-db-instances --region $REGION --db-instance-identifier cloudmart-$ENV --query 'DBInstances[0].Endpoint.Address' --output text) 5432"

# ──────────────────────────────────────────────────────────────── SECURITY
echo "[SECURITY]"
emit "$DIR/security/EV-SEC-01-networkpolicy.txt" "EV-SEC-01  NetworkPolicies (default-deny + allows)" \
  "kubectl get networkpolicy -n $NS"

emit "$DIR/security/EV-SEC-02-irsa-binding.txt" "EV-SEC-02  Per-service IRSA role bindings" \
  "kubectl get sa -n $NS -o custom-columns='SERVICEACCOUNT:.metadata.name,IRSA_ROLE_ARN:.metadata.annotations.eks\.amazonaws\.com/role-arn'"

# GuardDuty: generate a sample finding then list current findings
DET="$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text 2>/dev/null)"
if [ -n "${DET:-}" ] && [ "$DET" != "None" ]; then
  aws guardduty create-sample-findings --region "$REGION" --detector-id "$DET" \
    --finding-types "Recon:EC2/PortProbeUnprotectedPort" "UnauthorizedAccess:EC2/SSHBruteForce" >/dev/null 2>&1
  sleep 5
  emit "$DIR/security/EV-SEC-03-guardduty-finding.txt" "EV-SEC-03  GuardDuty active findings (detector $DET)" \
    "aws guardduty get-findings --region $REGION --detector-id $DET --finding-ids \$(aws guardduty list-findings --region $REGION --detector-id $DET --max-results 10 --query 'FindingIds' --output text) --query 'Findings[].{Severity:Severity,Type:Type,Title:Title}' --output table"
else
  echo "  EV-SEC-03  GuardDuty                          SKIP (no detector)"
fi

# ──────────────────────────────────────────────────────────────── OBSERVABILITY
echo "[OBSERVABILITY]"
emit "$DIR/observability/EV-OBS-00-hpa-current.txt" "EV-OBS-00  HPA targets (60% CPU, 2-6)" \
  "kubectl get hpa -n $NS"
echo "  ! EV-OBS-01 (scaling under load) is interactive — see README (hey + kubectl get hpa -w)."

# ──────────────────────────────────────────────────────────────── COST
echo "[COST]"
if [ -n "${ACCT:-}" ]; then
  emit "$DIR/cost/EV-COST-02-budget.txt" "EV-COST-02  Monthly budget + alert (filter Environment=prod)" \
    "aws budgets describe-budget --account-id $ACCT --budget-name cloudmart-monthly-$ENV --query 'Budget.{Name:BudgetName,Limit:BudgetLimit,Filter:CostFilters,TimeUnit:TimeUnit}' --output json"
else
  echo "  EV-COST-02  budget                           SKIP (no credentials)"
fi

# ──────────────────────────────────────────────────────────────── DR
echo "[DR]"
emit "$DIR/dr/EV-DR-01-rds-backups.txt" "EV-DR-01  RDS automated backups (7-day) + Multi-AZ" \
  "aws rds describe-db-instances --region $REGION --db-instance-identifier cloudmart-$ENV --query 'DBInstances[0].{BackupRetentionDays:BackupRetentionPeriod,BackupWindow:PreferredBackupWindow,MultiAZ:MultiAZ,Encrypted:StorageEncrypted}' --output json"

emit "$DIR/dr/EV-DR-03-velero.txt" "EV-DR-03  Velero backup schedule" \
  "kubectl get schedule -n velero"

echo "==> done. Console screenshots (.png) are listed in README.md."
