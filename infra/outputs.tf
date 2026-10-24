output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "kms_key_arns" {
  description = "KMS CMK ARNs by purpose (ebs, rds, secrets)"
  value       = { for k, v in aws_kms_key.this : k => v.arn }
}

# Defined in eks.tf
output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "rds_endpoints" {
  description = "RDS endpoints by logical database name"
  value       = { for k, v in aws_db_instance.main : k => v.endpoint }
}

output "rds_master_secret_arns" {
  description = "Secrets Manager ARNs holding the RDS master credentials"
  value       = { for k, v in aws_db_instance.main : k => v.master_user_secret[0].secret_arn }
}

# Defined in ecr.tf (for_each over var.microservices)
output "ecr_repository_urls" {
  description = "ECR repository URLs by microservice"
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}