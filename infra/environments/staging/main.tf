terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "cloudmart"
      Environment = var.environment
      Team        = var.team_id
      Owner       = var.owner_email
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
module "kms" {
  source      = "../../modules/kms"
  environment = var.environment
}

module "vpc" {
  source                = "../../modules/vpc"
  environment           = var.environment
  aws_region            = var.aws_region
  single_nat_gateway    = var.single_nat_gateway
  bastion_allowed_cidrs = var.bastion_allowed_cidrs
}

module "eks" {
  source                 = "../../modules/eks"
  environment            = var.environment
  aws_region             = var.aws_region
  public_subnet_ids      = module.vpc.public_subnet_ids
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  cluster_sg_id          = module.vpc.eks_nodes_sg_id
  node_instance_type     = var.node_instance_type
  eks_min_nodes          = var.eks_min_nodes
  eks_max_nodes          = var.eks_max_nodes
  eks_desired_nodes      = var.eks_min_nodes
}


module "ecr" {
  source        = "../../modules/ecr"
  environment   = var.environment
  kms_key_arn   = module.kms.app_key_arn
  node_role_arn = module.eks.node_role_arn
}

module "dynamodb" {
  source      = "../../modules/dynamodb"
  environment = var.environment
  kms_key_arn = module.kms.app_key_arn
}

module "sqs" {
  source      = "../../modules/sqs"
  environment = var.environment
  kms_key_arn = module.kms.app_key_arn
}

module "rds" {
  source                  = "../../modules/rds"
  environment             = var.environment
  private_data_subnet_ids = module.vpc.private_data_subnet_ids
  rds_sg_id               = module.vpc.rds_sg_id
  kms_key_arn             = module.kms.rds_key_arn
  db_instance_class       = var.db_instance_class
  multi_az                = var.rds_multi_az
}

module "iam" {
  source             = "../../modules/iam"
  environment        = var.environment
  aws_region         = var.aws_region
  account_id         = data.aws_caller_identity.current.account_id
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  dynamodb_table_arn = module.dynamodb.table_arn
  sqs_queue_arn      = module.sqs.queue_arn
  rds_secret_arn     = module.rds.secret_arn
  app_kms_key_arn    = module.kms.app_key_arn
  rds_kms_key_arn    = module.kms.rds_key_arn
  ses_from_email     = var.ses_from_email
  github_org         = var.github_org
  github_repo        = var.github_repo
  service_accounts = {
    "product-service"      = { namespace = "cloudmart-${var.environment}", sa_name = "product-service-sa" }
    "order-service"        = { namespace = "cloudmart-${var.environment}", sa_name = "order-service-sa" }
    "notification-service" = { namespace = "cloudmart-${var.environment}", sa_name = "notification-service-sa" }
    "user-service"         = { namespace = "cloudmart-${var.environment}", sa_name = "user-service-sa" }
  }
}

module "security" {
  source         = "../../modules/security"
  environment    = var.environment
  ses_from_email = var.ses_from_email
  alert_email    = var.alert_email
}

module "monitoring" {
  source      = "../../modules/monitoring"
  environment = var.environment
  aws_region  = var.aws_region
  alert_email = var.alert_email
}

module "s3" {
  source      = "../../modules/s3"
  environment = var.environment
}

module "budgets" {
  source             = "../../modules/budgets"
  environment        = var.environment
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
}

# ---------------------------------------------------------------------------
# Application secrets (service config stored in Secrets Manager)
# ---------------------------------------------------------------------------
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

locals {
  app_secrets = {
    "cloudmart/order-service/${var.environment}" = jsonencode({
      SQS_QUEUE_URL = module.sqs.queue_url
    })
    "cloudmart/product-service/${var.environment}" = jsonencode({
      DYNAMODB_TABLE = module.dynamodb.table_name
    })
    "cloudmart/notification-service/${var.environment}" = jsonencode({
      SQS_QUEUE_URL = module.sqs.queue_url
      FROM_EMAIL    = var.ses_from_email
    })
    "cloudmart/user-service/${var.environment}" = jsonencode({
      JWT_SECRET = random_password.jwt_secret.result
    })
  }
}

resource "aws_secretsmanager_secret" "app" {
  for_each                = local.app_secrets
  name                    = each.key
  kms_key_id              = module.kms.app_key_arn
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "app" {
  for_each      = local.app_secrets
  secret_id     = aws_secretsmanager_secret.app[each.key].id
  secret_string = each.value
}
