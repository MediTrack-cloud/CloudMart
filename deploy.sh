#!/usr/bin/env bash
# ==============================================================================
# CloudMart — Automated Deployer
# Usage:  ./deploy.sh -e staging        (default)
#         ./deploy.sh -e prod
# ==============================================================================
set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$1"; exit 1; }

# Portable sed -i  (macOS ships BSD sed which requires '' after -i)
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── 1  Load .env (if present) ────────────────────────────────────────────────
ROOT_DIR_EARLY="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$ROOT_DIR_EARLY/.env" ]; then
  log "Loading .env …"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR_EARLY/.env"
  set +a
fi

# Auto-select AWS profile (fallback to cims if not set in .env or environment)
export AWS_PROFILE="${AWS_PROFILE:-cims}"
log "Using AWS_PROFILE=$AWS_PROFILE"

# ── 2  Parse arguments ───────────────────────────────────────────────────────
ENV="staging"
while getopts "e:" opt; do
  case $opt in
    e) ENV="$OPTARG" ;;
    *) die "Usage: $0 [-e staging|prod]" ;;
  esac
done
[[ "$ENV" == "staging" || "$ENV" == "prod" ]] || die "Environment must be 'staging' or 'prod'."

# ── 2  AWS identity (resolved dynamically — nothing hardcoded) ───────────────
log "Verifying AWS credentials …"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
  || die "Not authenticated. Check AWS_PROFILE ($AWS_PROFILE) or run 'aws configure'."
# Optional guard: set EXPECTED_ACCOUNT_ID in .env to prevent deploying to the wrong
# account. Unset = deploy to whichever account the credentials resolve to.
if [[ -n "${EXPECTED_ACCOUNT_ID:-}" && "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  die "Account mismatch: resolved $ACCOUNT_ID but EXPECTED_ACCOUNT_ID=$EXPECTED_ACCOUNT_ID."
fi
AWS_REGION="${AWS_REGION:-us-east-1}"
log "Account $ACCOUNT_ID  |  Region $AWS_REGION  |  Env $ENV"

NAMESPACE="cloudmart-$ENV"
CLUSTER="cloudmart-$ENV"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"     # Always resolve to repo root

# Non-destructive build: placeholder substitution and Terraform-output injection
# happen on a throwaway COPY of k8s/, so the tracked source files are never
# mutated (they stay as ACCOUNT_ID / __REGION__ placeholders in git).
K8S_DIR="$(mktemp -d)/k8s"
cp -R "$ROOT_DIR/k8s" "$K8S_DIR"
trap 'rm -rf "$(dirname "$K8S_DIR")"' EXIT
log "Rendering manifests into throwaway build dir: $K8S_DIR"

# ── Export Terraform variables from .env ────────────────────────────────────
[[ -n "${GITHUB_ORG:-}" ]] || die "GITHUB_ORG is required. Set it in .env (see .env.example)."
export TF_VAR_aws_region="$AWS_REGION"
export TF_VAR_github_org="${GITHUB_ORG}"
export TF_VAR_github_repo="${GITHUB_REPO:-CloudMart-demo}"
export TF_VAR_alert_email="${ALERT_EMAIL:-}"
export TF_VAR_ses_from_email="${SES_FROM_EMAIL:-}"
export TF_VAR_monthly_budget_usd="${MONTHLY_BUDGET_USD:-30}"
export TF_VAR_owner_email="${OWNER_EMAIL:-team@cloudmart.example}"
# SES sandbox: route demo order emails to your verified address (defaults to the sender).
export DEMO_RECIPIENT_EMAIL="${DEMO_RECIPIENT_EMAIL:-${SES_FROM_EMAIL:-}}"

# ── SES sandbox: ensure sender + demo recipient are verified identities ──────
# SES silently rejects mail to/from unverified addresses while in sandbox.
# verify-email-identity is idempotent; the user must click the link once per address.
_ses_addrs="${TF_VAR_ses_from_email}"
[ -n "$DEMO_RECIPIENT_EMAIL" ] && [ "$DEMO_RECIPIENT_EMAIL" != "$TF_VAR_ses_from_email" ] \
  && _ses_addrs="$_ses_addrs $DEMO_RECIPIENT_EMAIL"
for _addr in $_ses_addrs; do
  [ -n "$_addr" ] || continue
  _status=$(aws ses get-identity-verification-attributes --identities "$_addr" \
    --region "$AWS_REGION" \
    --query "VerificationAttributes.\"$_addr\".VerificationStatus" --output text 2>/dev/null || echo None)
  if [ "$_status" = "Success" ]; then
    log "SES identity '$_addr' already verified."
  else
    aws ses verify-email-identity --email-address "$_addr" --region "$AWS_REGION" 2>/dev/null || true
    warn "SES identity '$_addr' is not verified ($_status). A verification email was sent — CLICK THE LINK (check inbox/spam). Mail won't send until you do."
  fi
done

# ── 3  Substitute ACCOUNT_ID + __REGION__ placeholders in kustomize manifests ─
log "Substituting ACCOUNT_ID=$ACCOUNT_ID, region=$AWS_REGION, env=$ENV in k8s/ manifests …"
find "$K8S_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) -not -path '*/helm/*' | while read -r f; do
  sedi -e "s/ACCOUNT_ID/$ACCOUNT_ID/g" -e "s/__REGION__/$AWS_REGION/g" -e "s/__ENV__/$ENV/g" "$f"
done
# Inject demo email recipient (SES sandbox sends only to verified addresses).
sedi "s|__DEMO_RECIPIENT__|${DEMO_RECIPIENT_EMAIL}|g" "$K8S_DIR/base/configmap.yaml"
log "Placeholder substitution complete."

# ── 4  Bootstrap — Terraform remote state ────────────────────────────────────
log "Bootstrapping Terraform remote-state backend …"
cd "$ROOT_DIR/infra/bootstrap"
terraform init -input=false
terraform apply \
  -var="account_id=$ACCOUNT_ID" \
  -var="aws_region=$AWS_REGION" \
  -auto-approve

# ── 5  Provision environment infrastructure ──────────────────────────────────
log "Provisioning infrastructure for $ENV  (EKS + VPC + RDS + DynamoDB + SQS + KMS + WAF + …)"
cd "$ROOT_DIR/infra/environments/$ENV"
terraform init -input=false \
  -backend-config="bucket=cloudmart-tf-state-$ACCOUNT_ID" \
  -backend-config="key=$ENV/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=cloudmart-tf-lock"

terraform apply -auto-approve
log "Terraform apply complete."

# Extract outputs that downstream steps need
CLUSTER_NAME=$(terraform output -raw cluster_name)
LB_ROLE_ARN=$(terraform output -raw lb_controller_role)
AS_ROLE_ARN=$(terraform output -raw cluster_autoscaler_role)
ES_ROLE_ARN=$(terraform output -raw external_secrets_role)
GH_ROLE_ARN=$(terraform output -raw github_actions_role)
WAF_ARN=$(terraform output -raw waf_arn)
VELERO_ROLE_ARN=$(terraform output -raw velero_role_arn)
XRAY_ROLE_ARN=$(terraform output -raw xray_role_arn)
KEDA_ROLE_ARN=$(terraform output -raw keda_operator_role_arn)
SQS_URL=$(terraform output -raw sqs_queue_url)
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:Project,Values=cloudmart" "Name=tag:Environment,Values=$ENV" \
  --query 'Vpcs[0].VpcId' --output text)

cd "$ROOT_DIR"

# ── 6  Patch Ingress: ensure an ACM cert exists and inject it for HTTPS ──────
INGRESS_FILE="$K8S_DIR/base/frontend/ingress.yaml"
SELF_SIGNED_CERT_NAME="cloudmart-selfsigned-$ENV"
if [[ -z "${ACM_CERT_ARN:-}" ]]; then
  # Reuse a previously-imported self-signed cert if present (tag-matched)
  ACM_CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
    --query "CertificateSummaryList[?contains(DomainName, 'cloudmart') || contains(DomainName, 'elb.amazonaws.com')].CertificateArn" \
    --output text | tr '\t' '\n' | while read -r arn; do
      [[ -z "$arn" ]] && continue
      name=$(aws acm list-tags-for-certificate --region "$AWS_REGION" --certificate-arn "$arn" \
        --query "Tags[?Key=='Name'].Value | [0]" --output text 2>/dev/null)
      [[ "$name" == "$SELF_SIGNED_CERT_NAME" ]] && { echo "$arn"; break; }
    done)
  if [[ -z "$ACM_CERT_ARN" ]]; then
    warn "ACM_CERT_ARN not set — generating a self-signed cert and importing to ACM."
    warn "Browsers will show a 'Not Secure' warning. Set ACM_CERT_ARN in .env to use a real cert."
    CERT_DIR=$(mktemp -d)
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
      -keyout "$CERT_DIR/tls.key" -out "$CERT_DIR/tls.crt" \
      -subj "/CN=cloudmart-demo/O=CloudMart/C=US" \
      -addext "subjectAltName=DNS:*.$AWS_REGION.elb.amazonaws.com,DNS:*.elb.amazonaws.com,DNS:cloudmart-demo,DNS:localhost" \
      >/dev/null 2>&1
    ACM_CERT_ARN=$(aws acm import-certificate --region "$AWS_REGION" \
      --certificate "fileb://$CERT_DIR/tls.crt" \
      --private-key "fileb://$CERT_DIR/tls.key" \
      --tags "Key=Name,Value=$SELF_SIGNED_CERT_NAME" "Key=Environment,Value=$ENV" "Key=ManagedBy,Value=deploy-sh" \
      --query CertificateArn --output text)
    rm -rf "$CERT_DIR"
    log "  Imported self-signed cert: $ACM_CERT_ARN"
  else
    log "  Reusing existing self-signed cert: $ACM_CERT_ARN"
  fi
else
  log "Using user-provided ACM_CERT_ARN for HTTPS."
fi
log "Injecting ACM certificate ARN into Ingress …"
sedi "s|arn:aws:acm:[^:]*:[^:]*:certificate/CERT_ID|$ACM_CERT_ARN|g" "$INGRESS_FILE"

# Inject real WAF ARN
sedi "s|arn:aws:wafv2:[^:]*:[^:]*:regional/webacl/cloudmart-waf-ENV/WAF_ID|$WAF_ARN|g" "$INGRESS_FILE"
# Remove host matching so the ALB responds on any hostname
sedi "s|host: cloudmart.example|# host: (removed — using ALB DNS)|" "$INGRESS_FILE"
sedi '/external-dns.alpha.kubernetes.io/d' "$INGRESS_FILE"

# ── 7  Inject dynamic role ARNs into Helm values & manifests ─────────────────
log "Injecting Terraform‐generated role ARNs into Helm value files …"
sedi "s|arn:aws:iam::$ACCOUNT_ID:role/cloudmart-lb-controller-role-.*|$LB_ROLE_ARN|" \
  "$K8S_DIR/helm-values/aws-load-balancer-controller.yaml"
sedi "s|arn:aws:iam::$ACCOUNT_ID:role/cloudmart-cluster-autoscaler-role-.*|$AS_ROLE_ARN|" \
  "$K8S_DIR/helm-values/cluster-autoscaler.yaml"
sedi "s|arn:aws:iam::$ACCOUNT_ID:role/cloudmart-external-secrets-role-.*|$ES_ROLE_ARN|" \
  "$K8S_DIR/helm-values/external-secrets.yaml"
sedi "s|arn:aws:iam::$ACCOUNT_ID:role/cloudmart-velero-role-.*|$VELERO_ROLE_ARN|" \
  "$K8S_DIR/velero/velero-values.yaml"
sedi "s|arn:aws:iam::$ACCOUNT_ID:role/cloudmart-xray-role-.*|$XRAY_ROLE_ARN|" \
  "$K8S_DIR/xray/xray-daemon-daemonset.yaml"

# Patch cluster name in Helm value files for current environment
sedi "s/clusterName: cloudmart-.*/clusterName: $CLUSTER_NAME/" \
  "$K8S_DIR/helm-values/aws-load-balancer-controller.yaml"

# Patch velero bucket name
sedi "s|cloudmart-velero-.*$ACCOUNT_ID|cloudmart-velero-$ACCOUNT_ID|" \
  "$K8S_DIR/velero/velero-values.yaml"

# Patch KEDA SQS URL
KEDA_FILE="$K8S_DIR/keda/notification-service-scaledobject-staging.yaml"
if [[ "$ENV" == "prod" ]]; then
  KEDA_FILE="$K8S_DIR/keda/notification-service-scaledobject.yaml"
fi
sedi "s|https://sqs\.[^.]*\.amazonaws\.com/.*|$SQS_URL\"|" "$KEDA_FILE"

# ── 8  Connect kubectl ───────────────────────────────────────────────────────
log "Connecting kubectl to EKS cluster $CLUSTER_NAME …"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# ── 9  Helm add-on installation ──────────────────────────────────────────────
log "Adding Helm repositories …"
helm repo add eks            https://aws.github.io/eks-charts              2>/dev/null || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io          2>/dev/null || true
helm repo add kedacore       https://kedacore.github.io/charts             2>/dev/null || true
helm repo add kyverno        https://kyverno.github.io/kyverno/            2>/dev/null || true
helm repo add autoscaler     https://kubernetes.github.io/autoscaler       2>/dev/null || true
helm repo add vmware-tanzu   https://vmware-tanzu.github.io/helm-charts    2>/dev/null || true
helm repo update

log "Installing Helm charts …"

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system --wait \
  --set clusterName="$CLUSTER_NAME" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=$LB_ROLE_ARN" \
  --set replicaCount=2

helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait \
  -f "$K8S_DIR/helm-values/metrics-server.yaml"

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --wait \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-secrets-sa \
  --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=$ES_ROLE_ARN"

helm upgrade --install keda kedacore/keda \
  -n keda --create-namespace --wait \
  -f "$K8S_DIR/helm-values/keda.yaml"

# Annotate KEDA operator SA with IRSA role for SQS queue-depth polling
kubectl annotate serviceaccount keda-operator -n keda \
  "eks.amazonaws.com/role-arn=$KEDA_ROLE_ARN" --overwrite
kubectl rollout restart deployment/keda-operator -n keda

helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace --wait \
  -f "$K8S_DIR/helm-values/kyverno.yaml"

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system --wait \
  --set "autoDiscovery.clusterName=$CLUSTER_NAME" \
  --set "awsRegion=$AWS_REGION" \
  --set "rbac.serviceAccount.create=true" \
  --set "rbac.serviceAccount.name=cluster-autoscaler" \
  --set "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=$AS_ROLE_ARN"

helm upgrade --install velero vmware-tanzu/velero \
  -n velero --create-namespace --wait \
  -f "$K8S_DIR/velero/velero-values.yaml" || warn "Velero install skipped (non-fatal)."

# ── 10  Apply Kubernetes manifests ───────────────────────────────────────────
log "Applying Kyverno cluster policies …"
kubectl apply -f "$K8S_DIR/security/"

log "Applying X-Ray daemon …"
kubectl apply -f "$K8S_DIR/xray/"

log "Applying Kustomize overlay ($ENV) …"
kustomize build --load-restrictor LoadRestrictionsNone "$K8S_DIR/overlays/$ENV" | kubectl apply -f -

# Force ESO to pull the latest Secrets Manager values NOW (refreshInterval is 1h, so a
# changed value — e.g. ses_from_email — would otherwise lag), then wait for the synced
# k8s Secrets to exist before the app pods need them (avoids CreateContainerConfigError).
log "Syncing External Secrets from Secrets Manager …"
kubectl annotate externalsecret --all -n "$NAMESPACE" "force-sync=$(date +%s)" --overwrite 2>/dev/null || true
kubectl wait --for=condition=Ready externalsecret --all -n "$NAMESPACE" --timeout=180s \
  || warn "Some ExternalSecrets not Ready after 180s — check 'kubectl get externalsecret -n $NAMESPACE'."

log "Applying KEDA ScaledObject …"
kubectl apply -f "$KEDA_FILE"

# ── 11  Build and push Docker images to ECR ──────────────────────────────────
log "Logging into Amazon ECR …"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS \
    --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Immutable tag — defaults to the pinned release the manifests reference (v1.0.0).
# Override with IMAGE_TAG=<git-sha> to push a specific build; never uses :latest.
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo 1.0.0)}"
log "Building and pushing 5 microservice images (tag: $IMAGE_TAG) …"
for SVC in product-service order-service user-service notification-service frontend; do
  IMG="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudmart/$SVC:$IMAGE_TAG"
  log "  → $SVC"
  docker build -q --platform linux/amd64 -t "$IMG" "$ROOT_DIR/services/$SVC"
  # Retry the push — ECR pushes occasionally hit transient TLS handshake timeouts.
  pushed=false
  for attempt in 1 2 3 4 5; do
    if docker push "$IMG"; then pushed=true; break; fi
    warn "  push of $SVC failed (attempt $attempt/5) — retrying in 8s …"; sleep 8
  done
  [[ "$pushed" == true ]] || die "Failed to push $SVC after 5 attempts."
done

# Pin the running workloads to the immutable tag just pushed.
log "Pinning overlay images to tag $IMAGE_TAG …"
ECR="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/cloudmart"
( cd "$K8S_DIR/overlays/$ENV" && \
  for SVC in product-service order-service user-service notification-service frontend; do
    kustomize edit set image "$ECR/$SVC=$ECR/$SVC:$IMAGE_TAG" 2>/dev/null || true
  done )
kustomize build --load-restrictor LoadRestrictionsNone "$K8S_DIR/overlays/$ENV" | kubectl apply -f -

# ── 12  Restart deployments ──────────────────────────────────────────────────
log "Rolling restart to pick up new images …"
kubectl rollout restart deployment -n "$NAMESPACE" 2>/dev/null || true

# ── 12b Seed DynamoDB products table (idempotent — only writes if not present) ─
DYNAMO_TABLE=$(cd "$ROOT_DIR/infra/environments/$ENV" && terraform output -raw dynamodb_table_name 2>/dev/null || echo "cloudmart-products-$ENV")
log "Seeding DynamoDB table $DYNAMO_TABLE with initial product catalogue …"
aws dynamodb batch-write-item --region "$AWS_REGION" --request-items "{
  \"$DYNAMO_TABLE\": [
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-001\"},\"name\":{\"S\":\"Wireless Bluetooth Headphones\"},\"description\":{\"S\":\"Premium noise-cancelling over-ear headphones with 30-hour battery life\"},\"price\":{\"N\":\"79.99\"},\"category\":{\"S\":\"electronics\"},\"stock\":{\"N\":\"150\"},\"imageUrl\":{\"S\":\"/images/headphones.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}},
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-002\"},\"name\":{\"S\":\"Organic Ceylon Tea (100 bags)\"},\"description\":{\"S\":\"Premium hand-picked Ceylon black tea from Nuwara Eliya estates\"},\"price\":{\"N\":\"12.99\"},\"category\":{\"S\":\"food\"},\"stock\":{\"N\":\"500\"},\"imageUrl\":{\"S\":\"/images/ceylon-tea.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}},
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-003\"},\"name\":{\"S\":\"USB-C Laptop Stand\"},\"description\":{\"S\":\"Adjustable aluminium stand with integrated USB-C hub\"},\"price\":{\"N\":\"49.99\"},\"category\":{\"S\":\"electronics\"},\"stock\":{\"N\":\"75\"},\"imageUrl\":{\"S\":\"/images/laptop-stand.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}},
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-004\"},\"name\":{\"S\":\"Handloom Cotton Sarong\"},\"description\":{\"S\":\"Traditional Sri Lankan handloom sarong, 100% cotton, machine washable\"},\"price\":{\"N\":\"24.99\"},\"category\":{\"S\":\"clothing\"},\"stock\":{\"N\":\"200\"},\"imageUrl\":{\"S\":\"/images/sarong.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}},
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-005\"},\"name\":{\"S\":\"Mechanical Keyboard (TKL)\"},\"description\":{\"S\":\"Tenkeyless keyboard with Cherry MX Brown switches, RGB backlight\"},\"price\":{\"N\":\"89.99\"},\"category\":{\"S\":\"electronics\"},\"stock\":{\"N\":\"60\"},\"imageUrl\":{\"S\":\"/images/keyboard.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}},
    {\"PutRequest\":{\"Item\":{\"id\":{\"S\":\"prod-006\"},\"name\":{\"S\":\"Coconut Oil (Cold Pressed, 500ml)\"},\"description\":{\"S\":\"Virgin cold-pressed coconut oil from Southern Province, Sri Lanka\"},\"price\":{\"N\":\"8.99\"},\"category\":{\"S\":\"food\"},\"stock\":{\"N\":\"300\"},\"imageUrl\":{\"S\":\"/images/coconut-oil.jpg\"},\"createdAt\":{\"S\":\"2025-01-15T10:00:00Z\"}}}}
  ]
}" 2>/dev/null && log "Products seeded." || warn "DynamoDB seed skipped (non-fatal)."

# ── 13  Summary ──────────────────────────────────────────────────────────────
echo ""
log "══════════════════════════════════════════════════════════════"
log "  DEPLOYMENT COMPLETE"
log "══════════════════════════════════════════════════════════════"
log "  Cluster:   $CLUSTER_NAME"
log "  Namespace: $NAMESPACE"
log "  Region:    $AWS_REGION"
log ""
log "  GitHub Actions Role ARN (set as AWS_ROLE_ARN secret):"
log "    $GH_ROLE_ARN"
log ""
log "  Wait ~2 min for the ALB to provision, then run:"
log "    kubectl get ingress cloudmart-ingress -n $NAMESPACE"
log "══════════════════════════════════════════════════════════════"
