# IAM trust policy for the AWS EBS CSI driver
data "aws_iam_policy_document" "ebs_csi_assume_role" {
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
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Dedicated IAM role for the CareLink EBS CSI driver
resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = local.common_tags
}

# AWS-managed permissions required by the EBS CSI driver
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Install the AWS-managed EBS CSI driver add-on
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = "v1.68.0-eksbuild.1"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  # Disks this driver creates for PersistentVolumeClaims (Prometheus, Loki,
  # Grafana) are made outside Terraform, so they did not get default_tags. The
  # nightly cleanup deletes untagged resources; attached disks survive only
  # because AWS cannot delete them while in use, so a disk detached at night
  # (node replaced or drained) would be deleted with its data. Tag every new one.
  configuration_values = jsonencode({
    controller = {
      extraVolumeTags = { Project = var.cohort_project_tag }
    }
  })

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi
  ]

  tags = local.common_tags
}

# The setting above only tags disks created from now on. Tag the ones that
# already exist too: every disk the cluster owns, found by the tag the driver
# puts on them (no hard-coded IDs, so it also works after a rebuild). Runs on
# every apply, so it catches any disk the driver setting might miss.
data "aws_ebs_volumes" "cluster_owned" {
  tags = { "kubernetes.io/cluster/${local.cluster_id}" = "owned" }
}

resource "aws_ec2_tag" "cluster_volumes_project" {
  for_each = toset(data.aws_ebs_volumes.cluster_owned.ids)

  resource_id = each.value
  key         = "Project"
  value       = var.cohort_project_tag
}
