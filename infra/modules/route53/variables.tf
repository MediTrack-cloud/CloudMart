variable "environment" {
  type = string
}

variable "domain_name" {
  description = "Root domain name (e.g. cloudmart.example.com)"
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB returned by the Ingress/LB controller"
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the ALB (AWS-managed, e.g. Z35SXDOTRQ7X7K)"
  type        = string
}

variable "failover_bucket_website_endpoint" {
  description = "S3 static-website endpoint for DNS failover (error page)"
  type        = string
  default     = ""
}

variable "failover_bucket_zone_id" {
  description = "Hosted zone ID of the S3 website endpoint region"
  type        = string
  default     = "Z3AQBSTGFYJSTF" # us-east-1 S3 website zone ID
}
