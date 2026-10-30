variable "project" {
  description = "Project name, used as a resource name prefix"
  type        = string
  default     = "carelink"
}

variable "environment" {
  description = "Deployment environment (staging or production)"
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be 'staging' or 'production'."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

# ---------- Networking ----------
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one shared NAT (staging); false = one NAT per AZ (production)"
  type        = bool
  default     = true
}

# ---------- EKS ----------
variable "eks_cluster_version" {
  description = "EKS Kubernetes version (must be a valid AWS EKS release, e.g., 1.30 or 1.31)"
  type        = string
  default     = "1.37"
}

variable "microservices" {
  description = "List of microservice identifiers used to provision ECR repositories, IAM roles, and deployment manifests"
  type        = list(string)
  default = [
    "api-gateway",
    "customers-service",
    "vets-service",
    "visits-service"
  ]

  validation {
    condition = length(var.microservices) > 0 && alltrue([
      for service in var.microservices : can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", service))
    ])
    error_message = "Each microservice name must be non-empty, use lowercase alphanumeric characters and hyphens, and cannot start or end with a hyphen."
  }
}

# ---------- RDS ----------
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.small"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ for RDS"
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Automated backup retention in days"
  type        = number
  default     = 7
}

variable "databases" {
  description = "RDS instances to create, keyed by logical name"
  type = map(object({
    engine            = string # mysql | postgres
    engine_version    = string
    db_name           = string
    allocated_storage = number
    max_storage       = number
  }))
  default = {
    mysql = {
      engine            = "mysql"
      engine_version    = "8.0"
      db_name           = "carelink"
      allocated_storage = 20
      max_storage       = 100
    }
    postgres = {
      engine            = "postgres"
      engine_version    = "16"
      db_name           = "carelink"
      allocated_storage = 20
      max_storage       = 100
    }
  }
}

variable "tags" {
  description = "Extra tags merged into all resources"
  type        = map(string)
  default     = {}
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}
