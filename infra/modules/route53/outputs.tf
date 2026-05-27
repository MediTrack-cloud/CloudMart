output "health_check_id" {
  value = aws_route53_health_check.alb.id
}

output "primary_record_fqdn" {
  value = aws_route53_record.primary.fqdn
}
