variable "environment" {
  description = "Deployment environment (prod or staging)"
  type        = string
}

variable "alb_arn" {
  description = "ARN of the ALB to associate the WAF WebACL with"
  type        = string
  default     = ""
}
