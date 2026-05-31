variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "private_data_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "single_nat_gateway" {
  type        = bool
  default     = false
  description = "Use a single NAT GW (staging cost saving) vs one per AZ (prod HA)"
}

variable "bastion_allowed_cidrs" {
  type        = list(string)
  default     = []
  description = "Admin/management CIDRs permitted to SSH to the bastion (least privilege). Empty = no inbound SSH (fail closed). Set to your office/VPN IP, e.g. [\"203.0.113.10/32\"]."
}
