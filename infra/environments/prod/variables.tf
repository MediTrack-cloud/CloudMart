variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "team_id" {
  type    = string
  default = "group-01"
}

variable "owner_email" {
  type    = string
  default = "team@cloudmart.example"
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "bastion_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Admin CIDRs allowed to SSH the bastion (least privilege). Empty = no inbound SSH; use SSM Session Manager instead."
}

variable "github_org" {
  description = "GitHub org/username for the GitHub Actions OIDC trust policy (set via TF_VAR_github_org)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for the GitHub Actions OIDC trust policy"
  type        = string
  default     = "CloudMart-demo"
}

variable "rds_multi_az" {
  type    = bool
  default = true
}

variable "eks_min_nodes" {
  type    = number
  default = 2
}

variable "eks_max_nodes" {
  type    = number
  default = 6
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "ses_from_email" {
  type    = string
  default = ""
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = string
  default = "50"
}

# Route 53 — leave empty to skip DNS module (use ALB hostname directly)
variable "domain_name" {
  type    = string
  default = ""
}

variable "alb_dns_name" {
  type    = string
  default = ""
}

variable "alb_zone_id" {
  type    = string
  default = "Z35SXDOTRQ7X7K" # us-east-1 ALB zone
}
