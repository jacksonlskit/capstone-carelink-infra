# =============================================================================
# AMAZON EKS CLUSTER & MANAGED NODE GROUP (eks.tf)
# Production-ready EKS configuration for CareLink microservices
# =============================================================================

locals {
  cluster_name = "carelink-cluster"
}

# -----------------------------------------------------------------------------
# 1. EKS CLUSTER IAM ROLE
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "carelink-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# 2. EKS CONTROL PLANE (CareLink High Availability)
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "carelink" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.30"

  vpc_config {
    # Replace with your private subnet references (e.g., aws_subnet.private[*].id)
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # CRITICAL: Enables EKS Access Entries used by eks-access.tf
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Control plane logging for Phase 3 SRE auditability
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name        = local.cluster_name
    Environment = "production"
    Application = "CareLink"
  }
}

# -----------------------------------------------------------------------------
# 3. NODE GROUP IAM ROLE
# -----------------------------------------------------------------------------

resource "aws_iam_role" "node_group" {
  name = "carelink-eks-nodegroup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

resource "aws_iam_role_policy_attachment" "node_registry" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# -----------------------------------------------------------------------------
# 4. MANAGED NODE GROUP (Distributed across Multi-AZ Private Subnets)
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "core_nodes" {
  cluster_name    = aws_eks_cluster.carelink.name
  node_group_name = "carelink-core-nodes"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 3
    min_size     = 2
    max_size     = 6
  }

  instance_types = ["t3.medium"] # Or t4g.medium (Graviton)
  capacity_type  = "ON_DEMAND"

  update_config {
    max_unavailable = 1 # Ensures 99.9% availability during rolling node upgrades
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_registry
  ]

  tags = {
    Name        = "carelink-eks-node"
    Environment = "production"
  }
}

# -----------------------------------------------------------------------------
# 5. OUTPUTS
# -----------------------------------------------------------------------------

output "cluster_name" {
  value = aws_eks_cluster.carelink.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.carelink.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.carelink.certificate_authority[0].data
}
