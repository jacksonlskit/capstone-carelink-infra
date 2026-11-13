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
# The Argo CD UI is not exposed publicly. To open it:
#   kubectl -n argocd port-forward svc/argocd-server 8443:443
#   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# then browse https://localhost:8443 (user: admin).
# ==============================================================================

variable "app_repo_url" {
  description = "Public Git repository that holds the app Helm chart (charts/carelink) and the env/<environment> deploy branches"
  type        = string
  default     = "https://github.com/jacksonlskit/capstone-carelink-app.git"
}

locals {
  argocd_app_name = "carelink-${var.environment}"
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.0"

  values = [yamlencode({
    # Not needed: no SSO (dex) and no Slack/e-mail notifications from Argo CD;
    # alerts go through CloudWatch/SNS (monitoring.tf).
    dex           = { enabled = false }
    notifications = { enabled = false }
    server = {
      service = { type = "ClusterIP" }
    }
  })]

  depends_on = [aws_eks_node_group.main]
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
    applications = {
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
    }
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
