# ADR 0010: Argo CD UI with GitHub sign-in

- **Status:** Accepted (staging first, production in a follow-up pull request)
- **Date:** 2026-11-25
- **Owner:** DevSecOps Engineer
- **Replaces:** the "UI not exposed publicly (port-forward only)" consequence of ADR 0008

## Context
Argo CD was reachable only through `kubectl port-forward`, with one shared local `admin` login whose password sits in a Kubernetes Secret. That worked for the DevOps owner, but:

- In production the rest of the team is view-only in the cluster (ADR 0006, `cluster_access`). They can neither port-forward nor read Secrets, so they cannot see deployments, sync status or diffs at all.
- Giving them port-forward in the `argocd` namespace would not help safely. RBAC cannot limit port-forward to the UI pod, so it would also open `argocd-repo-server` and `argocd-redis`, internal services that only Argo CD itself should reach. And the only login is `admin`, which can change an Application's source, sync, roll back or delete. That would bypass the `production` approval and the `env/production` lock (ADR 0006).

The team needs to see production deployments, but production changes must stay with the DevOps owner and the approved pipeline.

## Decision
- **Own hostname and ALB per environment:** `https://carelink-<env>-argocd.sctp-sandbox.com` (`infra/argocd.tf`, switched on per environment by `argocd_sso_enabled`). It uses the same pattern as the app Ingress: internet-facing ALB, TLS 1.3 policy, HTTP redirected to HTTPS, an ACM certificate found by hostname (created in `oicd-bootstrap/main.tf`, so it survives the nightly cleanup), the team's `Project` tag, and a DNS record written by external-dns. It is a separate ALB (no `group.name`), so the app's ALB is never touched. TLS ends at the ALB (`server.insecure`).
- **GitHub sign-in only, through Dex:** only members of the GitHub organization `carelink-group03` can sign in. Their teams reach Argo CD as groups `carelink-group03:<team>`. The local `admin` login is turned off, so there is no shared password and nothing to guess on the public page.
- **Roles from GitHub teams, per environment** (`argocd_team_roles` in `infra/argocd.tf`):

  | Team | Staging | Production |
  |---|---|---|
  | `devops` (DevOps owner) | admin | admin |
  | `team` (whole team) | admin | **read-only**: view apps, diffs, events and logs; no sync, rollback or delete |

  `policy.default` stays empty, so a signed-in user in no listed team sees nothing.
- **Membership is code:** the teams and their members are in `oicd-bootstrap/main.tf` (GitHub provider for the organization), so access changes through a reviewed pull request, like `cluster_access`. The organization and its two OAuth Apps (one per environment, owned by the organization) were created by hand, because GitHub has no API for either.
- **The OAuth client secret never touches Git or Terraform state:** Terraform creates the empty, tagged secret `carelink-<env>-argocd-github-oauth` (encrypted with the `secrets` KMS key); a person stores the value; External Secrets copies it into the Kubernetes Secret `argocd-dex-github`, which `dex.config` refers to as `$argocd-dex-github:<key>`. Same reasoning as the Grafana secret: an imported secret version would put the value into the state, which the cohort can read and which is re-imported every morning.
- **Webhook endpoint blocked:** Argo CD polls Git and we configured no webhooks, so the ALB answers `404` on `/api/webhook` instead of passing unauthenticated requests to Argo CD.
- **gRPC not exposed:** the ALB serves HTTP/1 only. The CLI works with `argocd login <host> --sso --grpc-web`.

## Alternatives considered
- **Port-forward in the `argocd` namespace for the team:** also opens the repo server and Redis (RBAC cannot target one Deployment's pods), and the only login is `admin`.
- **A read-only local Argo CD account:** a shared password set by hand outside IaC, and it still needs port-forward in `argocd`.
- **Argo CD metrics in Grafana:** read-only and small, but it shows only sync and health status, not diffs, history or logs.
- **GitHub sign-in without an organization, roles by e-mail address:** the teammates' e-mail addresses would sit in a public repository, and any GitHub user could reach the login screen.
- **Sharing the app's ALB (IngressGroup):** one ALB less (about $25 a month), but a mistake in the Argo CD Ingress could break the app's listener rules.

## Consequences
- The team sees production deployments without kubectl access, and production changes still go only through Git and the approved pipeline. The DevOps owner remains the only production admin in both the cluster and Argo CD.
- A new internet-facing endpoint per environment. Mitigations: GitHub sign-in limited to the organization, no local `admin`, the webhook endpoint blocked, TLS 1.2/1.3 only, the chart pinned (`argo-cd` 10.18.0, Argo CD v3.6.1). No IP allowlist: clinic staff and instructors sign in from anywhere.
- Cost: one ALB plus its public IPv4 addresses per environment, about $25 a month each. Infracost does not price ALBs created by the Load Balancer Controller (ADR 0009, "Not included").
- If GitHub or Dex is down, nobody can sign in to the UI. Break-glass for the DevOps owner, who is cluster admin: `kubectl` against the Application objects, or `argocd --core`, which talks to the Kubernetes API directly. Deployments are unaffected: the app pipeline only uses `kubectl` (`scripts/wait-for-argocd.sh`).
- New members must accept the organization invitation before they can sign in.
- Runbook: `docs/sre/runbooks/argocd-sso.md`.
