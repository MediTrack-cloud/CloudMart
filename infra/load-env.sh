#!/usr/bin/env bash
# Map the UPPER_CASE variables in .env -> the lower_case TF_VAR_* that Terraform
# expects, so user-specific values (emails, region, GitHub org) stay in .env and
# OUT of committed *.tfvars files. This mirrors exactly what deploy.sh exports.
#
# Usage — before a manual terraform apply (run from any infra/environments/* dir):
#     source ../../load-env.sh
#     terraform apply -var-file=terraform.tfvars
#
# Finds .env by walking up from the current directory, so it works in bash or zsh
# regardless of how it is sourced.

_d="$PWD"
while [ "$_d" != "/" ] && [ ! -f "$_d/.env" ]; do _d="$(dirname "$_d")"; done

if [ -f "$_d/.env" ]; then
  set -a            # export everything defined while sourcing
  . "$_d/.env"
  set +a
  echo "load-env.sh: sourced $_d/.env"
else
  echo "load-env.sh: WARNING — no .env found walking up from $PWD" >&2
fi

# .env UPPER_CASE  ->  TF_VAR_lower_case  (defaults mirror deploy.sh)
export TF_VAR_aws_region="${AWS_REGION:-us-east-1}"
export TF_VAR_owner_email="${OWNER_EMAIL:-team@cloudmart.example}"
export TF_VAR_alert_email="${ALERT_EMAIL:-}"
export TF_VAR_ses_from_email="${SES_FROM_EMAIL:-}"
export TF_VAR_monthly_budget_usd="${MONTHLY_BUDGET_USD:-30}"
export TF_VAR_github_org="${GITHUB_ORG:-}"
export TF_VAR_github_repo="${GITHUB_REPO:-CloudMart}"
# SES sandbox: demo order emails go to the verified recipient (defaults to sender).
export DEMO_RECIPIENT_EMAIL="${DEMO_RECIPIENT_EMAIL:-${SES_FROM_EMAIL:-}}"

echo "TF_VAR_* set: region=$TF_VAR_aws_region  ses_from_email=$TF_VAR_ses_from_email  owner=$TF_VAR_owner_email"
