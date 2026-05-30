#!/usr/bin/env bash
# ==============================================================================
# CloudMart — Automated Destroyer
# Usage:  ./destroy.sh -e staging        (default)
#         ./destroy.sh -e prod
#
# Destruction order (critical for avoiding orphan resources):
#   1. Delete K8s Ingress  → releases ALB, target groups, ENIs
#   2. Delete K8s namespace → removes all pods, services, PVCs
#   3. Uninstall Helm add-ons
#   4. terraform destroy   → removes EKS, VPC, RDS, SQS, DynamoDB, WAF, etc.
#   5. Empty & delete S3 buckets
#   6. terraform destroy   → removes bootstrap state bucket & lock table
#   7. Verify zero residual billing resources
# ==============================================================================
set -euo pipefail

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# ── Load .env (if present) ────────────────────────────────────────────────────
_ROOT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$_ROOT_DIR_EARLY/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$_ROOT_DIR_EARLY/.env"
  set +a
fi

# Auto-select AWS profile (fallback to cims if not set in .env or environment)
export AWS_PROFILE="${AWS_PROFILE:-cims}"
log "Using AWS_PROFILE=$AWS_PROFILE"

# ── 1  Parse arguments ───────────────────────────────────────────────────────
ENV="staging"
while getopts "e:" opt; do
  case $opt in
    e) ENV="$OPTARG" ;;
    *) die "Usage: $0 [-e staging|prod]" ;;
  esac
done
[[ "$ENV" == "staging" || "$ENV" == "prod" ]] || die "Environment must be 'staging' or 'prod'."

# ── 2  AWS identity ──────────────────────────────────────────────────────────
EXPECTED_ACCOUNT_ID="898865655202"
log "Verifying AWS credentials …"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Not authenticated. Check AWS_PROFILE ($AWS_PROFILE) or run 'aws configure'."
[[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] \
  || die "Account mismatch: resolved $ACCOUNT_ID but expected $EXPECTED_ACCOUNT_ID. Check AWS_PROFILE in .env"
AWS_REGION="${AWS_REGION:-us-east-1}"

NAMESPACE="cloudmart-$ENV"
CLUSTER="cloudmart-$ENV"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Export Terraform variables (same as deploy.sh — needed for terraform destroy)
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_github_org="${GITHUB_ORG:-cloudmart}"
export TF_VAR_github_repo="${GITHUB_REPO:-CloudMart-demo}"
export TF_VAR_alert_email="${ALERT_EMAIL:-}"
export TF_VAR_ses_from_email="${SES_FROM_EMAIL:-}"
export TF_VAR_monthly_budget_usd="${MONTHLY_BUDGET_USD:-30}"
export TF_VAR_owner_email="${OWNER_EMAIL:-team@cloudmart.example}"

log "Destroying $ENV  |  Account $ACCOUNT_ID  |  Region $AWS_REGION"

# ── 3  Kubernetes cleanup ────────────────────────────────────────────────────
if aws eks describe-cluster --name "$CLUSTER" --region "$AWS_REGION" &>/dev/null; then
  log "EKS cluster $CLUSTER found. Connecting kubectl …"
  aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"

  # 3a — Delete Ingress FIRST to release ALB / target groups / ENIs
  log "Deleting Ingress to release ALB …"
  kubectl delete ingress --all -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  # 3b — Delete LoadBalancer-type Services (if any)
  kubectl delete svc --field-selector spec.type=LoadBalancer -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  log "Waiting 120s for ALB controller to clean up AWS resources …"
  sleep 120

  # 3c — Delete the application namespace (cascades all pods, PVCs, etc.)
  log "Deleting namespace $NAMESPACE …"
  kubectl delete namespace "$NAMESPACE" --ignore-not-found=true --wait=false 2>/dev/null || true

  # 3d — Uninstall Helm releases in correct namespaces
  log "Uninstalling Helm add-ons …"
  helm uninstall aws-load-balancer-controller -n kube-system   --wait 2>/dev/null || true
  helm uninstall metrics-server               -n kube-system   --wait 2>/dev/null || true
  helm uninstall cluster-autoscaler           -n kube-system   --wait 2>/dev/null || true
  helm uninstall external-secrets             -n external-secrets --wait 2>/dev/null || true
  helm uninstall keda                         -n keda          --wait 2>/dev/null || true
  helm uninstall kyverno                      -n kyverno       --wait 2>/dev/null || true
  helm uninstall argo-rollouts                -n argo-rollouts --wait 2>/dev/null || true
  helm uninstall velero                       -n velero        --wait 2>/dev/null || true

  # 3e — Remove leftover add-on namespaces
  log "Deleting add-on namespaces …"
  kubectl delete namespace external-secrets keda kyverno argo-rollouts velero \
    --ignore-not-found=true --wait=false 2>/dev/null || true

  # 3f — Remove Kyverno CRDs, KEDA CRDs (they block terraform destroy of node groups)
  log "Cleaning up CRDs …"
  kubectl delete crd -l app.kubernetes.io/part-of=kyverno       2>/dev/null || true
  kubectl delete crd -l app.kubernetes.io/part-of=keda-operator 2>/dev/null || true

  log "Kubernetes cleanup complete."
else
  warn "EKS cluster $CLUSTER not found — skipping Kubernetes cleanup."
fi

# ── 4  Terraform destroy — environment ────────────────────────────────────────
log "Running terraform destroy for $ENV …"
STATE_BUCKET_EXISTS=false
aws s3api head-bucket --bucket "cloudmart-tf-state-$ACCOUNT_ID" 2>/dev/null && STATE_BUCKET_EXISTS=true || true

if [ "$STATE_BUCKET_EXISTS" = "false" ]; then
  warn "State bucket cloudmart-tf-state-$ACCOUNT_ID not found — Terraform state already destroyed, skipping."
elif [ -d "$ROOT_DIR/infra/environments/$ENV/.terraform" ]; then
  cd "$ROOT_DIR/infra/environments/$ENV"
  terraform destroy -auto-approve
  cd "$ROOT_DIR"
else
  warn "Terraform for $ENV was never initialised — attempting init + destroy …"
  cd "$ROOT_DIR/infra/environments/$ENV"
  terraform init -input=false \
    -backend-config="bucket=cloudmart-tf-state-$ACCOUNT_ID" \
    -backend-config="key=$ENV/terraform.tfstate" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=cloudmart-tf-lock" 2>/dev/null || true
  terraform destroy -auto-approve 2>/dev/null || warn "terraform destroy $ENV failed — continuing."
  cd "$ROOT_DIR"
fi

# ── 5  Empty and delete S3 buckets ────────────────────────────────────────────
log "Purging S3 buckets …"
for BUCKET in \
  "cloudmart-cloudtrail-$ENV-$ACCOUNT_ID" \
  "cloudmart-dr-$ENV-$ACCOUNT_ID" \
  "cloudmart-velero-$ACCOUNT_ID"; do
  if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    log "  ✕ $BUCKET"
    aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
    # Delete all object versions (for versioned buckets)
    aws s3api list-object-versions --bucket "$BUCKET" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null \
      | while read -r KEY VER; do
          [[ -n "$KEY" ]] && aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$VER" 2>/dev/null || true
        done
    aws s3api list-object-versions --bucket "$BUCKET" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null \
      | while read -r KEY VER; do
          [[ -n "$KEY" ]] && aws s3api delete-object --bucket "$BUCKET" --key "$KEY" --version-id "$VER" 2>/dev/null || true
        done
    aws s3api delete-bucket --bucket "$BUCKET" --region "$AWS_REGION" 2>/dev/null || true
  fi
done

# ── 6  Terraform destroy — bootstrap ──────────────────────────────────────────
log "Destroying bootstrap state backend …"
STATE_BUCKET="cloudmart-tf-state-$ACCOUNT_ID"
if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
  log "Emptying state bucket $STATE_BUCKET …"
  aws s3 rm "s3://$STATE_BUCKET" --recursive 2>/dev/null || true
  aws s3api list-object-versions --bucket "$STATE_BUCKET" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null \
    | while read -r KEY VER; do
        [[ -n "$KEY" ]] && aws s3api delete-object --bucket "$STATE_BUCKET" --key "$KEY" --version-id "$VER" 2>/dev/null || true
      done
  aws s3api list-object-versions --bucket "$STATE_BUCKET" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output text 2>/dev/null \
    | while read -r KEY VER; do
        [[ -n "$KEY" ]] && aws s3api delete-object --bucket "$STATE_BUCKET" --key "$KEY" --version-id "$VER" 2>/dev/null || true
      done
  cd "$ROOT_DIR/infra/bootstrap"
  terraform init -input=false 2>/dev/null || true
  terraform destroy -var="account_id=$ACCOUNT_ID" -var="aws_region=$AWS_REGION" -auto-approve 2>/dev/null || true
  cd "$ROOT_DIR"
else
  warn "State bucket $STATE_BUCKET not found — bootstrap already destroyed, skipping."
fi

# ── 7  Delete CloudWatch log groups ──────────────────────────────────────────
log "Deleting CloudMart CloudWatch log groups …"
aws logs describe-log-groups --log-group-name-prefix "/cloudmart/" --query 'logGroups[].logGroupName' --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r LG; do
    [[ -n "$LG" ]] && { log "  ✕ $LG"; aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true; }
  done
aws logs describe-log-groups --log-group-name-prefix "aws-waf-logs-cloudmart" --query 'logGroups[].logGroupName' --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r LG; do
    [[ -n "$LG" ]] && { log "  ✕ $LG"; aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true; }
  done
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/cloudmart" --query 'logGroups[].logGroupName' --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r LG; do
    [[ -n "$LG" ]] && { log "  ✕ $LG"; aws logs delete-log-group --log-group-name "$LG" 2>/dev/null || true; }
  done

# ── 8  Release Elastic IPs left by NAT ───────────────────────────────────────
log "Releasing unassociated Elastic IPs …"
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null \
  | tr '\t' '\n' | while read -r EIP; do
    [[ -n "$EIP" ]] && { log "  ✕ EIP $EIP"; aws ec2 release-address --allocation-id "$EIP" 2>/dev/null || true; }
  done

# ── 9  Verify zero residual cost resources ───────────────────────────────────
echo ""
log "══════════════════════════════════════════════════════════════"
log "  POST-DESTROY VERIFICATION"
log "══════════════════════════════════════════════════════════════"

check() {
  local label="$1" result="$2"
  if [[ -z "$result" || "$result" == "[]" || "$result" == "None" ]]; then
    printf '  \033[1;32m✓\033[0m %s\n' "$label"
  else
    printf '  \033[1;31m✗\033[0m %s → %s\n' "$label" "$result"
  fi
}

check "EKS Clusters" \
  "$(aws eks list-clusters --query 'clusters[?contains(@,`cloudmart`)]' --output text 2>/dev/null)"

check "Load Balancers" \
  "$(aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName,`cloudmart`)].LoadBalancerArn' --output text 2>/dev/null)"

check "NAT Gateways" \
  "$(aws ec2 describe-nat-gateways --filter 'Name=state,Values=available,pending' --query 'NatGateways[?Tags[?contains(Value,`cloudmart`)]].NatGatewayId' --output text 2>/dev/null)"

check "RDS Instances" \
  "$(aws rds describe-db-instances --query 'DBInstances[?contains(DBInstanceIdentifier,`cloudmart`)].DBInstanceIdentifier' --output text 2>/dev/null)"

check "ECR Repositories" \
  "$(aws ecr describe-repositories --query 'repositories[?contains(repositoryName,`cloudmart`)].repositoryName' --output text 2>/dev/null)"

check "S3 Buckets" \
  "$(aws s3api list-buckets --query 'Buckets[?contains(Name,`cloudmart`)].Name' --output text 2>/dev/null)"

check "DynamoDB Tables" \
  "$(aws dynamodb list-tables --query 'TableNames[?contains(@,`cloudmart`)]' --output text 2>/dev/null)"

echo ""
log "══════════════════════════════════════════════════════════════"
log "  DESTRUCTION COMPLETE"
log "══════════════════════════════════════════════════════════════"
