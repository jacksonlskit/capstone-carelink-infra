# SLIs, SLOs and alerting (SRE deliverables 4 and 5)

## SLIs and SLOs

| SLI | How measured | SLO | Why this target |
|---|---|---|---|
| **Availability** | % of requests at the ALB that do not return 5xx (target 5xx + ALB-generated 5xx) | **99.9%** during clinic hours 08:00-20:00 SGT, rolling 30 days | Brief hard constraint. Clinics cannot see patients when the platform is down. |
| **Latency** | p95 `TargetResponseTime` per 5-minute window | **p95 <= 1 s** | A receptionist booking a patient waits on every page; beyond about a second the tool feels broken. Not a brief constraint: our own, tunable (`slo_latency_p95_seconds`). |

**Error budget arithmetic.** Clinic hours are 12 h/day, so 30 days = 360 h = 21,600 minutes. 0.1% of that is **21.6 minutes** of allowed full outage per 30 days. Outside clinic hours the SLO does not apply (but we still alert by default, see below).

## Alerts (all go to SNS, then email; encrypted topic)

| Alarm | Condition | Severity | Ties to |
|---|---|---|---|
| `slo-availability-fast-burn` | error rate > **1.44%** (14.4 x the 0.1% budget) in 4 of 6 five-minute windows | PAGE | Availability SLO. At this rate the whole monthly budget is gone in 360/14.4 = **25 clinic hours**. |
| `slo-availability-slow-burn` | error rate > **0.6%** (6 x budget) in 5 of 6 one-hour windows | TICKET | Availability SLO. Budget gone in 360/6 = **60 clinic hours**: slow leak worth fixing this week. |
| `slo-latency-p95` | p95 > 1 s in 3 of 5 five-minute windows | PAGE | Latency SLO |
| `<service>-redundancy-lost` | running pods < 2 for 2 minutes (Container Insights `service_number_of_running_pods`) | PAGE | No-SPOF constraint. **Live demo trigger**: scale a service to 1 replica. |
| `<service>-error-burst` | > 20 ERROR log lines in 5 minutes (2 of 3) | PAGE | Early application failure signal from logs |
| `rds-cpu`, `rds-free-storage`, `rds-freeable-memory` | saturation thresholds | PAGE | Database failure modes that cause outages |
| RDS event subscription | failover, failure, availability, low storage, recovery, restoration, backup | INFO/PAGE | "Database died at 9am Monday": we learn from the event, not a phone call |
| Security: root usage, AccessDenied burst, console login without MFA | CloudTrail metric filters | PAGE | "Who accessed production and how would you know?" |

**Why burn-rate alerts instead of "error rate > X"?** They answer "how fast are we spending the budget the business agreed to?" A brief blip does not page anyone; a sustained problem that would blow the SLO does. Thresholds come from the SLO variable, so changing the SLO changes the alerts.

**Known simplification (say it if asked):** textbook multi-window burn-rate alerting combines a long and a short window with AND (composite alarm) to cut flapping. We use sustained-datapoint rules (4 of 6, 5 of 6), which is simpler to explain and operate; composite alarms are the next step.

**Clinic-hours gating.** `alert_clinic_hours_only = true` makes the burn alarms count only 00:00-12:00 UTC (= 08:00-20:00 SGT). Default is `false` so a demo outside clinic hours still fires. Decide per environment and say why: out-of-hours failures do not burn the SLO budget, but still deserve a look before the morning. The HOUR() metric-math gating should be tested once in the console after first apply.

## Live alert demo (rehearse this)

1. Confirm the SNS email subscription is **Confirmed** (not PendingConfirmation).
2. Open the dashboard; all tiles green.
3. On staging: `kubectl -n petclinic scale deployment/<service> --replicas=1` (or drain one node: `kubectl drain <node> --ignore-daemonsets`). Show the site still responds. Note: merely deleting a pod self-heals in seconds, usually faster than the 2-minute alarm window, so use it to show self-healing, not to trip the alert.
4. Within about 2-3 minutes `<service>-redundancy-lost` goes red and the email arrives. Scale back to 2: the tile returns green and an OK email follows.
5. Optional second alert: force an error burst or p95 breach with the load generator.

## Centralised logging

- One central group for all pods (Container Insights / Fluent Bit): `/aws/containerinsights/<cluster>/application`, KMS-encrypted, retention **90 days** (staging 14); per-service ERROR metric filters read the container name from each record. Patient identifiers may leak into application logs, so retention is kept as short as operations allow.
- Database audit and error logs: `/aws/rds/instance/<id>/audit|error`, retention **365 days** (staging 90): this is the evidence trail for who touched patient data. The `general` log is deliberately not exported because it records every statement.
- Search with CloudWatch Logs Insights; the dashboard has a last-50-errors table across all services.
