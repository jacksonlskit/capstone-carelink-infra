terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = local.aws_region

  # The nightly cleanup skips resources tagged with the team's exact value
  # (case-sensitive). Most important here: the Terraform state bucket.
  default_tags {
    tags = {
      Project = "capstone-project-group-03"
    }
  }
}

provider "github" {
  owner = local.github_owner
}

# -----------------------------------------------------------------------------
# LOCALS & DATA SOURCES
# -----------------------------------------------------------------------------

locals {
  github_owner = "jacksonlskit"
  repo_infra   = "capstone-carelink-infra"
  repo_app     = "capstone-carelink-app"
  aws_region   = "us-east-1"
  oidc_url     = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

data "github_user" "current" {
  username = local.github_owner
}

# -----------------------------------------------------------------------------
# OIDC IDENTITY PROVIDER
# -----------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = local.oidc_url
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]
}

# -----------------------------------------------------------------------------
# OIDC TRUST POLICY: ONE ROLE PER GITHUB ENVIRONMENT
# -----------------------------------------------------------------------------
# Both repositories use GitHub's immutable OIDC subject, which names the owner
# and repository by their numeric IDs (a renamed or re-created repository gets
# a new ID and cannot take over the role):
#   repo:<owner>@<owner id>/<repo>@<repo id>:environment:<environment>
#
# Each role trusts only jobs that run in ITS GitHub environment of these two
# repositories, matched exactly (no wildcards):
#   - staging role:    jobs with `environment: staging`
#   - production role: jobs with `environment: production`, which wait for the
#     required reviewer's approval before they start
# So staging can never act as production, a job without an environment (e.g.
# a feature-branch push) gets no AWS access, and no other repository can use
# either role. Every job that needs AWS runs in an environment (ci.yaml,
# cd.yaml, sre-health-check.yaml in infra; cd.yaml in app).

data "github_repository" "infra" {
  full_name = "${local.github_owner}/${local.repo_infra}"
}

data "github_repository" "app" {
  full_name = "${local.github_owner}/${local.repo_app}"
}

locals {
  oidc_subject_prefixes = [
    "repo:${local.github_owner}@${data.github_user.current.id}/${local.repo_infra}@${data.github_repository.infra.repo_id}",
    "repo:${local.github_owner}@${data.github_user.current.id}/${local.repo_app}@${data.github_repository.app.repo_id}",
  ]
}

data "aws_iam_policy_document" "github_oidc_trust" {
  for_each = toset(["staging", "production"])

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for prefix in local.oidc_subject_prefixes : "${prefix}:environment:${each.key}"]
    }
  }
}

# -----------------------------------------------------------------------------
# 1. S3 BACKEND STORAGE (NATIVE S3 LOCKFILE - NO DYNAMODB)
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket        = "carelink-infra-state-${local.aws_region}-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state_versioning" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state_crypto" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state_block_public" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# 1b. ONLY THE PIPELINES MAY CHANGE THE SHARED STATE
# -----------------------------------------------------------------------------
# Every change to staging and production goes through the reviewed pipeline.
# Before Terraform changes anything it writes a lock file into this bucket
# (<env>/terraform.tfstate.tflock), so denying writes here stops a
# `terraform apply` from a laptop before it touches AWS. Reading stays
# allowed, so a local `terraform plan -lock=false` still works.
#
# Who may still write:
#   - each GitHub pipeline role, but only its own environment's state
#   - AWSNukeAdminRole, the course's nightly cleanup (not ours to block)
#   - anyone in var.state_break_glass_principal_arns (empty by default)
#
# Break-glass, e.g. `terraform force-unlock` after a cancelled pipeline run:
#   terraform apply -var='state_break_glass_principal_arns=["<your IAM ARN>"]'
#   ...fix the state...
#   terraform apply   # removes the exception again
#
# This is a guard rail against accidents: an account admin can still remove
# the policy (CloudTrail records it) and the next bootstrap apply restores it.

variable "state_break_glass_principal_arns" {
  description = "IAM principals temporarily allowed to write the Terraform state (break-glass only). Keep empty."
  type        = list(string)
  default     = []
}

locals {
  state_write_actions = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
  cleanup_role_arn    = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/AWSNukeAdminRole"
}

data "aws_iam_policy_document" "tf_state" {
  statement {
    sid       = "OnlyThePipelinesWriteState"
    effect    = "Deny"
    actions   = local.state_write_actions
    resources = ["${aws_s3_bucket.tf_state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values = concat(
        [aws_iam_role.staging.arn, aws_iam_role.production.arn, local.cleanup_role_arn],
        var.state_break_glass_principal_arns,
      )
    }
  }

  statement {
    sid       = "StagingPipelineCannotWriteProductionState"
    effect    = "Deny"
    actions   = local.state_write_actions
    resources = ["${aws_s3_bucket.tf_state.arn}/production/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.staging.arn]
    }
  }

  statement {
    sid       = "ProductionPipelineCannotWriteStagingState"
    effect    = "Deny"
    actions   = local.state_write_actions
    resources = ["${aws_s3_bucket.tf_state.arn}/staging/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.production.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  policy = data.aws_iam_policy_document.tf_state.json

  # S3 rejects a policy change while the public access block is being updated.
  depends_on = [aws_s3_bucket_public_access_block.tf_state_block_public]
}

# -----------------------------------------------------------------------------
# 2. ENVIRONMENT-BASED IAM ROLES & POLICIES
# -----------------------------------------------------------------------------

# Staging IAM Role
resource "aws_iam_role" "staging" {
  name               = "carelink-github-staging-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust["staging"].json
}

resource "aws_iam_role_policy_attachment" "staging_admin" {
  role       = aws_iam_role.staging.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Production IAM Role
resource "aws_iam_role" "production" {
  name               = "carelink-github-production-role"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust["production"].json
}

resource "aws_iam_role_policy_attachment" "production_admin" {
  role       = aws_iam_role.production.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# 3. GITHUB ENVIRONMENTS (STAGING & PRODUCTION)
# -----------------------------------------------------------------------------

# Infra Repo Environments
resource "github_repository_environment" "infra_staging" {
  repository  = local.repo_infra
  environment = "staging"
}

resource "github_repository_environment" "infra_production" {
  repository  = local.repo_infra
  environment = "production"

  reviewers {
    users = [data.github_user.current.id]
  }
}

# App Repo Environments
resource "github_repository_environment" "app_staging" {
  repository  = local.repo_app
  environment = "staging"
}

resource "github_repository_environment" "app_production" {
  repository  = local.repo_app
  environment = "production"

  reviewers {
    users = [data.github_user.current.id]
  }

  # Only runs from main may use this environment (policy below). A workflow
  # written on a feature branch can then never reach production credentials or
  # the env/production deploy key, and is never even offered for approval.
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "app_production_main" {
  repository     = local.repo_app
  environment    = github_repository_environment.app_production.environment
  branch_pattern = "main"
}

# -----------------------------------------------------------------------------
# 4. ENVIRONMENT-SCOPED VARIABLES (AWS_ROLE_ARN AUTO-SELECTION)
# -----------------------------------------------------------------------------

# Infra Repo Environment Variables
resource "github_actions_environment_variable" "infra_staging_role" {
  repository    = local.repo_infra
  environment   = github_repository_environment.infra_staging.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.staging.arn
}

resource "github_actions_environment_variable" "infra_production_role" {
  repository    = local.repo_infra
  environment   = github_repository_environment.infra_production.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.production.arn
}

# App Repo Environment Variables
resource "github_actions_environment_variable" "app_staging_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_staging.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.staging.arn
}

resource "github_actions_environment_variable" "app_production_role" {
  repository    = local.repo_app
  environment   = github_repository_environment.app_production.environment
  variable_name = "AWS_ROLE_ARN"
  value         = aws_iam_role.production.arn
}

# -----------------------------------------------------------------------------
# 5. GLOBAL REPOSITORY VARIABLES
# -----------------------------------------------------------------------------

# App Repo Variables
resource "github_actions_variable" "app_aws_region" {
  repository    = local.repo_app
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

# Infra Repo Variables
resource "github_actions_variable" "infra_aws_region" {
  repository    = local.repo_infra
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

resource "github_actions_variable" "infra_state_bucket" {
  repository    = local.repo_infra
  variable_name = "TF_STATE_BUCKET"
  value         = aws_s3_bucket.tf_state.bucket
}

# -----------------------------------------------------------------------------
# 6. GITHUB BRANCH PROTECTION RULESETS
# -----------------------------------------------------------------------------

resource "github_repository_ruleset" "app_main_protection" {
  name        = "app-main-protection"
  repository  = local.repo_app
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 1
      dismiss_stale_reviews_on_push   = true
      # Someone other than the last pusher must approve, so new code pushed
      # after an approval cannot be merged unreviewed (same as the infra repo).
      require_last_push_approval = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      required_check {
        context = "build"
      }
    }
  }
}

# env/production is what Argo CD deploys to production, so only the approved
# production job may write it:
#   1. A write-access deploy key on the app repository (below). Its private half
#      exists only as the secret ENV_PRODUCTION_DEPLOY_KEY of the app's
#      production environment, which GitHub hands to a job only after the
#      required reviewer approves it, and only for runs from main (above).
#      The private key is never in this state or in Git: it was generated on
#      the DevOps owner's machine, stored with `gh secret set`, then deleted.
#   2. A ruleset that blocks creating, updating, deleting or force-pushing
#      env/production for everyone, admins and the pipeline's GITHUB_TOKEN
#      included, except deploy keys (bypass actor DeployKey). Only a repository
#      admin can add a deploy key, and this is the only one.
# Why a deploy key and not the GitHub Actions app: on a personal-account
# repository GitHub refuses an app as a bypass actor (422 on 21 Nov 2026,
# "Actor GitHub Actions integration must be part of the ruleset source or
# owner organization"); a deploy key belongs to the repository itself, and a
# disabled test ruleset proved it is accepted (22 Nov 2026).
# env/staging stays open on purpose: staging has no approval step to protect.
# Rotate the key: new key pair, replace the .pub file, `gh secret set` again,
# apply (the deploy key is replaced, the old private key stops working).
resource "github_repository_deploy_key" "app_env_production" {
  repository = local.repo_app
  title      = "carelink-cd-env-production (cd.yaml production job only)"
  key        = trimspace(file("${path.module}/keys/app-env-production-deploy-key.pub"))
  read_only  = false
}

resource "github_repository_ruleset" "app_env_production_lock" {
  name        = "app-env-production-lock"
  repository  = local.repo_app
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/env/production"]
      exclude = []
    }
  }

  bypass_actors {
    actor_type  = "DeployKey"
    bypass_mode = "always"
  }

  rules {
    creation         = true
    update           = true
    deletion         = true
    non_fast_forward = true
  }
}

resource "github_repository_ruleset" "infra_main_protection" {
  name        = "infra-main-protection"
  repository  = local.repo_infra
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 1
      dismiss_stale_reviews_on_push   = true
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      required_check {
        context = "Terraform Plan (staging)"
      }
      required_check {
        context = "Terraform Plan (production)"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# 5. APP TLS CERTIFICATES (ACM, DNS-validated)
# -----------------------------------------------------------------------------
# These live here and not in infra/ because the nightly wipe deletes the
# environments (EKS, RDS, VPC) and empties the infra state bucket, but leaves
# ACM certificates and Route 53 records in place. This layer's state is kept
# between days, so Terraform keeps managing the same certificate instead of
# creating a duplicate every morning (and recreates it if it is ever removed).
#
# The ALB Ingress lists the hostname under spec.tls.hosts and the AWS Load
# Balancer Controller finds the certificate by that hostname. The hostname's
# A record is written by external-dns in each cluster (infra/dns.tf).

locals {
  app_dns_zone = "sctp-sandbox.com"
  app_hostnames = {
    staging    = "carelink-staging.${local.app_dns_zone}"
    production = "carelink-production.${local.app_dns_zone}"
  }
}

data "aws_route53_zone" "sandbox" {
  name         = local.app_dns_zone
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  for_each = local.app_hostnames

  domain_name       = each.value
  validation_method = "DNS"
  key_algorithm     = "RSA_2048"

  # Project comes from the provider's default_tags; setting it here would override it.
  tags = {
    Environment = each.key
    ManagedBy   = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = aws_acm_certificate.app

  zone_id         = data.aws_route53_zone.sandbox.zone_id
  name            = one(each.value.domain_validation_options).resource_record_name
  type            = one(each.value.domain_validation_options).resource_record_type
  records         = [one(each.value.domain_validation_options).resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  for_each = aws_acm_certificate.app

  certificate_arn         = each.value.arn
  validation_record_fqdns = [aws_route53_record.app_cert_validation[each.key].fqdn]
}


# -----------------------------------------------------------------------------
# OUTPUTS
# -----------------------------------------------------------------------------

output "tf_state_bucket_name" {
  description = "The name of the S3 bucket configured for Terraform native state locking"
  value       = aws_s3_bucket.tf_state.bucket
}

output "staging_role_arn" {
  description = "IAM Role ARN for Staging environment workflows"
  value       = aws_iam_role.staging.arn
}

output "production_role_arn" {
  description = "IAM Role ARN for Production environment workflows"
  value       = aws_iam_role.production.arn
}

output "app_certificate_arns" {
  description = "ACM certificate ARNs per environment for the app ALB (found by hostname by the Load Balancer Controller)"
  value       = { for env, v in aws_acm_certificate_validation.app : env => v.certificate_arn }
}
