output "queue_url" { value = aws_sqs_queue.orders.id }
output "queue_arn" { value = aws_sqs_queue.orders.arn }
output "queue_name" { value = aws_sqs_queue.orders.name }
output "dlq_arn" { value = aws_sqs_queue.orders_dlq.arn }
