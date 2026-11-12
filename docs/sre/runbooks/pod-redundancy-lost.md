# Runbook: Pod Redundancy Lost

## 1. Purpose

This runbook describes how the on-call SRE investigates and responds when a CareLink application service has fewer than two running pods.

The service may still be available with one running pod, but redundancy is lost and the service has become a single point of failure.

## 2. Alert Details

- Alert name: `<service>-redundancy-lost`
- Monitoring system: AWS CloudWatch Container Insights
- Metric: `service_number_of_running_pods`
- Threshold: Fewer than 2 running pods
- Evaluation: 2 consecutive 60-second periods
- Notification: Amazon SNS email notification

Affected services:
- api-gateway
- customers-service
- vets-service
- visits-service

## 3. Initial Response

1. Acknowledge the alert.
2. Identify the affected service and environment.
3. Check whether the application is still responding.
4. Check whether other services are affected.
5. Record the alert time and current running pod count.

## 4. Diagnosis

Check pod status:

`kubectl get pods -n staging`

Check the affected deployment:

`kubectl get deployment <service> -n staging`

Check the number of desired and available replicas:

`kubectl describe deployment <service> -n staging`

Check recent pod events:

`kubectl get events -n staging --sort-by=.lastTimestamp`

Investigate possible causes:
- Pod crashes or CrashLoopBackOff.
- Failed readiness or liveness probes.
- Insufficient cluster resources.
- Image pull failures.
- Node failure or scheduling problems.
- Recent application deployment issues.

Check the affected pod logs:

`kubectl logs -n staging <pod-name> --previous`

Use `--previous` when the container has restarted and previous logs are available.

## 5. Mitigation

Depending on the cause:

- Resolve application configuration or startup problems.
- Investigate failed health probes.
- Restore unavailable cluster capacity through the approved infrastructure procedure.
- Investigate image pull or deployment configuration failures.
- Escalate application-related failures to the application developer.

Do not manually change replica counts or restart workloads without checking the deployment configuration and following the team's change procedure.

## 6. Verification

1. Confirm that at least two pods are running.
2. Check that the deployment has the expected available replicas.
3. Confirm that the application responds normally.
4. Verify that the CloudWatch alarm returns to OK.
5. Record the recovery time and actions taken.

## 7. Escalation

Escalate unresolved application issues to the application developer and incident commander.

Escalate node, cluster capacity, or infrastructure issues to the responsible infrastructure owner.

## 8. Incident Record

Record:
- Date and time of incident.
- Affected service and environment.
- Alarm name and pod count.
- Root cause.
- Actions taken.
- Recovery time.
- Follow-up actions.
