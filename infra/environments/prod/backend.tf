terraform {
  backend "s3" {
    bucket         = "cloudmart-tf-state-ACCOUNT_ID"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "cloudmart-tf-lock"
    encrypt        = true
  }
}
