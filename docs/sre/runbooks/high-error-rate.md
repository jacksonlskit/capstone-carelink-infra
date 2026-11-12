# Runbook: High Application Error Rate

## 1. Purpose

This runbook describes how the on-call SRE investigates and responds
when a CareLink application service produces an unusually high number
of ERROR log entries.

## 2. Alert Details

Alert name: `<service>-error-burst`

Monitoring system: AWS CloudWatch

Metric namespace: `Carelink/<environment>`

Threshold: More than 20 ERROR log lines per 5 minutes.

Evaluation: 2 out of 3 evaluation periods.

Notification: Amazon SNS email notification.

Affected services:
- api-gateway
- customers-service
- vets-service
- visits-service

## 3. Initial Response

1. Acknowledge the alert.
2. Identify which CareLink service triggered it.
3. Record the alert time and affected environment.
4. Check whether users are experiencing failed requests.
5. Check whether other services are reporting errors.

## 4. Diagnosis

Check the affected service's pod status:

`kubectl get pods -n staging`

Check recent application logs:

`kubectl logs -n staging deployment/<service> --since=15m`

Look for:
- Repeated ERROR messages.
- Database connection failures.
- HTTP 5xx responses.
- Timeout exceptions.
- Dependency or downstream service failures.

Check CloudWatch Logs Insights for the affected service's
application log group.

## 5. Mitigation

Depending on the cause:

- Investigate and resolve configuration errors.
- Restore unavailable dependencies.
- Escalate database connection or availability problems.
- Roll back a recent application deployment if it caused the errors,
  following the developer's deployment procedure.
- Escalate to the application developer when code-level investigation
  is required.

Do not restart or roll back services without understanding the
impact and following the team's change procedure.

## 6. Verification

1. Confirm that the affected service is healthy.
2. Check that application errors have reduced.
3. Verify that the CloudWatch alarm returns to OK.
4. Confirm that the CareLink application is responding normally.
5. Record the resolution and recovery time.

## 7. Escalation

Escalate unresolved application issues to the application developer
and the incident commander.

Escalate infrastructure or database issues to the responsible
infrastructure or database owner.

## 8. Incident Record

Record:
- Date and time of incident.
- Affected service and environment.
- Alarm name.
- Symptoms and root cause.
- Actions taken.
- Recovery time.
- Follow-up actions.
