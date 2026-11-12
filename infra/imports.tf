# ==============================================================================
# One-time imports (staging only)
# ------------------------------------------------------------------------------
# These resources were first created by hand in staging on 2026-11-11 to get the
# ALB and HTTPS working. The import blocks bring them under Terraform without
# recreating them. Production has none of them yet, so Terraform creates them
# there normally.
#
# After the first successful staging apply these blocks do nothing and can be
# deleted.
# ==============================================================================

locals {
  staging_imports = var.environment == "staging" ? toset(["staging"]) : toset([])
}

import {
  for_each = local.staging_imports
  to       = helm_release.lbc
  id       = "kube-system/aws-load-balancer-controller"
}

import {
  for_each = local.staging_imports
  to       = aws_acm_certificate.app
  id       = "arn:aws:acm:us-east-1:255945442255:certificate/3bf70414-faaa-4bf3-a9d5-d6b2cf6837e6"
}

import {
  for_each = local.staging_imports
  to       = aws_route53_record.app_cert_validation["carelink-staging.sctp-sandbox.com"]
  id       = "Z00541411T1NGPV97B5C0__068dfc17cab6cc7e32ee1a54357cefdb.carelink-staging.sctp-sandbox.com_CNAME"
}

import {
  for_each = local.staging_imports
  to       = aws_route53_record.app[0]
  id       = "Z00541411T1NGPV97B5C0_carelink-staging.sctp-sandbox.com_A"
}
