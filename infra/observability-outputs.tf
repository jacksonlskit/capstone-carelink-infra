output "loki_s3_bucket_name" {
  description = "S3 bucket used for Loki log storage"
  value       = aws_s3_bucket.loki.bucket
}

output "loki_s3_bucket_arn" {
  description = "ARN of the Loki S3 bucket"
  value       = aws_s3_bucket.loki.arn
}

output "loki_iam_role_arn" {
  description = "IAM role assumed by the Loki Kubernetes service account"
  value       = aws_iam_role.loki.arn
}
