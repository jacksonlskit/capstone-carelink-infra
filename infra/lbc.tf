# 1. Automatically grab the TLS certificate and create the OIDC provider for the current cluster
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# 2. Build the Trust Policy pointing to the brand-new daily OIDC provider
data "aws_iam_policy_document" "lbc_assume_role" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# 3. Create the IAM Role for LBC
resource "aws_iam_role" "lbc" {
  name               = "${local.name_prefix}-aws-lbc-role"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume_role.json

  tags = local.common_tags
}

# The controller's permissions, owned by this code. The role used to attach a
# shared, account-level policy (AWSLoadBalancerControllerIAMPolicy) created
# outside this repo, so anyone editing or deleting it would have broken our
# load balancers. policies/aws-lbc-iam-policy.json is the same document, now
# reviewed here and tagged, so the nightly cleanup spares it.
resource "aws_iam_policy" "lbc" {
  name        = "${local.name_prefix}-aws-lbc-policy"
  description = "AWS Load Balancer Controller permissions for ${local.name_prefix}"
  policy      = file("${path.module}/policies/aws-lbc-iam-policy.json")

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn

  # Attach the new policy before the old attachment is removed, so the
  # controller never runs without permissions during the switch.
  lifecycle {
    create_before_destroy = true
  }
}

# 4. Install the controller. It watches Ingress objects and creates the ALB for
#    them (the app repo's charts/carelink/templates/ingress.yaml). The service
#    account uses the IRSA role above.
resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.6.2"

  values = [yamlencode({
    clusterName = aws_eks_cluster.main.name
    region      = var.aws_region
    vpcId       = aws_vpc.main.id
    # The ALB, target groups and security groups are created by the controller,
    # not Terraform, so the provider's default_tags never reach them.
    defaultTags = {
      Project     = var.cohort_project_tag
      Environment = var.environment
    }
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.lbc.arn
      }
    }
  })]

  depends_on = [
    aws_iam_role_policy_attachment.lbc,
    aws_eks_node_group.main,
  ]
}
