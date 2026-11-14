# ==============================================================================
# Application database connection (RDS MySQL)
# ------------------------------------------------------------------------------
# The customers, vets and visits services store their data in the RDS MySQL
# instance of this environment instead of an in-memory database inside each
# pod, so data is shared by all replicas and survives every pod restart.
#
# Credentials never appear in code, Git or Terraform state:
#
#   RDS-managed master secret (Secrets Manager, KMS "secrets" key, rotated by AWS)
#     --(External Secrets Operator, IAM role allowed to read only this secret)-->
#   Kubernetes Secret "carelink-db" in the app namespace (url, username, password)
#     --(secretKeyRef in the app chart)--> SPRING_DATASOURCE_* in the pods
#
# Rotation: RDS rotates the password every 7 days. External Secrets refreshes
# the Kubernetes Secret every 5 minutes and Reloader then restarts the app pods
# one at a time (PodDisruptionBudgets keep one pod per service serving).
# ==============================================================================

locals {
  app_db = aws_db_instance.main["mysql"]

  # The services' own db/mysql/schema.sql scripts use this database name.
  app_db_name = "service_instance_db"

  # sslMode=REQUIRED: the connection is always encrypted (the server also
  # refuses anything else, see aws_db_parameter_group.mysql in rds.tf).
  app_db_jdbc_url = "jdbc:mysql://${local.app_db.address}:${local.app_db.port}/${local.app_db_name}?createDatabaseIfNotExist=true&sslMode=REQUIRED"

  app_db_secret_name = "carelink-db" # referenced by the app chart
}

# ------------------------------------------------------------------------------
# IAM role for External Secrets Operator (IRSA): read the app DB secret only
# ------------------------------------------------------------------------------
data "aws_iam_policy_document" "external_secrets_assume_role" {
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
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${local.name_prefix}-external-secrets-role"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid     = "ReadAppDatabaseAndGrafanaSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.app_db.master_user_secret[0].secret_arn,
    "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.observability.account_id}:secret:${local.name_prefix}-grafana-admin-*"]
  }

  statement {
    sid       = "DecryptItThroughSecretsManagerOnly"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this["secrets"].arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${local.name_prefix}-external-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# ------------------------------------------------------------------------------
# External Secrets Operator
# ------------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.15.0"

  values = [yamlencode({
    installCRDs = true
    serviceAccount = {
      name = "external-secrets" # must match the IAM trust policy above
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets.arn
      }
    }
  })]

  depends_on = [
    aws_iam_role_policy.external_secrets,
    aws_eks_node_group.main,
  ]
}

# ------------------------------------------------------------------------------
# Reloader: restart the app pods when the DB secret changes (password rotation)
# ------------------------------------------------------------------------------
resource "helm_release" "reloader" {
  name       = "reloader"
  namespace  = "kube-system"
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = "2.2.20"

  values = [yamlencode({
    reloader = {
      # Restart by bumping an annotation on the pod template. The default
      # strategy adds an env var, which Argo CD would see as drift from Git.
      reloadStrategy = "annotations"
    }
  })]

  depends_on = [aws_eks_node_group.main]
}

# ------------------------------------------------------------------------------
# The "carelink-db" Secret in the app namespace
# ------------------------------------------------------------------------------
# Applied with the generic charts/manifests chart: these are External Secrets
# custom resources, whose CRDs only exist once the operator above is installed.
resource "helm_release" "app_database" {
  name             = "app-database"
  namespace        = var.environment # the namespace Argo CD deploys the app into
  create_namespace = true
  chart            = "${path.module}/charts/manifests"

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1"
        kind       = "ClusterSecretStore"
        metadata   = { name = "aws-secrets-manager" }
        spec = {
          # No auth block: the operator uses its own IAM role (IRSA) above.
          provider = {
            aws = {
              service = "SecretsManager"
              region  = var.aws_region
            }
          }
        }
      },
      {
        apiVersion = "external-secrets.io/v1"
        kind       = "ExternalSecret"
        metadata = {
          name      = local.app_db_secret_name
          namespace = var.environment
        }
        spec = {
          refreshInterval = "5m"
          secretStoreRef = {
            kind = "ClusterSecretStore"
            name = "aws-secrets-manager"
          }
          target = {
            name           = local.app_db_secret_name
            creationPolicy = "Owner"
            template = {
              engineVersion = "v2"
              data = {
                # Not secret, kept next to the credentials so the app chart
                # needs no environment-specific database settings.
                url      = local.app_db_jdbc_url
                username = "{{ .username }}"
                password = "{{ .password }}"
              }
            }
          }
          data = [
            for key in ["username", "password"] : {
              secretKey = key
              remoteRef = {
                key      = local.app_db.master_user_secret[0].secret_arn
                property = key
              }
            }
          ]
        }
      },
    ]
  })]

  depends_on = [helm_release.external_secrets]
}

output "app_database_endpoint" {
  description = "RDS MySQL endpoint the app connects to (TLS required)"
  value       = "${local.app_db.address}:${local.app_db.port}/${local.app_db_name}"
}
