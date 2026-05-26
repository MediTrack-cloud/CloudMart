output "web_acl_arn" {
  description = "ARN of the WAF WebACL — use in ALB annotations and Ingress"
  value       = aws_wafv2_web_acl.cloudmart.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.cloudmart.id
}
