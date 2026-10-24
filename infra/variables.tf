variable "project" {
  description = "Project name, used as a resource name prefix"
  type        = string
  default     = "carelink"
}

variable "environment" {
  description = "Deployment environment"
  type        = string

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
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "microservices" {
  description = "Microservices that each get an ECR repository"
  type        = list(string)
  default     = ["service-a", "service-b", "service-c", "service-d"] # replace with real names
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