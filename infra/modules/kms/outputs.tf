output "rds_key_arn" { value = aws_kms_key.rds.arn }
output "rds_key_id" { value = aws_kms_key.rds.key_id }
output "app_key_arn" { value = aws_kms_key.app.arn }
output "app_key_id" { value = aws_kms_key.app.key_id }
