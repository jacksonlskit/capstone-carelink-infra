# CareLink Health: cloud infrastructure

Terraform, pipelines and documentation for CareLink Health (capstone Use Case B): Spring PetClinic Cloud on Amazon EKS in `us-east-1`, with a staging and a production environment. The application code, its Helm chart and its delivery pipeline live in [capstone-carelink-app](https://github.com/jacksonlskit/capstone-carelink-app).

## At a glance

- Two environments, each with its own VPC over three AZs, EKS cluster, RDS MySQL database and ALB. Production runs one NAT gateway per AZ and Multi-AZ MySQL; staging is a cost-reduced copy.
- GitHub Actions applies this repo with Terraform using short-lived OIDC credentials (no stored keys). Production changes need the DevOps owner's approval.
- Argo CD in each cluster deploys the app from the app repo's `env/<environment>` branch (GitOps).
- Both environments run a monitoring stack (Prometheus, Grafana, Loki, Alloy, Alertmanager to Discord) deployed by Argo CD from `observability/`, plus CloudWatch alarms. Grafana also shows each environment's monthly AWS run-rate from Infracost ([ADR 0009](docs/adr/0009-hybrid-finops-cost-observability.md)), and every infrastructure pull request gets an Infracost cost comment.
- Architecture and diagram: [docs/architecture.md](docs/architecture.md). Evidence for each hard constraint: [docs/compliance-mapping.md](docs/compliance-mapping.md). Decisions: [docs/adr/](docs/adr/). SLOs and runbooks: [docs/sre/](docs/sre/).

## Repository layout

```text
.github/workflows/
  ci.yaml                       PR checks: fmt/validate, Snyk IaC, plans for staging and production
  cd.yaml                       main: Snyk, apply staging, approval, apply production
  observability-validate.yaml   Prometheus alert rules (promtool) and Grafana dashboards
  infracost.yaml                PR cost comment (Infracost) and FinOps metrics drift check
  sre-health-check.yaml         scheduled check of CloudWatch alarms and log groups
infracost.yml                   Infracost projects: infra/ priced for staging and production
oicd-bootstrap/main.tf          one-time setup, applied locally: OIDC roles, state bucket, ACM
                                certificates, GitHub environments, variables and rulesets
infra/                          the platform, applied by the pipelines per environment
  vpc.tf eks.tf node-tags.tf    network, EKS cluster, node group, cluster access per environment
  rds.tf app-database.tf        MySQL with TLS required, the app's database secret
  kms.tf ecr.tf                 customer-managed keys, image repositories
  lbc.tf dns.tf ebs-csi.tf      load balancer controller, external-dns, EBS CSI driver and the
                                encrypted default storage class
  argocd.tf                     Argo CD and its Applications (the app, and the monitoring root app)
  monitoring*.tf observability-*.tf alerts-discord.tf lambda/
                                CloudWatch alarms and dashboard, SNS, Discord bridge, AWS side of
                                the monitoring stack (Loki bucket, Grafana and Discord secrets)
  policies/                     IAM policy documents (load balancer controller)
  charts/manifests/             small local Helm chart for plain Kubernetes objects
observability/                  monitoring stack for both environments, deployed by Argo CD
                                (argocd/ staging, argocd-production/ production, finops/ cost
                                exporter and dashboard)
scripts/                        recovery after the nightly cleanup: recover-state.sh,
                                generate-imports.sh, clean-wipe-leftovers.sh; FinOps:
                                export-infracost-metrics.py (regenerates the cost metrics)
docs/                           architecture, compliance mapping, ADRs, SLOs and runbooks
```

## Pipelines

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yaml` | Pull request to `main`; pushes to `feature/**` | `terraform fmt` and `validate`, Snyk IaC scan (fails on high), then a plan for staging and for production (the production plan waits for approval). Each plan first runs `scripts/recover-state.sh`. |
| `cd.yaml` | Push to `main`, or manual | Snyk check, apply to staging, then apply to production after the `production` environment approval. |
| `observability-validate.yaml` | Pull requests and pushes to `main` that change alert rules or dashboards under `observability/` | Prometheus rules with `promtool`, Grafana dashboard JSON. |
| `infracost.yaml` | Pull requests to `main` that change `infra/`, `infracost.yml` or the FinOps files | Posts one PR comment with the monthly cost of staging and production and what the change adds or removes, and warns if the FinOps metrics in `observability/finops/` no longer match the Terraform. Informational, not a required check; needs the `INFRACOST_CLI_AUTHENTICATION_TOKEN` repository secret. |
| `sre-health-check.yaml` | Every 6 hours, or manual | Lists CloudWatch alarms in ALARM and recent log groups. It runs in the production environment, so each run waits for approval. |

## Security model

- **Keyless credentials** ([ADR 0002](docs/adr/0002-keyless-oidc-pipelines.md)): a GitHub OIDC provider and one IAM role per environment. Each role trusts only its own GitHub environment, matched exactly on GitHub's immutable subject. The production role's condition:

  ```json
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": [
        "repo:<owner>@<owner id>/capstone-carelink-infra@<repo id>:environment:production",
        "repo:<owner>@<owner id>/capstone-carelink-app@<repo id>:environment:production"
      ]
    }
  }
  ```

  The staging role is the same with `environment:staging`. A staging job cannot assume the production role, and a job that runs outside an environment gets no AWS access.
- **State** ([ADR 0003](docs/adr/0003-s3-native-state-locking.md)): one S3 bucket, one key per environment, native locking. Only the pipeline roles can write state, each only its own environment's key.
- **Reviews:** `main` in both repositories needs a pull request with one approval from someone other than the last pusher, and green checks. Production deployments need the DevOps owner's approval.
- **Production deploy branch:** Argo CD deploys whatever is on the app repository's `env/production`, so a ruleset lets only one deploy key write it. GitHub gives that key (the production environment secret `ENV_PRODUCTION_DEPLOY_KEY`) only to the production job, after the approval, for runs from `main`. Nobody can push there directly.
- **Cluster access:** per environment in `infra/variables.tf` (`cluster_access`). In production only the DevOps owner is cluster admin; the rest of the team is view-only, plus `kubectl port-forward` in the `monitoring` namespace so they can open Grafana (Role `monitoring-portforward`, `infra/eks.tf`).
- **Known limits** ([ADR 0006](docs/adr/0006-environment-isolation.md)): both pipeline roles have AdministratorAccess in the shared cohort account, and `env/staging` is not locked (staging has no approval step).
- **Argo CD UI** ([ADR 0010](docs/adr/0010-argocd-github-sso.md)): `https://carelink-<env>-argocd.sctp-sandbox.com`, GitHub sign-in for members of the `carelink-group03` organization, no local admin. In production only the DevOps owner is admin; the rest of the team is read-only. Staging first; production follows. Runbook: [docs/sre/runbooks/argocd-sso.md](docs/sre/runbooks/argocd-sso.md).
- **Grafana** ([ADR 0011](docs/adr/0011-grafana-github-sso.md)): `https://carelink-<env>-grafana.sctp-sandbox.com`, GitHub sign-in for the same organization and teams. In production only the DevOps owner is Admin; the rest of the team are Viewers (Explore allowed, no saving). The admin login stays as break-glass. Runbook: [docs/sre/runbooks/grafana-sso.md](docs/sre/runbooks/grafana-sso.md).

## Bootstrap

The pipelines authenticate with roles that the bootstrap creates, so the bootstrap is applied from the DevOps owner's machine and keeps its state locally:

```bash
cd oicd-bootstrap
terraform init
GITHUB_TOKEN=$(gh auth token) terraform apply
```

It creates the OIDC provider, the two pipeline roles and their trust policies, the state bucket and its policy, the DNS-validated ACM certificates, the GitHub environments (with the production approval), the variables the workflows read (`AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`), the rulesets for `main`, and the `env/production` lock (deploy key, ruleset, main-only production environment). The Snyk token (`SNYK_TOKEN`) and the Infracost service-account token (`INFRACOST_CLI_AUTHENTICATION_TOKEN`) are repository secrets, set by hand with `gh secret set`.

The deploy key's private half is not in Terraform: it was generated locally and stored once with `gh secret set ENV_PRODUCTION_DEPLOY_KEY --env production --repo <owner>/capstone-carelink-app`, then deleted, so it is in neither Git nor the bootstrap state. To rotate it, generate a new pair, replace `oicd-bootstrap/keys/app-env-production-deploy-key.pub`, set the secret again and apply.

## The nightly cleanup and the morning routine

The cohort account is cleaned every night (about 22:00 UTC): untagged resources, the Terraform state objects and every IAM policy attachment are deleted. Everything we keep carries `Project = capstone-project-group-03` through the Terraform `default_tags`. Each morning:

1. Re-apply the bootstrap from `main` (it restores the pipeline roles' policy attachments): `git switch --detach origin/main`, then the apply above. Expect 2 to add.
2. Run the deployment pipeline: `gh workflow run cd.yaml --ref main`. Its first step adopts every resource that still exists (import blocks), then applies.
3. Approve production, and check that the apply reports 0 destroyed.

Details: [docs/sre/runbooks/state-recovery-after-cleanup.md](docs/sre/runbooks/state-recovery-after-cleanup.md).

## Making a change

1. Branch from `main`, commit, push and open a pull request.
2. CI runs the plans for both environments (approve the production plan run); a teammate reviews.
3. Merge: CD applies to staging, then waits for the production approval.

Only the pipeline applies: a local `terraform apply` is refused by the state bucket policy while taking the lock, before anything changes. To preview a change locally, run `terraform plan -lock=false`. The break-glass procedure is in the comments of `oicd-bootstrap/main.tf`.
