locals {
  services = ["product-service", "order-service", "user-service", "notification-service", "frontend"]
}

# ---------------------------------------------------------------------------
# CloudWatch Log Groups (one per service)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "services" {
  for_each          = toset(local.services)
  name              = "/cloudmart/${each.key}/${var.environment}"
  retention_in_days = var.log_retention_days
  tags              = { Service = each.key }
}

# ---------------------------------------------------------------------------
# CloudWatch Dashboard
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "cloudmart" {
  dashboard_name = "CloudMart-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "EKS Node CPU Utilization"
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", "cloudmart-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 12, y = 0, width = 12, height = 6
        properties = {
          title = "EKS Node Memory Utilization"
          view  = "timeSeries"
          metrics = [
            ["ContainerInsights", "node_memory_utilization", "ClusterName", "cloudmart-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 0, y = 6, width = 12, height = 6
        properties = {
          title = "SQS Queue Depth (Orders)"
          view  = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "cloudmart-orders-${var.environment}"],
            ["AWS/SQS", "ApproximateNumberOfMessagesNotVisible", "QueueName", "cloudmart-orders-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 12, y = 6, width = 12, height = 6
        properties = {
          title = "RDS Connections & CPU"
          view  = "timeSeries"
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "cloudmart-${var.environment}"],
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "cloudmart-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 0, y = 12, width = 24, height = 6
        properties = {
          title = "ALB Request Count & 5XX Errors"
          view  = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "app/cloudmart-${var.environment}"],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", "app/cloudmart-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Log metric filter: product-service 5xx errors
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "product_5xx" {
  name           = "cloudmart-product-service-5xx-${var.environment}"
  log_group_name = "/cloudmart/product-service/${var.environment}"
  pattern        = "[timestamp, level, service, ip, ..., status_code=5*]"

  metric_transformation {
    name          = "ProductService5xxCount"
    namespace     = "CloudMart/${var.environment}"
    value         = "1"
    default_value = "0"
  }

  depends_on = [aws_cloudwatch_log_group.services]
}

# ---------------------------------------------------------------------------
# CloudWatch Alarm: product-service error rate > 5% for 5 minutes
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "product_error_rate" {
  alarm_name          = "cloudmart-product-service-high-error-rate-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "ProductService5xxCount"
  namespace           = "CloudMart/${var.environment}"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "product-service 5xx error count > 5 for 5 consecutive minutes"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = { Service = "product-service" }
}

# ---------------------------------------------------------------------------
# SNS topic for alerts
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "cloudmart-alerts-${var.environment}"
  tags = { Name = "cloudmart-alerts-${var.environment}" }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------------------------------------------------------
# Custom metric filter: order throughput (orders placed per minute)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "order_throughput" {
  name           = "cloudmart-order-throughput-${var.environment}"
  log_group_name = "/cloudmart/order-service/${var.environment}"
  # Matches log lines emitted when an order is successfully created
  pattern = "{ $.message = \"Order created\" }"

  metric_transformation {
    name          = "OrdersPerMinute"
    namespace     = "CloudMart/${var.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }

  depends_on = [aws_cloudwatch_log_group.services]
}

# ---------------------------------------------------------------------------
# CloudWatch Logs Insights saved queries (Distinction — analytics on flow logs)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_query_definition" "rejected_traffic" {
  name = "CloudMart/VPC-FlowLogs-RejectedTraffic-${var.environment}"

  log_group_names = ["/cloudmart/vpc-flow-logs/${var.environment}"]

  query_string = <<-QUERY
    fields @timestamp, srcAddr, dstAddr, srcPort, dstPort, protocol, action
    | filter action = "REJECT"
    | stats count(*) as rejectionCount by srcAddr, dstAddr, dstPort
    | sort rejectionCount desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "top_talkers" {
  name = "CloudMart/VPC-FlowLogs-TopTalkers-${var.environment}"

  log_group_names = ["/cloudmart/vpc-flow-logs/${var.environment}"]

  query_string = <<-QUERY
    fields @timestamp, srcAddr, dstAddr, bytes
    | filter action = "ACCEPT"
    | stats sum(bytes) as totalBytes by srcAddr
    | sort totalBytes desc
    | limit 20
  QUERY
}

resource "aws_cloudwatch_query_definition" "service_errors" {
  name = "CloudMart/ServiceErrors-5xx-${var.environment}"

  log_group_names = [for s in local.services : "/cloudmart/${s}/${var.environment}"]

  query_string = <<-QUERY
    fields @timestamp, @logStream, @message
    | filter @message like /5[0-9][0-9]/
    | parse @message "* [*] *: *" as timestamp, level, service, detail
    | stats count(*) as errorCount by service, bin(5m)
    | sort errorCount desc
  QUERY
}

resource "aws_cloudwatch_query_definition" "order_throughput_query" {
  name = "CloudMart/OrderThroughput-${var.environment}"

  log_group_names = ["/cloudmart/order-service/${var.environment}"]

  query_string = <<-QUERY
    fields @timestamp, @message
    | filter @message like /Order created/
    | stats count(*) as ordersPlaced by bin(1m)
    | sort @timestamp desc
  QUERY
}

# ---------------------------------------------------------------------------
# Dashboard widget: order throughput custom metric
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "cloudmart_extended" {
  dashboard_name = "CloudMart-${var.environment}-Detailed"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        x    = 0, y = 0, width = 12, height = 6
        properties = {
          title = "Order Throughput (orders/min)"
          view  = "timeSeries"
          metrics = [
            ["CloudMart/${var.environment}", "OrdersPerMinute"]
          ]
          period = 60
          region = var.aws_region
          stat   = "Sum"
        }
      },
      {
        type = "metric"
        x    = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Product Service Error Rate"
          view  = "timeSeries"
          metrics = [
            ["CloudMart/${var.environment}", "ProductService5xxCount"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 0, y = 6, width = 12, height = 6
        properties = {
          title = "SQS Queue Depth"
          view  = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "cloudmart-orders-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      },
      {
        type = "metric"
        x    = 12, y = 6, width = 12, height = 6
        properties = {
          title = "ALB Request Count & 5XX Errors"
          view  = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", "app/cloudmart-${var.environment}"],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", "app/cloudmart-${var.environment}"]
          ]
          period = 60
          region = var.aws_region
        }
      }
    ]
  })
}
