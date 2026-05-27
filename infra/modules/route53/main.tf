# Route 53 hosted zone + health-check-based failover to a static S3 error page.
# Primary record points to the ALB; secondary record points to an S3 website
# that serves a maintenance page when the ALB health check fails.

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# Health check — monitors the ALB via HTTPS
# ---------------------------------------------------------------------------
resource "aws_route53_health_check" "alb" {
  fqdn              = var.alb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name = "cloudmart-alb-healthcheck-${var.environment}"
  }
}

# ---------------------------------------------------------------------------
# Primary record — ALB (failover = PRIMARY)
# ---------------------------------------------------------------------------
resource "aws_route53_record" "primary" {
  zone_id        = data.aws_route53_zone.main.zone_id
  name           = var.environment == "prod" ? var.domain_name : "${var.environment}.${var.domain_name}"
  type           = "A"
  set_identifier = "primary-${var.environment}"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.alb.id

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# Secondary record — S3 static error page (failover = SECONDARY)
# Activated automatically when primary health check fails.
# ---------------------------------------------------------------------------
resource "aws_route53_record" "secondary" {
  count          = var.failover_bucket_website_endpoint != "" ? 1 : 0
  zone_id        = data.aws_route53_zone.main.zone_id
  name           = var.environment == "prod" ? var.domain_name : "${var.environment}.${var.domain_name}"
  type           = "A"
  set_identifier = "secondary-${var.environment}"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = var.failover_bucket_website_endpoint
    zone_id                = var.failover_bucket_zone_id
    evaluate_target_health = false
  }
}
