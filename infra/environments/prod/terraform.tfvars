# ── Infrastructure config (env-specific, safe to commit) ───────────────────
environment        = "prod"
team_id            = "group-01"
single_nat_gateway = false # HA: one NAT gateway per AZ in prod
rds_multi_az       = true  # prod RDS Multi-AZ automatic failover

# Least privilege: set to your admin/VPN IP(s), e.g. ["203.0.113.10/32"].
# Leave empty to disable inbound SSH entirely and use SSM Session Manager.
bastion_allowed_cidrs = []
eks_min_nodes         = 2
eks_max_nodes         = 6
db_instance_class     = "db.t3.small"
monthly_budget_usd    = "50"

# ── User-specific values come from .env → TF_VAR_ (do NOT hardcode here) ────
# aws_region, owner_email, alert_email, ses_from_email, github_org, github_repo
#   • via ./deploy.sh -e prod   (exports them automatically), or
#   • for a manual `terraform apply`, first:  source ../../load-env.sh
# SES stays in sandbox: ses_from_email + the demo recipient must be verified.

# Optional — uncomment once a domain is registered in Route 53:
# domain_name  = "cloudmart.yourdomain.com"
# alb_dns_name = ""                 # fill after first apply (kubectl get ingress -n cloudmart-prod)
# alb_zone_id  = "Z35SXDOTRQ7X7K"   # us-east-1 ALB zone ID
