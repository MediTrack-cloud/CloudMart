data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# GuardDuty
# ---------------------------------------------------------------------------
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true
  datasources {
    s3_logs { enable = true }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes { enable = true }
      }
    }
  }
  tags = { Environment = var.environment }
}

# ---------------------------------------------------------------------------
# CloudTrail
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "cloudmart-cloudtrail-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = var.environment != "prod"
  tags          = { Name = "cloudmart-cloudtrail-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.cloudtrail]
}

resource "aws_cloudtrail" "main" {
  name                          = "cloudmart-trail-${var.environment}"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cw.arn
  tags                          = { Name = "cloudmart-trail-${var.environment}" }
  depends_on                    = [aws_s3_bucket_policy.cloudtrail]
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/cloudmart/cloudtrail/${var.environment}"
  retention_in_days = 30
}

resource "aws_iam_role" "cloudtrail_cw" {
  name = "cloudmart-cloudtrail-cw-role-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_cw" {
  role = aws_iam_role.cloudtrail_cw.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ---------------------------------------------------------------------------
# WAF v2 (attached to ALB ARN post-deploy)
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "main" {
  name  = "cloudmart-waf-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # AWS IP reputation list — blocks bots, scrapers and known malicious IPs
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 4
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Rate-limit rule: 2 000 requests per 5 min per IP
  rule {
    name     = "RateLimitPerIP"
    priority = 5
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cloudmart-waf-${var.environment}"
    sampled_requests_enabled   = true
  }

  tags = { Name = "cloudmart-waf-${var.environment}" }
}

# WAF logging to CloudWatch
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-cloudmart-${var.environment}"
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn
}

# ---------------------------------------------------------------------------
# SES email identity verification
# ---------------------------------------------------------------------------
resource "aws_ses_email_identity" "sender" {
  count = var.ses_from_email != "" ? 1 : 0
  email = var.ses_from_email
}

# ---------------------------------------------------------------------------
# GuardDuty findings → SNS → email
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "guardduty_findings" {
  name = "cloudmart-guardduty-findings-${var.environment}"
}

resource "aws_sns_topic_subscription" "guardduty_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.guardduty_findings.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "guardduty" {
  name        = "cloudmart-guardduty-findings-${var.environment}"
  description = "Forward GuardDuty HIGH/CRITICAL findings to SNS"
  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty.name
  target_id = "GuardDutySNS"
  arn       = aws_sns_topic.guardduty_findings.arn
}
