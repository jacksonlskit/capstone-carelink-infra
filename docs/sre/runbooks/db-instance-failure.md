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
- Watch for stale connections: Java caches DNS and connection pools hold dead sockets. If errors persist after RDS shows `available`, force new connections by restarting/redeploying the services (`kubectl -n <environment> rollout restart deployment/<service>`), one service at a time so redundancy is kept.
- Verify: dashboard availability back to 100%, a real read and write through the app, then close out.

### 3B. Instance unrecoverable: restore (budget about 1.5-2 h)
1. Decide quickly (by T+30): restoring is the plan if the instance will not come back.
2. Restore to the latest restorable time (point in time recovery, normally within about 5 minutes of now, so **RPO of minutes**; fallback is the last daily snapshot, still inside the 24 h RPO):
   `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier <id> --target-db-instance-identifier <id>-restored --use-latest-restorable-time` (re-apply the same subnet group, security groups, parameter group and class, and add `--multi-az` in production; these are not all inherited. `scripts/restore-drill.sh` shows how to copy them from the failed instance.)
3. Restore time scales with data size; our dataset is small, so allow tens of minutes. Wait for `available`.
4. Cut over. The JDBC URL in the `carelink-db` Secret is built by Terraform from the RDS instance address and refreshed by External Secrets, so a restore under a NEW identifier gets a NEW endpoint and the apps would keep pointing at the dead one. Avoid this by restoring under the SAME identifier:
   1. Free the name: `aws rds modify-db-instance --db-instance-identifier carelink-production-mysql --new-db-instance-identifier carelink-production-mysql-failed --apply-immediately` (rename, do not delete: production has deletion protection, and the failed instance is evidence and a fallback).
   2. Once the old name is released, run the restore in step 2 with `--target-db-instance-identifier carelink-production-mysql`.
   3. The endpoint is unchanged, so only restart the services one at a time to drop stale connections: `kubectl -n production rollout restart deployment/<service>`.
5. Verify with a read and a write, check audit logging is exporting on the new instance and Multi-AZ is enabled.
6. Reconcile IaC: the restored instance is outside Terraform state. Afterwards `terraform import` it or rebuild via Terraform from the snapshot, record the drift in the post-incident review, and delete the `-failed` instance once the review is done. Speed first, tidy second.

### Preconditions and known limits (checked 23 Nov 2026)
- **Multi-AZ:** production MySQL is Multi-AZ (confirmed in the console: secondary zone us-east-1c), so section 3A is the expected path for an instance or AZ failure. Section 3B is for data loss, corruption or an unrecoverable instance. The `postgres` instance in `rds.tf` is single-AZ and appears unused (no application connections observed); this runbook covers `carelink-<env>-mysql`.
- **Credentials:** the master password lives in the RDS-managed secret. A point-in-time restore keeps the same master credentials, so the existing secret keeps working. The staging drill read the password from that secret and connected with TLS to the restored copy, which confirms it.
- **RPO evidence:** automated backups run daily at 01:00-02:00 SGT, are kept 7 days, and point-in-time restore reaches to within about 5 minutes of the failure. Both are inside the 24 h RPO.
- **Not in the drill time:** application cutover (renaming, same-endpoint restore and a rolling restart of the services). Time that separately in the next drill.

### Indicative timeline (RTO budget 4 h)

| Time | Activity |
|---|---|
| T+0 to 5 min | Alarm and email, incident declared |
| T+5 to 15 min | Diagnosis, failover vs restore decision |
| T+15 min to 2 h | Restore (3B) or watch failover (3A, done in minutes) |
| T+2 h to 2.5 h | Cutover, service restarts, verification |
| T+2.5 h to 4 h | **Buffer**, comms, confirming data integrity |

The staging restore drill (section 6) gives measured figures for the restore step: the whole database restore and data check took about 19 minutes against the 4-hour budget.

## 4. Escalation and communication
- 0-15 min: on-call SRE acts; informs team lead.
- 30 min and no clear recovery path: involve the SA (architecture) and the product owner / clinic liaison.
- If there is any sign of **data loss or unauthorised access** (not just downtime): involve the data protection officer immediately. PDPA breach-notification clocks are short (Singapore PDPC: notify within 3 calendar days once a breach is assessed as notifiable; Malaysia has introduced mandatory breach notification as well). Check current requirements with the compliance contact; this is not legal advice.

## 5. After the incident
Blameless review within 48 h: timeline, detection time vs target, what the SLO error budget lost (21.6 min monthly allowance), follow-up tickets (alarms to add, runbook fixes).

## 6. Drill record

Run with `scripts/restore-drill.sh` against staging (single-AZ `db.t4g.small`, 20 GiB). The restored copy was deleted afterwards.

| Item | Value |
|---|---|
| Date / environment | 2026-11-22 (UTC) / staging, instance `carelink-staging-mysql` |
| Restore method (PITR or snapshot) | Point-in-time restore, `--use-latest-restorable-time`, restored to a new instance `carelink-staging-mysql-drill` |
| Start time to `available` | 14 min 48 s |
| Start time to data verified through the data path | 18 min 54 s (excludes application cutover) |
| Data check (row counts before/after) | Match: owners 15, pets 13, vets 6, visits 4 (same on source and restored copy) |
| Total elapsed vs 4 h RTO | About 19 min of 240 min for the restore and data check; application cutover not measured |

Honest limits: the drill used a small, synthetic dataset, so production restore time may be longer with more data. It did not time the same-endpoint cutover in step 4 of section 3B.
