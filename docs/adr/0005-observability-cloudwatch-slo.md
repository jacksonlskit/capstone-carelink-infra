# ADR 0005: Observability on CloudWatch with SLO burn-rate alerting

- **Status:** Accepted (implemented in `infra/monitoring.tf` once the application stack exists)
- **Date:** 2026-10-23
- **Owner:** Site Reliability Engineer

## Context
The brief requires centralised searchable logs with defined retention, infrastructure and application metrics, a dashboard a non-team-member can read, at least two SLIs/SLOs, at least two alerts routed to a real destination (one triggered live), and an incident runbook. Clinics depend on the system 08:00-20:00 SGT with a 99.9% availability target, which is only about 21.6 minutes of downtime per 30 days. We are a small team and do not want monitoring servers that need their own monitoring.

## Decision
Use CloudWatch Logs, Metrics, Alarms and Dashboards, with alarms notifying an encrypted SNS topic that emails the on-call. All of it is defined in Terraform. Log groups are KMS-encrypted with retention (application 90 days, database audit 365 days). Alert on **SLO burn rate** (fast burn 14.4x = page, slow burn 6x = ticket) plus p95 latency, lost redundancy (fewer than two healthy targets), database saturation and RDS lifecycle events, rather than on raw CPU.

Alternatives considered: **Prometheus + Grafana + Alertmanager** (richer dashboards and queries, but more infrastructure to run, secure and keep alive); **OpenSearch/ELK** (powerful log search, heavy to operate and costly at small scale).

## Consequences
- No monitoring servers to operate; alarms and dashboard are reproducible from code and match the deployed system.
- Alerts reflect user impact against a stated business target, so they are explainable to non-engineers.
- Weaker ad-hoc analysis than Grafana/Loki; email-only notification unless a Slack/Telegram bridge is added; sustained-datapoint burn rules instead of full multi-window composite alarms; CloudWatch cost scales with log volume.
- Email subscriptions must be confirmed before every demo or no alert is delivered.
