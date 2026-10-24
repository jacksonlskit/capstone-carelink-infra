data "aws_caller_identity" "current" {}

locals {
  kms_keys = {
    ebs     = "EBS volume encryption (EKS nodes)"
    rds     = "RDS storage, backups and snapshots"
    secrets = "Secrets Manager / Kubernetes secrets"
  }
}

data "aws_iam_policy_document" "kms" {
  for_each = local.kms_keys

  statement {
    sid       = "EnableRootAccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # EC2 Auto Scaling must use the EBS key for encrypted node volumes
  dynamic "statement" {
    for_each = each.key == "ebs" ? [1] : []

    content {
      sid = "AllowAutoScalingServiceLinkedRole"
      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = local.kms_keys

  description             = "${local.name_prefix} - ${each.value}"
  enable_key_rotation     = true
  deletion_window_in_days = var.environment == "production" ? 30 : 7
  policy                  = data.aws_iam_policy_document.kms[each.key].json

  tags = { Name = "${local.name_prefix}-${each.key}" }
}

resource "aws_kms_alias" "this" {
  for_each = local.kms_keys

  name          = "alias/${local.name_prefix}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}