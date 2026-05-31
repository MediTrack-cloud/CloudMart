# WAF v2 WebACL with AWS-managed rule groups attached to the CloudMart ALB.
# Managed rules cover OWASP Top 10, known bad inputs, and SQL injection.

resource "aws_wafv2_web_acl" "cloudmart" {
  name  = "cloudmart-waf-${var.environment}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Core rule set (OWASP Top 10 coverage)
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
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Known bad inputs (log4j, Spring4Shell, etc.)
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
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # SQL injection protection
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
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # IP reputation list (bots, scrapers, known malicious IPs)
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
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting: 2000 req/5 min per IP — protects against DDoS/brute-force
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

  tags = {
    Name = "cloudmart-waf-${var.environment}"
  }
}

# Associate WebACL with ALB only when the ALB ARN is provided
resource "aws_wafv2_web_acl_association" "cloudmart" {
  count        = var.alb_arn != "" ? 1 : 0
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.cloudmart.arn
}

# CloudWatch logging for WAF — stream sampled requests to a log group
resource "aws_cloudwatch_log_group" "waf" {
  name              = "/aws/wafv2/cloudmart-${var.environment}"
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudmart" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.cloudmart.arn
}
