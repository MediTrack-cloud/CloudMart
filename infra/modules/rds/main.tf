resource "aws_db_subnet_group" "main" {
  name       = "cloudmart-rds-subnet-group-${var.environment}"
  subnet_ids = var.private_data_subnet_ids
  tags       = { Name = "cloudmart-rds-subnet-group-${var.environment}" }
}

resource "aws_db_parameter_group" "postgres" {
  name   = "cloudmart-postgres15-${var.environment}"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+[]{}:,.?"
}

resource "aws_db_instance" "postgres" {
  identifier              = "cloudmart-${var.environment}"
  engine                  = "postgres"
  engine_version          = "15"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  max_allocated_storage   = 100
  storage_type            = "gp2"
  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn
  db_name                 = "cloudmart"
  username                = "cloudmartadmin"
  password                = random_password.db_password.result
  db_subnet_group_name    = aws_db_subnet_group.main.name
  vpc_security_group_ids  = [var.rds_sg_id]
  parameter_group_name    = aws_db_parameter_group.postgres.name
  # Backup retention: 7 days for prod, disabled for staging to save cost
  backup_retention_period = var.environment == "prod" ? 7 : 0
  backup_window           = "02:00-03:00"
  maintenance_window      = "Mon:03:00-Mon:04:00"
  multi_az                = var.multi_az
  deletion_protection     = var.environment == "prod"
  skip_final_snapshot     = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "cloudmart-prod-final-snapshot" : null
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "cloudmart-postgres-${var.environment}" }
}

# Store DB connection URL in Secrets Manager
resource "aws_secretsmanager_secret" "db_url" {
  name                    = "cloudmart/rds/user-service/${var.environment}"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 0
  description             = "PostgreSQL connection URL for CloudMart user-service (${var.environment})"
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id = aws_secretsmanager_secret.db_url.id
  secret_string = jsonencode({
    DATABASE_URL = "postgresql://${aws_db_instance.postgres.username}:${random_password.db_password.result}@${aws_db_instance.postgres.endpoint}/${aws_db_instance.postgres.db_name}"
    DB_HOST      = aws_db_instance.postgres.address
    DB_PORT      = tostring(aws_db_instance.postgres.port)
    DB_NAME      = aws_db_instance.postgres.db_name
    DB_USER      = aws_db_instance.postgres.username
    DB_PASSWORD  = random_password.db_password.result
  })
}
