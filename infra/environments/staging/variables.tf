variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "staging"
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
  default = true
}

variable "bastion_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Admin CIDRs allowed to SSH the bastion (least privilege). Empty = no inbound SSH; use SSM Session Manager instead."
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "node_instance_type" {
  type    = string
  default = "m7i-flex.large"
}

variable "eks_min_nodes" {
  type    = number
  default = 2
}

variable "eks_max_nodes" {
  type    = number
  default = 4
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
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
  default = "30"
}

variable "github_org" {
  description = "GitHub org/username — set via TF_VAR_github_org in .env"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "CloudMart-demo"
}
