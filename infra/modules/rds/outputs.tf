output "db_endpoint" { value = aws_db_instance.postgres.endpoint }
output "db_address" { value = aws_db_instance.postgres.address }
output "db_name" { value = aws_db_instance.postgres.db_name }
output "secret_arn" { value = aws_secretsmanager_secret.db_url.arn }
output "secret_name" { value = aws_secretsmanager_secret.db_url.name }
