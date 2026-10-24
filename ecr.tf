# =============================================================================
# AMAZON ECR REPOSITORIES & LIFECYCLE POLICIES (ecr.tf)
# Private container registries for Spring PetClinic Cloud microservices
# =============================================================================

locals {
  # List of microservices required for the distributed CareLink workload
  microservices = [
    "api-gateway",
    "customers-service",
    "vets-service",
    "visits-service"
  ]
}

# -----------------------------------------------------------------------------
# 1. ECR REPOSITORIES
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "services" {
  for_each             = toset(local.microservices)
  name                 = "carelink/${each.key}"
  image_tag_mutability = "MUTABLE" # Allows commit SHA and branch tagging

  # Satisfies Phase 2 Security Gate: Scans images automatically on push
  image_scanning_configuration {
    scan_on_push = true
  }

  # Satisfies CareLink Data Protection: Enforces encryption at rest
  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = {
    Name        = "carelink-${each.key}"
    Service     = each.key
    Application = "CareLink"
    ManagedBy   = "Terraform"
  }
}

# -----------------------------------------------------------------------------
# 2. LIFECYCLE POLICIES (COST DISCIPLINE)
# -----------------------------------------------------------------------------

resource "aws_ecr_lifecycle_policy" "services_lifecycle" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        # Rule 1: Immediately clean up dangling/untagged images
        rulePriority = 1
        description  = "Remove untagged images older than 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        # Rule 2: Retain only the last 30 deployed versions to control storage costs
        rulePriority = 2
        description  = "Retain only the last 30 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-", "main-", "staging-", "prod-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# 3. OUTPUTS
# -----------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "Map of microservice names to their corresponding ECR repository URLs"
  value = {
    for k, v in aws_ecr_repository.services : k => v.repository_url
  }
}

output "ecr_repository_arns" {
  description = "Map of microservice names to their corresponding ECR repository ARNs"
  value = {
    for k, v in aws_ecr_repository.services : k => v.arn
  }
}
