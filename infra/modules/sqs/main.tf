resource "aws_sqs_queue" "orders_dlq" {
  name                      = "cloudmart-orders-dlq-${var.environment}"
  kms_master_key_id         = var.kms_key_arn
  message_retention_seconds = 1209600  # 14 days
  tags = { Name = "cloudmart-orders-dlq-${var.environment}" }
}

resource "aws_sqs_queue" "orders" {
  name                       = "cloudmart-orders-${var.environment}"
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400  # 1 day
  receive_wait_time_seconds  = 20     # long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 5
  })

  tags = { Name = "cloudmart-orders-${var.environment}" }
}

resource "aws_sqs_queue_policy" "orders" {
  queue_url = aws_sqs_queue.orders.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = { AWS = "*" }
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.orders.arn
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}
