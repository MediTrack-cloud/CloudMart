# ── Infrastructure config (not user-specific, safe to commit) ──────────────
environment        = "staging"
team_id            = "group-01"
single_nat_gateway = true
rds_multi_az       = false
node_instance_type = "m7i-flex.large"
eks_min_nodes      = 2
eks_max_nodes      = 4
db_instance_class  = "db.t3.micro"

# ── User-specific values come from .env → TF_VAR_ (do NOT add them here) ──
# aws_region, owner_email, alert_email, ses_from_email,
# monthly_budget_usd, github_org, github_repo
