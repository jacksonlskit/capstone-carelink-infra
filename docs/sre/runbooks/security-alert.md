# Runbook: Security Alert

## 1. Purpose

This runbook describes how the on-call SRE responds to security-related
CloudWatch alarms involving AWS account activity.

These alerts help identify potentially unauthorised access or
suspicious activity affecting CareLink infrastructure.

## 2. Alert Details

Monitoring system: AWS CloudWatch

Metric namespace: `Carelink/Security`

Notification: Amazon SNS email notification.

Configured security alerts:

| Alert | Threshold | Description |
|---|---:|---|
| root-account-usage | 1 | Root account activity detected |
| unauthorized-api-calls | 5 | Burst of AccessDenied or unauthorized API calls |
| console-login-without-mfa | 1 | Successful IAM user console login without MFA |

Evaluation period: 5 minutes.

Each alarm evaluates one period and triggers when the metric
reaches or exceeds its configured threshold.

## 3. Initial Response

1. Treat the security alert as important and acknowledge it.
2. Record the alarm name, alert time and affected AWS environment.
3. Identify the account activity that triggered the alert.
4. Notify the incident commander and responsible security owner.
5. Preserve relevant CloudWatch and CloudTrail evidence.

Do not delete logs or make unapproved changes to the affected resources.

## 4. Diagnosis

Open the relevant CloudWatch alarm and identify the metric that
triggered it.

Check the configured CloudTrail log group using CloudWatch Logs Insights.

Investigate the following:

### Root account usage

- Identify the event time and AWS region.
- Examine the event name and source IP address.
- Identify the service or action involved.
- Determine whether the activity was expected or authorised.

### Unauthorized API calls

- Identify the IAM user or role involved.
- Examine the denied API actions.
- Check the source IP address and event time.
- Determine whether the activity was expected or suspicious.

### Console login without MFA

- Identify the IAM user.
- Check the login time and source IP address.
- Review the authentication details.
- Confirm whether the login was authorised.

## 5. Mitigation

If suspicious activity is confirmed:

- Escalate immediately to the security owner and incident commander.
- Follow the organisation's approved incident response procedure.
- Request the security owner to revoke or restrict compromised
  credentials where necessary.
- Review affected IAM roles, policies and resources.
- Preserve logs and evidence for investigation.

Do not independently disable accounts, delete IAM resources,
or modify production access without the appropriate authorisation.

## 6. Verification

1. Confirm that the suspicious activity has stopped.
2. Confirm that the security owner has completed the required response.
3. Review subsequent CloudTrail events for further suspicious activity.
4. Verify that the CloudWatch alarm returns to OK when appropriate.
5. Record the incident and evidence references.

## 7. Dependencies and Limitations

These alerts depend on CloudTrail events being delivered to the
configured CloudWatch log group.

The CloudTrail trail itself is owned by the SA/security team and
is not currently defined in this Terraform configuration.

The availability and delivery of CloudTrail logs must therefore
be confirmed before treating these alerts as operational.

## 8. Escalation

Escalate all suspected security incidents to the security owner
and incident commander.

Follow the organisation's security incident response and
data-protection escalation procedures.

## 9. Incident Record

Record:
- Date and time of incident.
- Alarm name and security event.
- Affected AWS account and environment.
- IAM user or role involved, if identified.
- Source IP address and event details.
- Investigation findings.
- Actions taken and responsible owner.
- Recovery or containment time.
- Follow-up actions.
