# ADR 0005: Observability: CloudWatch alarms plus an in-cluster Prometheus stack, with SLO burn-rate alerts

**Status:** Accepted (revised 26 Nov 2026 to match what was built; the first version planned CloudWatch only)

**Date:** 2026-11-26

## Context
The brief requires:
- centralised, searchable logs with defined retention;
- infrastructure and application metrics;
- a dashboard a non-team member can read;
- at least two SLIs/SLOs;
- at least two alerts routed to a real destination, one of them triggered live;
- an incident runbook.

Clinics depend on the system 08:00–20:00 SGT with a 99.9% availability target, about 21.6 minutes of downtime per 30 days. The team is small, and both clusters are rebuilt from code after the nightly cleanup, so all monitoring must be code too.

## Options Considered
**1. CloudWatch only (the first plan)**
- For: nothing to run in the cluster, and AWS metrics (ALB, RDS) out of the box.
- Against:
  - Kubernetes and application metrics need Container Insights (extra agent and cost).
  - Ad-hoc log search and dashboards are weaker.
  - Notifications are e-mail only unless a bridge is added.

**2. In-cluster Prometheus, Loki and Grafana only**
- For: rich queries, dashboards as code and Kubernetes-native metrics, all deployed by Argo CD.
- Against:
  - It runs inside the clusters it watches, so it is blind when a cluster is down.
  - It doesn't cover AWS-side signals such as ALB 5xx and RDS events as directly.

**3. Both (hybrid)**
- For: CloudWatch alarms watch the user-facing ALB and the database from outside the cluster, and the Prometheus stack covers Kubernetes, probes, logs and dashboards.
- Against: two alerting paths to keep consistent, and more components to run.

**4. OpenSearch / ELK**
- For: powerful log search.
- Against: heavy to operate and costly at this scale.

## Decision
Option 3, hybrid, everything as code.

**AWS side** (`infra/monitoring.tf`, Terraform):
- **ALB alarms:** availability burn rate, fast (14.4x, 4 of 6 five-minute periods) and slow (6x); p95 latency over 1 s in 3 of 5 windows.
- **RDS:** alarms and lifecycle events, plus a CloudWatch dashboard.
- **Delivery:** alarms go to an encrypted SNS topic, then a Lambda, then Discord (no e-mail subscription by default).
- **Logs:** EKS control-plane logs, including `audit`, go to CloudWatch.

**In the cluster** (`observability/`, deployed by Argo CD in both environments):
- **Metrics:** kube-prometheus-stack (Prometheus, 7-day retention), with a blackbox exporter probing the public `/actuator/health`.
- **Logs:** Loki (logs in S3, 7-day retention) fed by Alloy on every node.
- **Rules:** probe-based SLO recording rules, multi-window burn-rate alerts, Kubernetes alerts and service-redundancy alerts. Alertmanager sends them to Discord, with separate staging and production configurations.
- **Dashboards:** Grafana dashboards as code (SRE overview, FinOps); access with GitHub sign-in (ADR 0011).

**SLOs:** availability 99.9%, and p95 latency under 1 second.

## Consequences
- **Delivery is proven:** Alertmanager had delivered 47 (staging) and 32 (production) notifications to Discord by 26 Nov 2026 with no failures, and the CloudWatch path delivers through the Lambda.
- **User-facing alerts:** alerts are tied to user impact and a business target, so non-engineers can follow them.
- **Two paths:** the Prometheus path can't see a cluster that is down, and CloudWatch covers that from outside.
- **Known limitations:**
  - **No Container Insights agent:** the Container Insights log groups receive nothing, so the four "app error burst" alarms, which read that log group, cannot fire. Application logs live in Loki.
  - **No application metrics in production:** the app has no ServiceMonitor there, so the SLOs are measured from the probe and the ALB.
  - **Short retention:** Prometheus and Loki keep 7 days, which is enough for the course but short for audits.
- **Runbooks:** `docs/sre/runbooks/`.
