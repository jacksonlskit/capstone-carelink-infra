# ADR 0009: Cost visibility: Infracost estimates plus live node count in Grafana

**Status:** Accepted

**Date:** 2026-11-23

## Context
CareLink operates isolated `staging` and `production` environments on AWS (`us-east-1`) spanning EKS, RDS MySQL, RDS PostgreSQL, VPC NAT Gateways, KMS, Secrets Manager, and CloudWatch. Engineering and operations teams need continuous monthly run-rate visibility inside Grafana to compare environment HA trade-offs and spot unused resources across nightly teardown and rebuild cycles.

Three constraints shaped the design:
- **Restricted billing APIs:** Shared AWS account IAM policies deny `ce:*` (AWS Cost Explorer) permissions, and native billing data lags infrastructure changes by up to 24 hours.
- **Off-cluster managed services:** Roughly 70% of CareLink's AWS spend sits outside EKS worker nodes (managed RDS instances, EKS control planes, and NAT Gateways), so pod-only Kubernetes cost tools underreport total environment spend.
- **Dynamic worker scaling:** EKS worker node counts change during load tests or right-sizing, causing static cost spreadsheets to drift.

## Options Considered
**1. Hybrid: Infracost prices the Terraform, Prometheus adds the live node count (Grafana)**
- For:
  - Works without billing permissions.
  - Covers the off-cluster costs (RDS, NAT, EKS control plane) that make up most of the spend.
  - Follows node scaling within 30 seconds.
  - Every infrastructure pull request shows its cost change.
- Against:
  - An estimate, not the bill: usage-based charges and resources created outside Terraform (the ALBs) are missing.
  - The metrics must be regenerated when priced resources change.

**2. AWS Cost Explorer / Cost and Usage Report exporters**
- For: real billed cost.
- Against: blocked by the shared account's IAM policy (`ce:*` denied), and up to 24 hours of billing lag.

**3. Kubernetes-only cost tools (e.g. OpenCost)**
- For: detailed per-pod allocation.
- Against: covers only in-cluster nodes and pods, and misses RDS, NAT Gateways and the EKS control plane.

**4. A static cost spreadsheet**
- For: simple.
- Against: goes stale whenever nodes or resources change, and lives outside the dashboards.

## Decision
Option 1:

- **Hybrid Infracost + Prometheus model:** The generator `scripts/export-infracost-metrics.py` runs `infracost scan` (Infracost CLI v2.20.0) on the projects in `infracost.yml` (`carelink-staging` and `carelink-production`: the same `infra/` priced once per environment, with the same switches the pipelines set: `monitor_alb`, `discord_alerts_enabled`, `argocd_sso_enabled`) and writes only `observability/finops/01-infracost-metrics-cm.yaml`. It separates fixed off-cluster AWS baseline costs from per-node EC2 compute (**$34.37/mo per worker node** = the node group's price divided by `desired_size` in `infra/eks.tf`, so the unit price follows the code).
- **Live PromQL run-rate calculation:** Grafana combines fixed IaC baseline metrics with live Kubernetes telemetry, reacting within 30 seconds whenever worker nodes scale or a load balancer is added or removed:

      sum(carelink_infracost_fixed_monthly_usd{environment="$env"})
      + (count(kube_node_info) * scalar(carelink_infracost_ec2_node_unit_monthly_usd{environment="$env"}))
      + (count(kube_ingress_info{ingressclass="alb"}) or vector(0)) * scalar(carelink_infracost_alb_unit_monthly_usd{environment="$env"})

  The last line adds the **Application Load Balancers**, which Infracost cannot see because the AWS Load Balancer Controller creates them from Kubernetes Ingresses (app, Argo CD, Grafana: 3 per environment since 26 Nov). The generator writes their unit price, **$27.38/mo** (ALB $0.0225/h plus 3 public IPv4 at $0.005/h, us-east-1 Price List API, 26 Nov 2026), as constants, because it runs without AWS credentials. It assumes one ALB per Ingress, which holds as long as no IngressGroup (`group.name`) is used.

  `kube_node_info` only covers the cluster the dashboard runs in, so `$env` is read from that cluster's own probe job (`carelink-<env>-health`) instead of being a free choice: each Grafana shows its own environment's live cost.
- **Zero-dependency exporter & sidecar provisioning (`observability/finops/`):** Metrics are stored in a `ConfigMap` (`infracost-metrics`) and served over HTTP at `/metrics` by an nginx Deployment (`infracost-exporter`) configured with `Content-Type: text/plain; version=0.0.4; charset=utf-8`. The image is `nginxinc/nginx-unprivileged:1.30.6-alpine`, pinned by digest, running as a non-root user with a read-only root filesystem and no service account token. The ConfigMap is mounted as a directory (not `subPath`), so a new version reaches `/metrics` within about a minute without a restart. A `ServiceMonitor` (`release: kube-prometheus-stack`) scrapes `/metrics` into Prometheus, and a `ConfigMap` (`grafana_dashboard: "1"`) auto-provisions the 7-panel dashboard (including "Load Balancers (live)") (`CareLink FinOps & AWS Cost Run-Rate`). Only `01-...` is generated; the exporter and the dashboard are edited by hand.
- **Cost check on every infrastructure pull request (`.github/workflows/infracost.yaml`):** the `cost-diff` job runs Infracost's CI image (`ghcr.io/infracost/ci:2.1.5`, pinned by digest) on the base branch and the pull request and posts one PR comment with both environments' monthly cost and what the change adds or removes. The `finops-drift` job runs the generator with `--check` and warns (without failing) when the committed metrics no longer match the Terraform. Both are informational, not required checks, use no AWS credentials, and authenticate with the repository secret `INFRACOST_CLI_AUTHENTICATION_TOKEN` (an Infracost service-account token).
- **GitOps delivery across environments (ADR 0008):** Argo CD syncs `observability/finops/` into `monitoring` via `observability/argocd/apps/finops.yaml` (staging) and `observability/argocd-production/apps/finops.yaml` (production), with `Namespace` whitelisted in `observability-project.yaml` so fresh cluster rebuilds bootstrap cleanly.

### Audited Baseline Run-Rate (4 Worker Nodes / Cluster)

| Service Category | Staging | Production | Cost Driver |
| :--- | :---: | :---: | :--- |
| **RDS MySQL** | $171.66/mo | $198.05/mo | MySQL 8.0 Extended Support, about $146/mo per instance (see below); production adds the Multi-AZ standby (+$26.39/mo) |
| **EKS Worker Nodes (EC2)** | $137.47/mo | $137.47/mo | 4 × nodes at **$34.37/mo** each (live in Grafana) |
| **EKS Control Plane** | $73.00/mo | $73.00/mo | Fixed managed control plane ($0.10/hr) |
| **VPC NAT Gateways** | $32.85/mo | $98.55/mo | Single-AZ staging vs. 3-AZ production (+$65.70/mo) |
| **RDS PostgreSQL** | $25.66/mo | $25.66/mo | Provisioned database instance (cleanup candidate) |
| **KMS, Secrets & CloudWatch** | $10.30/mo | $10.30/mo | 4 KMS keys, 5 Secrets Manager secrets, the CloudWatch dashboard and alarms |
| **Total 24/7 IaC Run-Rate** | **$450.94/mo** | **$543.03/mo** | **Combined: $993.97/mo** (Terraform only) |
| **Application Load Balancers (live, outside Terraform)** | 3 × $27.38 = **$82.13/mo** | 3 × $27.38 = **$82.13/mo** | App, Argo CD and Grafana Ingresses; counted live in each cluster's dashboard |
| **Total with load balancers** | **$533.07/mo** | **$625.16/mo** | **Combined: $1,158.22/mo** |

### Cost driver found: MySQL 8.0 Extended Support
Both MySQL instances (`db.t4g.small`, 20 GB gp3) run 8.0, whose RDS standard support ended on 31 Jul 2026, and they are enrolled in RDS Extended Support (`EngineLifecycleSupport: open-source-rds-extended-support`). RDS then bills Extended Support per vCPU-hour, about 2 vCPU x $0.10 x 730 h = **$146/mo per instance**. That is the whole difference between MySQL ($171.66) and PostgreSQL 16 ($25.66, still in standard support) at the same size: about 85% of each MySQL line pays for running an old major version. Whether the production Multi-AZ standby is billed Extended Support as well is not confirmed (Infracost adds only the instance price for it).

**Recommendation, not done for the capstone:** upgrade to MySQL 8.4 (standard support until July 2029) with an RDS Blue/Green deployment, which saves about $292/mo for the two instances. Not done now because a major-version upgrade (new parameter group family, a changed default authentication plugin, a switchover) right before the live demonstration is a bigger risk than about $10 a day, and the environments are removed after the course.

### Not included (outside Terraform, or usage-based)
Infracost prices what the Terraform declares, so these are missing from the totals above (prices for `us-east-1`, counted on 22 Nov; the Application Load Balancers are no longer in this list, because the dashboard counts them live since 26 Nov):

| Item | Staging | Production | Why it is missing |
| :--- | :---: | :---: | :--- |
| NAT gateway public IPv4 addresses ($3.65/mo each) | 1: $3.65/mo | 3: $10.95/mo | The NAT Elastic IPs are in Terraform, but Infracost does not price them (the ALBs' addresses are now included in the live load balancer price) |
| Monitoring volumes (3 PVCs, 50 GB gp3) | ~$4.00/mo | ~$4.00/mo | Created by the EBS CSI driver from PersistentVolumeClaims |
| NAT data processing, CloudWatch Logs, data transfer | usage-based | usage-based | Depend on traffic; not estimated |

So the real run-rate is roughly $8/mo (staging) and $15/mo (production) above the dashboard before usage-based charges and load balancer capacity units (LCUs).

## Consequences
- **Zero billing IAM dependency:** Displays the Terraform-managed run-rate of each environment inside Grafana without Cost Explorer permissions (what it leaves out is listed above).
- **Automatic rebuild recovery:** Argo CD restores `infracost-exporter` and the Grafana dashboard automatically after nightly cluster teardowns in both staging and production.
- **Live scaling accuracy:** Adding or terminating EKS worker nodes, or adding or removing an Ingress (and so an ALB), updates the live monthly run-rate of that cluster within 30 seconds without manual edits.
- **Manual refresh for non-EC2 Terraform changes:** Modifying off-cluster Terraform resources (such as RDS instance classes or NAT Gateway counts) requires re-running `scripts/export-infracost-metrics.py` and committing the updated `01-infracost-metrics-cm.yaml`. The `finops-drift` job warns on the pull request when that was forgotten, and the `cost-diff` comment shows the change in dollars before it is merged.
