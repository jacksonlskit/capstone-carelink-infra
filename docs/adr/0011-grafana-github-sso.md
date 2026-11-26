# ADR 0011: Grafana with its own URL and GitHub sign-in

- **Status:** Accepted (26 Nov 2026)
- **Date:** 2026-11-26
- **Owner:** DevSecOps Engineer (with the SRE observability owner)
- **Builds on:** ADR 0010 (Argo CD with GitHub sign-in), ADR 0005 (observability)

## Context
Grafana was reachable only through `kubectl port-forward` with the shared `admin` login. Since 25 Nov the production viewers may port-forward in `monitoring` (`helm_release.monitoring_access`), but every viewer still needs kubectl, cluster credentials and the admin password. That's awkward for the SRE team, and it doesn't work at all for instructors or anyone without cluster access. ADR 0010 already set up the GitHub organization `carelink-group03` with the teams `devops` and `team` for Argo CD.

## Decision
- **Own hostname and ALB per environment:** `https://carelink-<env>-grafana.sctp-sandbox.com`. It uses the same Ingress pattern as the app and Argo CD: internet-facing ALB, TLS 1.3 policy, HTTP redirected to HTTPS, an ACM certificate found by hostname (`oicd-bootstrap/main.tf`), the team's `Project` tag, and a DNS record from external-dns. It is configured in `observability/values/kube-prometheus-stack/<env>.yaml`.
- **Grafana's built-in GitHub sign-in** (no Dex needed). Only members of `carelink-group03` can sign in. Roles come from the GitHub teams (`role_attribute_path`), and anyone in neither team is refused (`role_attribute_strict`):

  | Team | Staging | Production |
  |---|---|---|
  | `devops` | Admin | Admin |
  | `team` | Admin | **Viewer**, with `viewers_can_edit`: Explore and trying changes, never saving |

- **Credentials are never in Git or Terraform state.** Terraform creates the empty, tagged secret `carelink-<env>-grafana-github-oauth`, and a person stores the value (`scripts/set-argocd-oauth-secret.sh <env> grafana`). External Secrets turns it into the Kubernetes Secret `grafana-github-oauth` with `GF_AUTH_GITHUB_CLIENT_ID`, `GF_AUTH_GITHUB_CLIENT_SECRET` and **`GF_AUTH_GITHUB_ENABLED`**.
- **The switch is in the Secret.** `auth.github.enabled` is `false` in the values. Grafana loads the Secret through `envFromSecrets` with `optional: true`, and Reloader restarts it when the Secret appears or changes. So deploying the values changes nothing about sign-in until the credentials exist, and GitHub sign-in turns itself on when they do.
- **Rollout without a stuck pod:** `maxSurge: 0, maxUnavailable: 1`. The old pod stops before the new one starts, because the ReadWriteOnce disk can't attach to two nodes. Type `Recreate` was tried first and rejected by the API server under server-side apply, which keeps the defaulted `rollingUpdate` block.
- **The admin login form stays** as break-glass. The password is 32 random characters from Secrets Manager, and Grafana locks a user after 5 failed logins in 5 minutes.

## Alternatives considered
- **Keep port-forward only:** needs cluster access and the shared admin password for every viewer.
- **Share Argo CD's ALB (IngressGroup):** saves about $25 a month per environment, but the Argo CD ALB would have to be rebuilt. That is worth doing after the presentation, not the day before it.
- **Dex in front of Grafana:** Grafana's own GitHub sign-in does the same with one component less.

## Consequences
- Anyone in the organization can open Grafana with a browser. Production viewers can't change dashboards, which stay code (ConfigMaps in Git).
- **One more internet-facing endpoint per environment**, with the same mitigations as ADR 0010, plus the strong admin password and Grafana's brute-force lockout.
- **These settings are deployed by Argo CD from `main`**, like the rest of observability, not by the approved production pipeline. The pull request review is the gate.
- Cost: one ALB plus its public IPv4 addresses per environment, about $25 a month each. Infracost doesn't price ALBs from the Load Balancer Controller (ADR 0009).
- Each change to Grafana's settings means about a minute of Grafana downtime (rollout), and none for the app.
- Runbook: `docs/sre/runbooks/grafana-sso.md`.
