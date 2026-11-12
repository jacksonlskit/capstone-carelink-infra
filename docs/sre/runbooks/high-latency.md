# Runbook: High Application Latency

## 1. Purpose

This runbook describes how the on-call SRE investigates and responds
when CareLink application response times become unusually slow.

High latency can affect clinic staff when searching for customers,
viewing veterinary records, or booking visits.

## 2. Alert Details

- Alert name: `slo-latency-p95`
- Monitoring system: AWS CloudWatch
- Metric: Application Load Balancer `TargetResponseTime`
- Statistic: p95 (95th percentile)
- Threshold: Greater than 1 second
- Evaluation: 3 out of 5 five-minute periods
- Notification: Amazon SNS email notification

## 3. Initial Response

1. Acknowledge the alert.
2. Record the alert time and affected environment.
3. Check whether the latency affects all services or only one.
4. Check whether users are also experiencing errors or timeouts.
5. Check whether other infrastructure alarms are active.

## 4. Diagnosis

Check the application pods:

`kubectl get pods -n staging`

Check recent application logs:

`kubectl logs -n staging deployment/<service> --since=15m`

Look for:
- Slow database queries or connection problems.
- Repeated timeout messages.
- Downstream service delays.
- High request processing times.
- Application exceptions or resource pressure.

Check the CloudWatch dashboard for:
- ALB TargetResponseTime.
- Request count and HTTP 5xx errors.
- EKS node CPU and memory metrics.
- RDS CPU, freeable memory and free storage.

Compare the latency across services to identify whether the
problem is isolated or widespread.

## 5. Mitigation

Depending on the cause:

- Escalate slow database queries or database resource issues to the database owner.
- Escalate application processing or dependency issues to the application developer.
- Investigate unhealthy pods or infrastructure capacity problems.
- Roll back a recent application deployment if it is identified as the cause, following the approved deployment procedure.

Do not make production configuration or infrastructure changes
without following the team's change procedure.

## 6. Verification

1. Confirm that application response times have improved.
2. Check that p95 latency is below 1 second.
3. Verify that the CloudWatch alarm returns to OK.
4. Confirm that the CareLink application responds normally.
5. Record the recovery time and actions taken.

## 7. Escalation

Escalate unresolved application performance issues to the
application developer and incident commander.

Escalate database or infrastructure resource problems to the
responsible infrastructure or database owner.

## 8. Incident Record

Record:
- Date and time of incident.
- Affected service and environment.
- Alarm name and observed p95 latency.
- Root cause.
- Actions taken.
- Recovery time.
- Follow-up actions.
