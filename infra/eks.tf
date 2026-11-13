# ==============================================================================
# IAM Policies & Roles for EKS Control Plane
# ==============================================================================

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${local.name_prefix}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ==============================================================================
# EKS Cluster Control Plane
# ==============================================================================

resource "aws_eks_cluster" "main" {
  name     = local.cluster_id
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]

  lifecycle {
    # Creation-only settings that AWS does not report back. After the cluster is
    # re-imported into an empty state (scripts/recover-state.sh) Terraform would
    # see them as changed and plan to REPLACE the whole cluster. They only matter
    # when the cluster is first created, so later differences are ignored.
    ignore_changes = [
      bootstrap_self_managed_addons,
      access_config[0].bootstrap_cluster_creator_admin_permissions,
    ]
  }
}

# ==============================================================================
# EKS Access Entries (Kubernetes RBAC Access for Team IAM Principals)
# ==============================================================================

resource "aws_eks_access_entry" "team_admins" {
  for_each      = toset(var.admin_iam_arns)
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "team_admins" {
  for_each      = toset(var.admin_iam_arns)
  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.team_admins]
}

# ==============================================================================
# IAM Policies & Roles for EKS Worker Nodes
# ==============================================================================

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_nodes" {
  name               = "${local.name_prefix}-eks-nodes"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

# ==============================================================================
# EKS Managed Node Group
# ==============================================================================

resource "aws_eks_node_group" "main" {
  cluster_name = aws_eks_cluster.main.name
  # A name prefix (Terraform adds a unique suffix) together with
  # create_before_destroy below: when the node group has to be replaced, the new
  # nodes are created and Ready before the old group is drained and deleted, so
  # pods always have somewhere to run. A fixed name would force delete-then-create.
  node_group_name_prefix = "${local.name_prefix}-workers"
  node_role_arn          = aws_iam_role.eks_nodes.arn
  subnet_ids             = aws_subnet.private[*].id
  instance_types         = ["t3.medium"]
  capacity_type          = "ON_DEMAND"
  disk_size              = 50

  scaling_config {
    desired_size = 5
    min_size     = 4
    max_size     = 10
  }

  update_config {
    max_unavailable = 1
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy_attachment.eks_nodes]

  lifecycle {
    create_before_destroy = true
  }
}
