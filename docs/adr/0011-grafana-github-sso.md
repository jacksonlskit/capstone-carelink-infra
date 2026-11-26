# ADR 0011: Grafana with its own URL and GitHub sign-in

**Status:** Accepted (live in staging and production on 26 Nov 2026)

**Date:** 2026-11-26

## Context
Grafana was reachable only through `kubectl port-forward` with the shared `admin` login. Since 25 Nov the production viewers may port-forward in `monitoring`, but every viewer still needs kubectl, cluster credentials and the admin password. That is awkward for the SRE team and impossible for instructors or anyone without cluster access.

ADR 0010 already created the GitHub organization `carelink-group03` with the teams `devops` and `team`.

## Options Considered
**1. Own URL and ALB per environment, with Grafana's built-in GitHub sign-in**
- For:
  - Anyone in the organization opens Grafana in a browser.
  - Roles come from the same GitHub teams as Argo CD.
  - No extra component: Grafana does GitHub sign-in itself.
- Against:
  - One more internet-facing endpoint per environment, and about $25/month per ALB.
  - The settings are deployed by Argo CD from `main`, not by the approved production pipeline.

**2. Keep port-forward only**
- For: no public endpoint.
- Against: every viewer needs cluster access and the shared admin password.

**3. Share Argo CD's ALB (IngressGroup)**
- For: saves about $25/month per environment.
- Against: Argo CD's ALB would have to be rebuilt, which is not worth the risk the day before the presentation. It's a good change afterwards.

**4. Dex in front of Grafana**
- For: one sign-in component for both tools.
- Against: Grafana's own GitHub sign-in does the same with one component fewer.

## Decision
Option 1 (`observability/values/kube-prometheus-stack/<env>.yaml`):
- **URL and ALB:** `https://carelink-<env>-grafana.sctp-sandbox.com`, on its own ALB with the same Ingress pattern as the app and Argo CD; certificate from `oicd-bootstrap/main.tf`.
- **Sign-in:** GitHub, only for members of `carelink-group03`. Roles come from the teams (`role_attribute_path`), and anyone in neither team is refused (`role_attribute_strict`):

  | Team | Staging | Production |
  |---|---|---|
  | `devops` | Admin | Admin |
  | `team` | Admin | **Viewer** (with `viewers_can_edit`: Explore and trying changes, never saving) |

- **Credentials:** never in Git or Terraform state. Terraform creates the empty secret `carelink-<env>-grafana-github-oauth`; a person stores the value (`scripts/set-argocd-oauth-secret.sh <env> grafana`); External Secrets turns it into the Kubernetes Secret `grafana-github-oauth`.
- **The switch is in the Secret:** `auth.github.enabled` is `false` in Git, and the Secret supplies `GF_AUTH_GITHUB_ENABLED=true` with the client ID and secret (`envFromSecrets`, `optional: true`). Grafana runs normally until the credentials exist.
- **Rollout:** `maxSurge: 0, maxUnavailable: 1`, so the old pod stops before the new one starts, because the ReadWriteOnce disk can't attach to two nodes. Type `Recreate` was rejected by the API server under server-side apply, which keeps the defaulted `rollingUpdate` block.
- **The admin login form stays** as break-glass: 32 random characters from Secrets Manager, and Grafana locks a user after 5 failed logins in 5 minutes.

## Consequences
- **Access:** anyone in the organization can open Grafana in a browser. Production viewers can't change dashboards, which stay code (ConfigMaps in Git).
- **The pull request review is the gate** for these settings: they are deployed by Argo CD from `main`, like the rest of observability.
- **New endpoints:** one more internet-facing endpoint per environment, with the same mitigations as ADR 0010 plus the strong admin password and the lockout. About $25/month per ALB, not priced by Infracost (ADR 0009).
- **Downtime:** each change to Grafana's settings means about a minute of Grafana downtime (none for the application).
- **Reloader restarts Grafana when the Secret *changes*,** for example after a rotation, **but not when it is first created.** On 26 Nov the first switch-on needed one `kubectl rollout restart` per environment.
- **Callback URLs:** GitHub's "redirect_uri is not associated with this application" means the OAuth App's callback URL is wrong. It must be `https://carelink-<env>-grafana.sctp-sandbox.com/login/github` (seen in production on 26 Nov).
- **Runbook:** `docs/sre/runbooks/grafana-sso.md`.
