environment        = "prod"
aws_region         = "us-east-1"
team_id            = "group-01"
owner_email        = "madhuraweerasooriye@gmail.com"
single_nat_gateway = false
rds_multi_az       = true

# Least privilege: set to your admin/VPN IP(s), e.g. ["203.0.113.10/32"].
# Leave empty to disable inbound SSH entirely and use SSM Session Manager.
bastion_allowed_cidrs = []
eks_min_nodes         = 2
eks_max_nodes         = 6
db_instance_class     = "db.t3.small"
monthly_budget_usd    = "50"

# Set these before applying:
alert_email    = "madhuraweerasooriye@gmail.com"
ses_from_email = "" # Set to verified SES sender email, e.g. "noreply@yourdomain.com"

# Optional — uncomment once domain is registered in Route 53:
# domain_name  = "cloudmart.yourdomain.com"
# alb_dns_name = ""  # Fill after first apply (kubectl get ingress -n cloudmart-prod)
# alb_zone_id  = "Z35SXDOTRQ7X7K"  # us-east-1 ALB zone ID
