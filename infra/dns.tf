# ==============================================================================
# Public hostname and TLS certificate for the application ALB
# ------------------------------------------------------------------------------
# The ALB is not created here: the AWS Load Balancer Controller (lbc.tf) creates
# it from the app repo's Ingress. That Ingress lists this hostname under
# spec.tls.hosts, and the controller finds the matching ACM certificate by
# hostname, so no certificate ARN has to be copied between repos.
#
#   carelink-<environment>.sctp-sandbox.com  --A alias-->  ALB  -->  api-gateway
# ==============================================================================

locals {
  app_hostname = "${local.name_prefix}.${var.dns_zone_name}"

  # The A record can only point at the ALB once the Ingress has created it.
  app_alb_ready = lookup(var.app_alb_ready, var.environment, false)
}

# Shared cohort zone; teams add records named <team>-<app>.sctp-sandbox.com.
data "aws_route53_zone" "sandbox" {
  name         = var.dns_zone_name
  private_zone = false
}

# ------------------------------------------------------------------------------
# ACM certificate (DNS-validated, renewed automatically by ACM)
# ------------------------------------------------------------------------------
resource "aws_acm_certificate" "app" {
  domain_name       = local.app_hostname
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id         = data.aws_route53_zone.sandbox.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

# Waits until ACM reports the certificate as issued.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

# ------------------------------------------------------------------------------
# Hostname -> ALB
# ------------------------------------------------------------------------------
# Found by the tags the controller puts on the ALB it creates for the Ingress
# <namespace>/carelink-alb-ingress (the namespace matches the environment name).
data "aws_lb" "app_ingress" {
  count = local.app_alb_ready ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = aws_eks_cluster.main.name
    "ingress.k8s.aws/stack" = "${var.environment}/carelink-alb-ingress"
  }
}

resource "aws_route53_record" "app" {
  count = local.app_alb_ready ? 1 : 0

  zone_id = data.aws_route53_zone.sandbox.zone_id
  name    = local.app_hostname
  type    = "A"

  alias {
    name                   = "dualstack.${data.aws_lb.app_ingress[0].dns_name}"
    zone_id                = data.aws_lb.app_ingress[0].zone_id
    evaluate_target_health = true
  }
}
