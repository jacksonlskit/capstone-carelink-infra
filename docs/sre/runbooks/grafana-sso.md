# Runbook: Grafana sign-in with GitHub

Design: [ADR 0011](../../adr/0011-grafana-github-sso.md). The GitHub organization, teams and OAuth App handling are shared with Argo CD: see [argocd-sso.md](argocd-sso.md) for adding people and for the "application not authorized to read org data" fix.

## Where everything lives

| What | Where |
|---|---|
| URL | `https://carelink-<env>-grafana.sctp-sandbox.com` |
| Settings (Ingress, `grafana.ini`, role mapping) | `observability/values/kube-prometheus-stack/<env>.yaml`, deployed by Argo CD |
| OAuth App (one per environment) | Created **from the organization's page** (`github.com/organizations/carelink-group03/settings/applications`). Callback URL `https://carelink-<env>-grafana.sctp-sandbox.com/login/github` |
| Client ID and secret | Secrets Manager `carelink-<env>-grafana-github-oauth` (`infra/observability-grafana.tf`), value stored with `scripts/set-argocd-oauth-secret.sh <env> grafana` |
| Copy in the cluster | Kubernetes Secret `grafana-github-oauth` (namespace `monitoring`), from the ExternalSecret in `observability/secrets/` (`production/` for production); it also sets `GF_AUTH_GITHUB_ENABLED=true` |
| TLS certificate | ACM, `oicd-bootstrap/main.tf` (`aws_acm_certificate.grafana`) |
| Admin login | Still available (break-glass): `docs/sre/runbooks/grafana-admin-password.md` |

## Switch it on in an environment

1. **Bootstrap apply** from `origin/main` (certificates): expect the 2 Grafana certificates with their validation records. Until then the Ingress has no ALB (`no certificate found for host`); the Load Balancer Controller retries by itself.
2. **Infra deploy** of the pull request creates the empty secret and lets External Secrets read it.
3. **Store the OAuth App's client ID and secret:**
   ```bash
   scripts/set-argocd-oauth-secret.sh staging grafana
   ```
4. **Copy it into the cluster now** (instead of within 5 minutes):
   ```bash
   kubectl -n monitoring annotate externalsecret grafana-github-oauth force-sync="$(date +%s)" --overwrite
   kubectl -n monitoring get externalsecret grafana-github-oauth
   ```
   Expect `SecretSynced`.
5. **The first time only, restart Grafana** so it reads the new environment variables (about a minute without Grafana):
   ```bash
   kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana
   ```
   Reloader restarts Grafana when the Secret *changes* (for example after a rotation), but not when it is first *created*; seen on 26 Nov 2026. Afterwards the login page shows **Sign in with GitHub**.

## Check it works

| Check | Expected |
|---|---|
| `curl -sI https://carelink-<env>-grafana.sctp-sandbox.com/api/health \| head -1` | `HTTP/2 200` |
| `kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana` | a pod started after step 5 (or, after a rotation, restarted by Reloader) |
| DevOps owner signs in with GitHub | Admin |
| Teammate signs in (production) | Viewer: dashboards and Explore work; **Save** is not offered |
| Someone outside the organization | refused ("Login failed") |

## When sign-in is broken

- **No "Sign in with GitHub" button:** the Secret is missing or Grafana was not restarted. Check `kubectl -n monitoring get secret grafana-github-oauth`, then `kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-grafana`.
- **"Login failed" for a team member:** the person has not accepted the organization invitation, is in neither team, or the OAuth App is not approved for the organization (see argocd-sso.md). Grafana's log says which: `kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana | grep -i github`.
- **"redirect_uri is not associated with this application":** the OAuth App's callback URL must be exactly `https://carelink-<env>-grafana.sctp-sandbox.com/login/github`.
- **Rollout stuck:** should not happen with `maxSurge: 0`. If a new pod is `ContainerCreating` with "Multi-Attach error", delete the old pod.
