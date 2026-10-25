# ==============================================================================
# Networking Outputs
# ==============================================================================

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  # Works for both count and for_each implementations
  value = try(aws_subnet.public[*].id, [for s in aws_subnet.public : s.id])
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  # Works for both count and for_each implementations
  value = try(aws_subnet.private[*].id, [for s in aws_subnet.private : s.id])
}

# ==============================================================================
# Security & Encryption (KMS)
# ==============================================================================

output "kms_key_arns" {
  description = "KMS CMK ARNs by purpose (ebs, rds, secrets)"
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

# ==============================================================================
# EKS Cluster & Workload Identity Outputs
# ==============================================================================

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "eks_cluster_security_group_id" {
  description = "Security group created by EKS to allow control plane and worker node communication"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "eks_oidc_provider_arn" {
  description = "OIDC Provider ARN used to configure IAM Roles for Service Accounts (IRSA)"
  value       = try(aws_iam_openid_connect_provider.eks[0].arn, null)
}

output "eks_oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL without https://"
  value       = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# ==============================================================================
# Database (RDS) Outputs
# ==============================================================================

output "rds_endpoints" {
  description = "RDS full connection endpoints (host:port) by logical database name"
  value       = { for k, v in aws_db_instance.main : k => v.endpoint }
}

output "rds_addresses" {
  description = "RDS hostnames (without port) by logical database name"
  value       = { for k, v in aws_db_instance.main : k => v.address }
}

output "rds_ports" {
  description = "RDS connection ports by logical database name"
  value       = { for k, v in aws_db_instance.main : k => v.port }
}

output "rds_master_secret_arns" {
  description = "Secrets Manager ARNs holding the RDS master credentials"
  value       = { for k, v in aws_db_instance.main : k => try(v.master_user_secret[0].secret_arn, null) }
}

# ==============================================================================
# Container Registry (ECR) Outputs
# ==============================================================================

output "ecr_repository_urls" {
  description = "ECR repository URLs by microservice"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}
