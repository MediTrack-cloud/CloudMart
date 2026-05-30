variable "environment" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "account_id" {
  type = string
}

variable "oidc_provider_arn" {
  type = string
}

variable "oidc_provider_url" {
  type = string
}

variable "dynamodb_table_arn" {
  type = string
}

variable "sqs_queue_arn" {
  type = string
}

variable "rds_secret_arn" {
  type = string
}

variable "app_kms_key_arn" {
  type = string
}

variable "rds_kms_key_arn" {
  type    = string
  default = ""
}

variable "ses_from_email" {
  type    = string
  default = ""
}

variable "github_org" {
  description = "GitHub org/username for the GitHub Actions OIDC trust policy"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name for the GitHub Actions OIDC trust policy"
  type        = string
  default     = "CloudMart-demo"
}

variable "service_accounts" {
  description = "Map of service name to K8s service account config"
  type = map(object({
    namespace = string
    sa_name   = string
  }))
  default = {
    "product-service"      = { namespace = "cloudmart-staging", sa_name = "product-service-sa" }
    "order-service"        = { namespace = "cloudmart-staging", sa_name = "order-service-sa" }
    "notification-service" = { namespace = "cloudmart-staging", sa_name = "notification-service-sa" }
    "user-service"         = { namespace = "cloudmart-staging", sa_name = "user-service-sa" }
  }
}
