# ADR 0010: Argo CD UI with GitHub sign-in

**Status:** Accepted (staging live 25 Nov 2026, production 25 Nov 2026; replaces ADR 0008's "UI only through port-forward")

**Date:** 2026-11-25

## Context
Argo CD was reachable only through `kubectl port-forward`, with one shared local `admin` login whose password sits in a Kubernetes Secret. That worked for the DevOps owner, but:
- In production the rest of the team is view-only in the cluster (ADR 0006). They can neither port-forward nor read Secrets, so they cannot see deployments, sync status or diffs.
- The only login, `admin`, can change an Application's source, sync, roll back or delete. Sharing it would bypass the `production` approval and the `env/production` lock (ADR 0006).

The team needs to *see* production deployments, while production *changes* stay with the DevOps owner and the approved pipeline.

## Options Considered
**1. Own URL and ALB per environment, GitHub sign-in through Dex, roles from GitHub teams**
- For:
  - Everyone signs in with their own GitHub account and there is no shared password.
  - Roles differ per environment (read-only for the team in production).
  - Membership is code.
  - The local `admin` can be switched off.
- Against:
  - A new internet-facing endpoint per environment, and about $25/month per ALB.
  - Needs a GitHub organization and two OAuth Apps created by hand (GitHub has no API for them).

**2. Port-forward in the `argocd` namespace for the team**
- For: no public endpoint.
- Against: RBAC can't limit port-forward to the UI pod, so it also opens the repo server and Redis, and the only login is still `admin`.

**3. A read-only local Argo CD account**
- For: no SSO setup.
- Against: a shared password set by hand outside IaC, and it still needs port-forward.

**4. Argo CD metrics in Grafana only**
- For: read-only and small.
- Against: shows sync and health status, but not diffs, history or logs.

**5. GitHub sign-in without an organization, roles by e-mail address**
- For: no organization to create.
- Against: teammates' e-mail addresses would sit in a public repository, and any GitHub user could reach the login screen.

## Decision
Option 1 (`infra/argocd.tf`, switched on per environment by `argocd_sso_enabled`):
- **URL and ALB:** `https://carelink-<env>-argocd.sctp-sandbox.com`, on its own ALB with the same pattern as the app Ingress: TLS 1.3 policy, HTTP to HTTPS, ACM certificate from `oicd-bootstrap/main.tf`, the `Project` tag, a DNS record from external-dns. TLS ends at the ALB.
- **Sign-in:** GitHub only, through Dex, for members of the organization `carelink-group03`. The local `admin` login is off.
- **Roles from GitHub teams** (`argocd_team_roles`):

  | Team | Staging | Production |
  |---|---|---|
  | `devops` | admin | admin |
  | `team` | admin | **read-only** (view apps, diffs, events and logs; no sync, rollback or delete) |

- **Membership as code:** teams and members are defined in `oicd-bootstrap/main.tf`.
- **Credentials:** the OAuth client secret lives only in Secrets Manager (`carelink-<env>-argocd-github-oauth`), stored by a person and copied by External Secrets. It is never in Git or Terraform state.
- **Smaller attack surface:** the ALB answers 404 on `/api/webhook` (we use no Git webhooks), and gRPC is not exposed (the CLI uses `--grpc-web`).

## Consequences
- **Visibility without control:** the team sees production deployments without kubectl access. Production changes still go only through Git and the approved pipeline (Jon signed in to production as read-only on 26 Nov).
- **New endpoints:** a new internet-facing endpoint per environment, mitigated by organization-only GitHub sign-in, no local admin, the blocked webhook and TLS 1.2/1.3 only.
- **Cost:** about $25/month per ALB, not priced by Infracost (ADR 0009).
- **If GitHub or Dex is down**, nobody can use the UI. The DevOps owner still has `kubectl` and `argocd --core`, and deployments are unaffected (the pipeline uses only `kubectl`).
- **Organization approval:** an OAuth App created under a personal account must be approved for the organization once ("Grant"); apps created from the organization's page are approved automatically.
- **Runbook:** `docs/sre/runbooks/argocd-sso.md`.
