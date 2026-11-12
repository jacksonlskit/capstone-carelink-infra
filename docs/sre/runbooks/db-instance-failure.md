# Runbook: production database instance failure

Scenario from the brief: *"It's 9am Monday and your database instance just died. Walk me through the next four hours."*
Targets: **RTO <= 4 h, RPO <= 24 h.** Owner: on-call SRE. Escalation: incident commander (team lead), then SA.

## 1. Detection (target: under 5 minutes)

Any of these reaches the on-call email:
- RDS event subscription: failover / failure / availability event.
- `slo-availability-fast-burn` or `<service>-error-burst` (apps cannot reach the DB: connection errors).
- `rds-*` alarms; dashboard database tiles flat or red.

Declare an incident, note the time (this is T+0 for the RTO clock), tell the clinics' contact there is an issue and an update is coming.

## 2. Diagnosis (T+5 to T+15)

1. What does RDS say? `aws rds describe-db-instances --db-instance-identifier <id> --query 'DBInstances[0].[DBInstanceStatus,AvailabilityZone,MultiAZ]'` and `aws rds describe-events --source-type db-instance --source-identifier <id> --duration 120`.
2. Is it a failover in progress? Status `rebooting`/`failing-over` plus a "Multi-AZ instance failover started" event = **automatic recovery under way**, go to 3A.
3. Status `failed`, `storage-full`, `incompatible-*`, or no standby / corruption suspected = go to 3B.
4. What do the apps say? Logs Insights on the service log groups for connection errors; check security group, subnet and secret did not change (recent Terraform apply? `git log`, CloudTrail).

## 3. Mitigation

### 3A. Multi-AZ failover (expected case, minutes)
- RDS promotes the standby; the endpoint DNS name stays the same and re-points, typically in 1-2 minutes. Replication was synchronous, so **data loss is about zero**.
- Watch for stale connections: Java caches DNS and connection pools hold dead sockets. If errors persist after RDS shows `available`, force new connections by restarting/redeploying the services (`kubectl -n staging rollout restart deployment/<service>`), one service at a time so redundancy is kept.
- Verify: dashboard availability back to 100%, a real read and write through the app, then close out.

### 3B. Instance unrecoverable: restore (budget about 1.5-2 h)
1. Decide quickly (by T+30): restoring is the plan if the instance will not come back.
2. Restore to the latest restorable time (point in time recovery, normally within about 5 minutes of now, so **RPO of minutes**; fallback is the last daily snapshot, still inside the 24 h RPO):
   `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier <id> --target-db-instance-identifier <id>-restored --use-latest-restorable-time` (re-apply the same subnet group, security group, encryption key, parameter group, Multi-AZ; these are not all inherited).
3. Restore time scales with data size; our dataset is small, so allow tens of minutes. Wait for `available`.
4. Cut over: update the DB endpoint in the secret/config the services read (this is why the app should use a stable private DNS name or Secrets Manager value rather than a hard-coded endpoint), redeploy services one at a time.
5. Verify with a read and a write, check audit logging is exporting on the new instance and Multi-AZ is enabled.
6. Reconcile IaC: the restored instance is outside Terraform state. Afterwards `terraform import` it or rebuild via Terraform from the snapshot, and record the drift in the post-incident review. Speed first, tidy second.

### Indicative timeline (RTO budget 4 h)

| Time | Activity |
|---|---|
| T+0 to 5 min | Alarm and email, incident declared |
| T+5 to 15 min | Diagnosis, failover vs restore decision |
| T+15 min to 2 h | Restore (3B) or watch failover (3A, done in minutes) |
| T+2 h to 2.5 h | Cutover, service restarts, verification |
| T+2.5 h to 4 h | **Buffer**, comms, confirming data integrity |

Our demo target is to restore in staging and record the elapsed time, which makes the table above evidence instead of estimates.

## 4. Escalation and communication
- 0-15 min: on-call SRE acts; informs team lead.
- 30 min and no clear recovery path: involve the SA (architecture) and the product owner / clinic liaison.
- If there is any sign of **data loss or unauthorised access** (not just downtime): involve the data protection officer immediately. PDPA breach-notification clocks are short (Singapore PDPC: notify within 3 calendar days once a breach is assessed as notifiable; Malaysia has introduced mandatory breach notification as well). Check current requirements with the compliance contact; this is not legal advice.

## 5. After the incident
Blameless review within 48 h: timeline, detection time vs target, what the SLO error budget lost (21.6 min monthly allowance), follow-up tickets (alarms to add, runbook fixes).

## 6. Drill record (fill in during the restore demo)

| Item | Value |
|---|---|
| Date / environment | |
| Restore method (PITR or snapshot) | |
| Start time to `available` | |
| Start time to application verified | |
| Data check (row counts before/after) | |
| Total elapsed vs 4 h RTO | |
