# ==============================================================================
# Argo CD (GitOps delivery of the application)
# ------------------------------------------------------------------------------
# Argo CD runs in each cluster and keeps the app namespace (staging or
# production) in sync with the app repo's Helm chart on the branch
# env/<environment>. The app pipeline (app repo .github/workflows/cd.yaml)
# builds the images and then commits the chart plus the new image tag to that
# branch; it never runs kubectl apply.
#
#   main (PR + review) --CI build/scan--> ECR
#          |
#          +--cd.yaml--> env/staging    --Argo CD--> staging cluster
#                    \--> env/production --Argo CD--> production cluster
#                         (GitHub environment "production" requires approval)
#
# Both Argo CD and its Application are installed here, so after a nightly
# rebuild the app comes back on its own: Argo CD syncs whatever env/<env>
# last recorded, without re-running the app pipeline.
#
# The Argo CD UI (ADR 0010, runbook docs/sre/runbooks/argocd-sso.md): with
# argocd_sso_enabled it is served at https://carelink-<env>-argocd.sctp-sandbox.com
# on its own ALB, sign-in is GitHub only (members of argocd_github_org, through
# Dex), and the local admin login is off. Roles come from the member's GitHub
# team (argocd_team_roles): in production only the DevOps owner is admin and the
# rest of the team is read-only. Without it, the UI is reached with
#   kubectl -n argocd port-forward svc/argocd-server 8443:443
# and the admin password from the Secret argocd-initial-admin-secret.
# ==============================================================================

variable "app_repo_url" {
  description = "Public Git repository that holds the app Helm chart (charts/carelink) and the env/<environment> deploy branches"
  type        = string
  default     = "https://github.com/jacksonlskit/capstone-carelink-app.git"
}

variable "observability_repo_url" {
  description = "Public Git repository (this one) whose observability/ folder holds the staging monitoring stack that Argo CD deploys"
  type        = string
  default     = "https://github.com/jacksonlskit/capstone-carelink-infra.git"
}

variable "argocd_sso_enabled" {
  description = "Serve the Argo CD UI on its own internet-facing ALB with GitHub sign-in (Dex) and turn the local admin login off (ADR 0010). Set per environment by the pipelines (TF_VAR_argocd_sso_enabled): staging first, then production."
  type        = bool
  default     = false
}

variable "argocd_github_org" {
  description = "GitHub organization whose members may sign in to Argo CD. Its teams and members are managed in oicd-bootstrap/main.tf."
  type        = string
  default     = "carelink-group03"
}

variable "argocd_team_roles" {
  description = <<-EOT
    Argo CD role for each GitHub team of argocd_github_org, per environment. A
    team reaches Argo CD as the group "<org>:<team>". Production admin stays with
    the DevOps owner, so production only changes through Git and the approved
    pipeline; the rest of the team can view apps, diffs and logs but cannot
    sync, roll back or delete. A signed-in user in no listed team sees nothing
    (policy.default is empty).
  EOT
  type = map(object({
    admin    = list(string)
    readonly = list(string)
  }))
  default = {
    staging = {
      admin    = ["devops", "team"]
      readonly = []
    }
    production = {
      admin    = ["devops"]
      readonly = ["team"]
    }
  }

  validation {
    condition     = alltrue([for env in ["staging", "production"] : contains(keys(var.argocd_team_roles), env)])
    error_message = "argocd_team_roles needs an entry for both staging and production."
  }
}

locals {
  argocd_app_name = "carelink-${var.environment}"

  # ---- Argo CD UI with GitHub sign-in (only used when argocd_sso_enabled) -----
  argocd_hostname = "${local.name_prefix}-argocd.${var.dns_zone_name}" # certificate in oicd-bootstrap/main.tf

  # Kubernetes Secret that External Secrets fills from Secrets Manager. Argo CD
  # resolves "$<secret>:<key>" in dex.config only for Secrets labelled
  # app.kubernetes.io/part-of: argocd.
  argocd_oauth_k8s_secret = "argocd-dex-github"

  argocd_rbac_policy = join("\n", concat(
    [for team in var.argocd_team_roles[var.environment].admin : "g, ${var.argocd_github_org}:${team}, role:admin"],
    [for team in var.argocd_team_roles[var.environment].readonly : "g, ${var.argocd_github_org}:${team}, role:readonly"],
  ))

  # Helm merges this over the base values below.
  argocd_sso_values = {
    # Sets the url in argocd-cm, which Dex needs for the sign-in callback
    # (https://<host>/api/dex/callback, registered in the GitHub OAuth App).
    global = { domain = local.argocd_hostname }

    dex = { enabled = true }

    configs = {
      # TLS ends at the ALB; the ALB talks plain HTTP to argocd-server inside the VPC.
      params = { "server.insecure" = true }

      cm = {
        # GitHub sign-in only: no shared password, nothing to guess on the public page.
        "admin.enabled" = false
        "dex.config" = yamlencode({
          connectors = [{
            type = "github"
            id   = "github"
            name = "GitHub"
            config = {
              # "$<secret>:<key>": Argo CD reads the value from that Secret.
              # (format, because "$${" would be HCL's escape for a literal "${".)
              clientID     = format("$%s:clientID", local.argocd_oauth_k8s_secret)
              clientSecret = format("$%s:clientSecret", local.argocd_oauth_k8s_secret)
              # Only members of this organization can sign in; their teams
              # arrive as groups "<org>:<team slug>".
              orgs          = [{ name = var.argocd_github_org }]
              teamNameField = "slug"
              useLoginAsID  = true
            }
          }]
        })
      }

      rbac = {
        "policy.default" = ""
        "policy.csv"     = local.argocd_rbac_policy
        scopes           = "[groups]"
      }
    }

    server = {
      ingress = {
        enabled          = true
        controller       = "generic"
        ingressClassName = "alb"
        # Same pattern as the app Ingress (app repo charts/carelink), but its own
        # ALB: no group.name, so the app's ALB is not touched.
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/listen-ports"     = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
          "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
          "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
          "alb.ingress.kubernetes.io/success-codes"    = "200"
          # The nightly cleanup skips resources with the team's Project tag.
          "alb.ingress.kubernetes.io/tags" = "Project=${var.cohort_project_tag},Environment=${var.environment}"
          # Git webhooks are not used (Argo CD polls Git), so the unauthenticated
          # webhook endpoint answers 404 at the ALB instead of reaching Argo CD.
          "alb.ingress.kubernetes.io/actions.block-webhook" = jsonencode({
            type                = "fixed-response"
            fixedResponseConfig = { contentType = "text/plain", statusCode = "404", messageBody = "Not found" }
          })
          # external-dns (dns.tf) points the hostname at this ALB.
          "external-dns.alpha.kubernetes.io/hostname" = local.argocd_hostname
        }
        # Listed before the main "/" path, so the ALB checks it first.
        extraPaths = [{
          path     = "/api/webhook"
          pathType = "Exact"
          backend  = { service = { name = "block-webhook", port = { name = "use-annotation" } } }
        }]
        # No secretName: the Load Balancer Controller finds the ACM certificate
        # by this hostname.
        extraTls = [{ hosts = [local.argocd_hostname] }]
      }
    }
  }

  # The staging monitoring stack (Prometheus, Grafana, Loki, Alloy, alerting) is
  # an "app of apps": this root Application deploys observability/argocd, which
  # holds one Application per component. Staging only; production has none.
  # It used to be applied by hand with kubectl, so a rebuilt cluster would not
  # have got its monitoring back; now it comes back with the rest.
  observability_root_app = {
    "carelink-observability" = {
      namespace = "argocd"
      project   = "default"
      source = {
        repoURL        = var.observability_repo_url
        targetRevision = "main"
        path           = var.environment == "production" ? "observability/argocd-production" : "observability/argocd"
        directory      = { recurse = true }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
      }
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.0"

  values = concat([yamlencode({
    # Dex (GitHub sign-in) is switched on by argocd_sso_values when
    # argocd_sso_enabled. No Slack/e-mail notifications from Argo CD; alerts go
    # through CloudWatch/SNS (monitoring.tf).
    dex           = { enabled = false }
    notifications = { enabled = false }
    server = {
      service = { type = "ClusterIP" }
    }
    # The application controller requested no memory, so the scheduler could not
    # see it (about 445 MiB in use in staging, 155 MiB in production on 20 Nov).
    # A request makes the node sizing in eks.tf hold. No limit on purpose: an
    # out-of-memory kill would stop every sync.
    controller = {
      resources = { requests = { memory = "512Mi" } }
    }
  })], var.argocd_sso_enabled ? [yamlencode(local.argocd_sso_values)] : [])

  # The Load Balancer Controller's webhook checks every new Ingress, so it must
  # be running before the Argo CD Ingress is created.
  depends_on = [
    aws_eks_node_group.main,
    helm_release.lbc,
    helm_release.external_dns,
  ]
}

# ------------------------------------------------------------------------------
# GitHub OAuth App credentials for the sign-in
# ------------------------------------------------------------------------------
# One OAuth App per environment, owned by the GitHub organization and created by
# hand (GitHub has no API for it). Its client ID and secret are stored here by a
# person (runbook docs/sre/runbooks/argocd-sso.md), never by Terraform: an
# imported secret version would put the value into the state, which the whole
# cohort can read and which is re-imported every morning. Value format:
#   {"clientID": "...", "clientSecret": "..."}
# Created in every environment, so the value can be stored before the sign-in is
# switched on there.
resource "aws_secretsmanager_secret" "argocd_github_oauth" {
  name        = "${local.name_prefix}-argocd-github-oauth"
  description = "Client ID and secret of the ${var.environment} Argo CD GitHub OAuth App (org ${var.argocd_github_org}); stored by hand, read by External Secrets"
  kms_key_id  = aws_kms_key.this["secrets"].arn

  tags = local.common_tags
}

# External Secrets copies it into the Kubernetes Secret that dex.config refers to.
resource "helm_release" "argocd_github_oauth" {
  count = var.argocd_sso_enabled ? 1 : 0

  name      = "argocd-github-oauth"
  namespace = "argocd"
  chart     = "${path.module}/charts/manifests"

  values = [yamlencode({
    resources = [
      {
        apiVersion = "external-secrets.io/v1"
        kind       = "ExternalSecret"
        metadata = {
          name      = local.argocd_oauth_k8s_secret
          namespace = "argocd"
        }
        spec = {
          refreshInterval = "5m"
          secretStoreRef = {
            kind = "ClusterSecretStore"
            name = "aws-secrets-manager" # app-database.tf
          }
          target = {
            name           = local.argocd_oauth_k8s_secret
            creationPolicy = "Owner"
            template = {
              engineVersion = "v2"
              # Without this label Argo CD ignores the Secret.
              metadata = { labels = { "app.kubernetes.io/part-of" = "argocd" } }
              data = {
                clientID     = "{{ .clientID }}"
                clientSecret = "{{ .clientSecret }}"
              }
            }
          }
          data = [
            for key in ["clientID", "clientSecret"] : {
              secretKey = key
              remoteRef = {
                key      = aws_secretsmanager_secret.argocd_github_oauth.name
                property = key
              }
            }
          ]
        }
      }
    ]
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.app_database, # creates the ClusterSecretStore
  ]
}

# The Application is created through the argocd-apps chart rather than a
# kubernetes_manifest resource, because the Application CRD only exists after
# Argo CD is installed and kubernetes_manifest needs the CRD at plan time
# (which breaks a rebuild from empty state).
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"

  values = [yamlencode({
    applications = merge({
      (local.argocd_app_name) = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.app_repo_url
          targetRevision = "env/${var.environment}"
          path           = "charts/carelink"
          helm = {
            releaseName = "carelink"
            valueFiles  = ["values.yaml", "values-${var.environment}.yaml"]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = var.environment
        }
        syncPolicy = {
          # prune: remove what was deleted from the chart; selfHeal: undo manual
          # kubectl changes, so Git stays the only way to change the app.
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
          # Right after a rebuild the Load Balancer Controller webhook may not
          # be ready yet; retry instead of staying failed.
          retry = {
            limit   = 10
            backoff = { duration = "30s", factor = 2, maxDuration = "5m" }
          }
        }
      }
    }, local.observability_root_app)
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.lbc,
    helm_release.external_dns,
  ]
}

output "argocd_application" {
  description = "Argo CD Application that deploys the app in this environment (namespace argocd)"
  value       = local.argocd_app_name
}

output "argocd_url" {
  description = "Argo CD UI with GitHub sign-in (empty while argocd_sso_enabled is false: use kubectl port-forward)"
  value       = var.argocd_sso_enabled ? "https://${local.argocd_hostname}" : ""
}
