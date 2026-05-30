output "alerts_sns_arn" { value = aws_sns_topic.alerts.arn }
output "log_group_names" { value = { for k, v in aws_cloudwatch_log_group.services : k => v.name } }
