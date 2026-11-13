# Hard-constraint compliance mapping (CareLink Health, Use Case B)

*Draft 25 Oct 2026 by Jon (SRE). Written against infra repo commit 8d95781 (files in `infra/`) plus the SRE files in this pack. **Status is honest, not aspirational**: the brief says "it works" is not a defence against "it violates the constraint", and every row must end up demonstrable live. Update the Status column as gaps close; delete this banner before submission.*

**Status legend:** **Met in code** = the Terraform does it (still prove it live). **Partial** = some of it. **Gap** = not in the code yet (owner in brackets). **Not built** = depends on something not yet written. Gap references (A1, C2...) point to `REPO-FINDINGS.md`.

## Constraint 1: Availability 99.9% in clinic hours (08:00-20:00 SGT), no single point of failure, survive loss of one application instance

| Requirement | Design decision and where | Status | Evidence to show live |
|---|---|---|---|
| Targets and measurement | Availability and latency SLIs/SLOs; burn-rate alarms (`monitoring.tf`: `slo_availability_burn`, `slo_latency_p95`); 99.9% = 21.6 min per 30 clinic-hour days | **Not built** until an ALB exists (C2); alarms are written | Dashboard SLI vs SLO line; alarm list; SLO arithmetic on paper |
| Multi-AZ network | VPC with 3 public + 3 private subnets over 3 AZs (`vpc.tf`) | **Met in code** | `aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc>` showing 3 AZs |
| Nodes spread across AZs | Managed node group uses all 3 private subnets; both environments `min_size = 4`, `desired_size = 5` (`eks.tf`) | **Likely met**: 4+ nodes span all 3 private subnets; confirm with the command in the next column | `kubectl get nodes -L topology.kubernetes.io/zone` |
| 2+ replicas per service on different nodes | App deployment settings (replicas, pod anti-affinity or topology spread, PodDisruptionBudget): **not in the infra repo** | **Gap** [Jack] | `kubectl get pods -o wide` showing pods on different nodes/AZs |
| Database tier survives an instance/AZ loss | RDS `multi_az = var.rds_multi_az`, default `false`, tfvars empty (`rds.tf`, `variables.tf`) | **Gap**: production would deploy single-AZ (A1) [Krisna] | `aws rds describe-db-instances --query 'DBInstances[].[DBInstanceIdentifier,MultiAZ]'` must show `true` in production |
| NAT tier survives an AZ loss | `single_nat_gateway` default `true` (`vpc.tf`); production intends one per AZ | **Gap** until the variable is set from the environment (A1) [Krisna] | Three NAT gateways in three AZs |
| Public entry point | ALB from the app repo's Ingress (`k8s/overlays/staging/ingress.yaml`) via the AWS Load Balancer Controller (`helm_release.lbc` in `lbc.tf`); hostname `carelink-<env>.sctp-sandbox.com` kept pointed at the day's ALB by external-dns (`dns.tf`) | **Met in staging**; production has the controller but no Ingress yet [Jack] | `kubectl -n staging get ingress`; ALB across 3 AZs; https://carelink-staging.sctp-sandbox.com |
| **Demonstrate loss of one instance** | Scale a service to 1 replica or `kubectl drain` one node in production; alarm `<service>-redundancy-lost` emails (`monitoring.tf`) | **Not demonstrable yet** (needs app, nodes >= 2, add-on for pod metrics: C3) | Site keeps responding during the drill, email arrives, dashboard tile red then green |

## Constraint 2: Data protection (encrypted at rest and in transit, database not public, production access restricted and logged)

| Requirement | Design decision and where | Status | Evidence to show live |
|---|---|---|---|
| Encrypted at rest: database | `storage_encrypted = true` with CMK `kms.tf` "rds" key; master secret encrypted with the "secrets" CMK (`rds.tf`); KMS rotation on | **Met in code** | `describe-db-instances` -> `StorageEncrypted: true`, `KmsKeyId`; key rotation status |
| Encrypted at rest: node disks | Node group uses a Terraform launch template (`aws_launch_template.nodes` in `eks.tf`) whose root volume is `encrypted = true` with the "ebs" CMK (`kms.tf`, rotation on); IMDSv2 required | **Met in code** (C5 closed) [Jack] | `aws ec2 describe-volumes --filters Name=tag:eks:cluster-name,Values=carelink-staging-eks --query 'Volumes[].[VolumeId,Encrypted,KmsKeyId]'` shows `True` and the `alias/carelink-staging-ebs` key |
| Encrypted at rest: logs, alerts, state | CMK on log groups and SNS (`monitoring.tf`); S3 state bucket SSE-AES256 and versioning (`oicd-bootstrap`) | **Met in code** (monitoring files not merged yet) | Log group `kmsKeyId`; SNS `KmsMasterKeyId` |
| Encrypted in transit: users to service | HTTPS listener with a DNS-validated ACM certificate (`oicd-bootstrap/main.tf`, kept there because certificates survive the nightly wipe), policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.2/1.3 only), HTTP 301 to HTTPS (Ingress annotations) | **Met in staging**; production certificate is created, Ingress pending [Jack] | Browser padlock; `curl -I http://carelink-staging.sctp-sandbox.com` returns 301; `openssl s_client -tls1_1` refused |
| Encrypted in transit: app to database | Force TLS in DB parameter group (MySQL `require_secure_transport`, PostgreSQL `rds.force_ssl`) and app connects with TLS | **Gap** (A3) [Krisna, Jack] | A non-TLS connection is refused; app connection string shows TLS |
| Database not publicly accessible | `publicly_accessible = false`; DB subnet group uses private subnets; SG allows DB port only from private subnet CIDRs (`rds.tf`) | **Met in code** | Failed connection from the internet; SG rule listing |
| Access to production data **restricted** | Master credential in Secrets Manager (no password in code/state); but the CI production role has AdministratorAccess and could read it; no per-person DB users; EKS access entries not written (C1) | **Partial/Gap**: restrict who can `GetSecretValue`, scope CI roles, add access entries [Jack] | IAM policy simulation or `aws secretsmanager get-secret-value` denied for a non-admin identity; list of who can |
| Access **logged** (data plane) | DB audit logging is **not enabled** (only error/slowquery or postgresql/upgrade exported) (A2); log groups with 365-day retention are ready in `monitoring.tf` | **Gap** [Krisna] | Audit log group showing a connection/query event |
| Access **logged** (control plane) | CloudTrail not in the repo (C4); alarms for root use / AccessDenied / no-MFA login are written (`monitoring.tf`, off until `monitor_cloudtrail`) | **Not built** [SA/Jack] | CloudTrail event for a role assumption or secret read |
| Data residency (PDPA) | Deployed in **us-east-1** by team decision for the capstone (synthetic data only); ADR 0007 states the production-intent position | **Accepted limitation**, documented | ADR 0007; `aws_region` in `variables.tf` |

## Constraint 3: Recovery (RPO <= 24 h, RTO <= 4 h, automated backups, demonstrated restore)

| Requirement | Design decision and where | Status | Evidence to show live |
|---|---|---|---|
| Automated backups | `backup_retention_period = var.db_backup_retention_days` (default 7), `backup_window = 17:00-18:00 UTC` (01:00-02:00 SGT), `copy_tags_to_snapshot` (`rds.tf`) | **Met in code** | `describe-db-instances` -> `BackupRetentionPeriod: 7`, `LatestRestorableTime` |
| RPO <= 24 h | Daily backup plus point-in-time recovery (automatic when retention > 0): realistic RPO of minutes; Multi-AZ synchronous standby for instance failure | **Met in code** for backups; Multi-AZ **Gap** in production (A1) | `LatestRestorableTime` within minutes of now |
| RTO <= 4 h | Failover (minutes) or restore-from-backup; runbook timeline `docs/sre/runbooks/db-instance-failure.md`, with a timed drill | **Not yet proven**: drill not run | Drill record table filled in with real timestamps |
| **Demonstrate a restore** (staging acceptable) | Take a manual snapshot (staging uses `skip_final_snapshot`, and automated backups vanish if the instance is destroyed: A6), restore it to a new instance, verify data | **Not done** [Jon/Krisna] | `restore-db-instance-from-db-snapshot` output, timings, row-count check |
| Notice a database failure quickly | RDS event subscription and saturation alarms (`monitoring.tf`) | **Written**, not merged | Test alert email; RDS event in the inbox |

## Cross-cutting evidence the panel will also ask for
| Requirement | Where | Status |
|---|---|---|
| Infrastructure as code, live state matches code | All of `infra/`; `terraform plan` shows no changes | **Met** once applied; run plan before the demo |
| Per-environment credentials, none stored long-lived | GitHub OIDC roles, environment-scoped `AWS_ROLE_ARN` (`oicd-bootstrap`) | **Partial**: both roles share a trust policy and AdministratorAccess (`REVIEW-NOTES.md` items 1-2) |
| Security gates that block | Snyk IaC at `--severity-threshold=high` in CI and CD | **Met for IaC**; SCA and container image scanning are in the app repo's pipeline [Jack] |
| Alerts to a real destination, one fired live | SNS email subscription (`monitoring.tf`) | **Written**; must be merged, confirmed and rehearsed |

## What to say when a gap is asked about
Name the gap before the panel does, state the owner, and say what you would do and how you would prove it: that scores better than a confident wrong answer, per the brief.
