# ADR 0009: Hybrid FinOps cost observability with Infracost, Prometheus, and Grafana

- **Status:** Accepted
- **Date:** 2026-11-22
- **Owner:** DevSecOps Engineer

## Context
CareLink operates isolated `staging` and `production` environments on AWS (`us-east-1`) spanning EKS, RDS MySQL, RDS PostgreSQL, VPC NAT Gateways, KMS, Secrets Manager, and CloudWatch. Engineering and operations teams need continuous monthly run-rate visibility inside Grafana to compare environment HA trade-offs and spot unused resources across nightly teardown and rebuild cycles.

Three constraints shaped the design:
- **Restricted billing APIs:** Shared AWS account IAM policies deny `ce:*` (AWS Cost Explorer) permissions, and native billing data lags infrastructure changes by up to 24 hours.
- **Off-cluster managed services:** Roughly 70% of CareLink's AWS spend sits outside EKS worker nodes (managed RDS instances, EKS control planes, and NAT Gateways), so pod-only Kubernetes cost tools underreport total environment spend.
- **Dynamic worker scaling:** EKS worker node counts change during load tests or right-sizing, causing static cost spreadsheets to drift.

## Decision
- **Hybrid Infracost + Prometheus model:** A local generator (`export-infracost-metrics.py`) parses `infracost scan` output across `carelink-staging` and `carelink-production`, separating fixed off-cluster AWS baseline costs from per-node EC2 compute (**$34.37/mo per worker node**).
- **Live PromQL run-rate calculation:** Grafana combines fixed IaC baseline metrics with live Kubernetes node telemetry (`count(kube_node_info)`), reacting within 30 seconds whenever worker nodes scale:

      sum(carelink_infracost_fixed_monthly_usd{environment="$env"})
      + (count(kube_node_info) * scalar(carelink_infracost_ec2_node_unit_monthly_usd{environment="$env"}))

- **Zero-dependency exporter & sidecar provisioning (`observability/finops/`):** Metrics are stored in a `ConfigMap` (`infracost-metrics`) and served over HTTP at `/metrics` by an `nginx:alpine` Deployment (`infracost-exporter`) configured with `Content-Type: text/plain; version=0.0.4; charset=utf-8`. A `ServiceMonitor` (`release: kube-prometheus-stack`) scrapes `/metrics` into Prometheus, and a `ConfigMap` (`grafana_dashboard: "1"`) auto-provisions the 6-panel dashboard (`CareLink FinOps & AWS Cost Run-Rate`).
- **GitOps delivery across environments (ADR 0008):** Argo CD syncs `observability/finops/` into `monitoring` via `observability/argocd/apps/finops.yaml` (staging) and `observability/argocd-production/apps/finops.yaml` (production), with `Namespace` whitelisted in `observability-project.yaml` so fresh cluster rebuilds bootstrap cleanly.

### Audited Baseline Run-Rate (4 Worker Nodes / Cluster)

| Service Category | Staging | Production | Cost Driver |
| :--- | :---: | :---: | :--- |
| **RDS MySQL** | $171.66/mo | $198.05/mo | Production Multi-AZ (+$26.39/mo HA delta) |
| **EKS Worker Nodes (EC2)** | $137.47/mo | $137.47/mo | 4 × nodes at **$34.37/mo** each (live in Grafana) |
| **EKS Control Plane** | $73.00/mo | $73.00/mo | Fixed managed control plane ($0.10/hr) |
| **VPC NAT Gateways** | $32.85/mo | $98.55/mo | Single-AZ staging vs. 3-AZ production (+$65.70/mo) |
| **RDS PostgreSQL** | $25.66/mo | $25.66/mo | Provisioned database instance (cleanup candidate) |
| **KMS, Secrets & CloudWatch** | $8.80/mo | $8.80/mo | 4 KMS keys, Secrets Manager, dashboards/alarms |
| **Total 24/7 Run-Rate** | **$449.44/mo** | **$541.53/mo** | **Combined 24/7 Ceiling: $990.97/mo** |

## Alternatives considered
- **AWS Cost Explorer / CUR Prometheus exporters:** Blocked by shared account `ce:*` IAM restrictions and introduces up to a 24-hour billing lag.
- **Kubernetes-only cost tools (e.g., OpenCost):** Covers in-cluster pod/node allocation only, omitting off-cluster RDS, NAT Gateways, and EKS control plane costs.
- **Static documentation:** Requires manual edits whenever worker node counts change and lives outside operational dashboards.

## Consequences
- **Zero billing IAM dependency:** Displays full AWS environment run-rates inside Grafana without Cost Explorer permissions.
- **Automatic rebuild recovery:** Argo CD restores `infracost-exporter` and the Grafana dashboard automatically after nightly cluster teardowns in both staging and production.
- **Live scaling accuracy:** Adding or terminating EKS worker nodes updates live monthly compute spend within 30 seconds without manual edits.
- **Manual refresh for non-EC2 Terraform changes:** Modifying off-cluster Terraform resources (such as RDS instance classes or NAT Gateway counts) requires re-running `export-infracost-metrics.py` locally and committing the updated `01-infracost-metrics-cm.yaml` to Git.
