# ==============================================================================
# Public hostname for the application ALB (external-dns)
# ------------------------------------------------------------------------------
# The environment is torn down every night and rebuilt from empty state, and the
# ALB is created later by the app pipeline (AWS Load Balancer Controller acting
# on the app repo's Ingress), so its DNS name is new every day. Terraform cannot
# point a record at an ALB that does not exist yet. external-dns runs in the
# cluster and keeps carelink-<environment>.sctp-sandbox.com pointed at whichever
# ALB the Ingress has today, driven by this Ingress annotation:
#
#   external-dns.alpha.kubernetes.io/hostname: carelink-<environment>.sctp-sandbox.com
#
# TLS: the ACM certificate for this hostname lives in oicd-bootstrap/main.tf,
# because ACM certificates and Route 53 records survive the nightly wipe. The
# controller finds it by hostname (the Ingress lists it under spec.tls.hosts).
# ==============================================================================

locals {
  app_hostname = "${local.name_prefix}.${var.dns_zone_name}"
}

# Shared cohort zone; teams add records named <team>-<app>.sctp-sandbox.com.
data "aws_route53_zone" "sandbox" {
  name         = var.dns_zone_name
  private_zone = false
}

# ------------------------------------------------------------------------------
# IAM role for the external-dns service account (IRSA), limited to this zone
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "external_dns_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${local.name_prefix}-external-dns-role"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid = "ChangeRecordsInSandboxZoneOnly"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResources",
    ]
    resources = [data.aws_route53_zone.sandbox.arn]
  }

  statement {
    sid       = "FindZones"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "${local.name_prefix}-external-dns"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

# ------------------------------------------------------------------------------
# external-dns
# ------------------------------------------------------------------------------
# upsert-only: creates and updates records but never deletes, which is the safe
# choice in a zone shared with other teams. It only changes records it owns,
# marked by TXT records carrying txtOwnerId (the cluster name, which stays the
# same across nightly rebuilds, so each day's cluster takes over the record).
resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.23.0"

  values = [yamlencode({
    provider      = { name = "aws" }
    policy        = "upsert-only"
    registry      = "txt"
    txtOwnerId    = aws_eks_cluster.main.name
    sources       = ["ingress"]
    domainFilters = [var.dns_zone_name]
    extraArgs = [
      "--zone-id-filter=${data.aws_route53_zone.sandbox.zone_id}",
      "--aws-zone-type=public",
    ]
    env = [{ name = "AWS_DEFAULT_REGION", value = var.aws_region }]
    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
      }
    }
  })]

  depends_on = [
    aws_iam_role_policy.external_dns,
    aws_eks_node_group.main,
  ]
}
