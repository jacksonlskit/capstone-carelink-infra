# Runbook: app database on RDS (TLS, persistence, rotation)

The customers, vets and visits services use the environment's **RDS MySQL** instance (`carelink-<env>-mysql`, database `service_instance_db`) instead of an in-memory database in each pod.

```
RDS-managed secret (Secrets Manager)  --External Secrets (IRSA, read-only, this secret only)-->
Kubernetes Secret carelink-db (url, username, password)  --secretKeyRef-->  SPRING_DATASOURCE_* in the pods
```

- Defined in `infra/app-database.tf` (External Secrets, Reloader, the `carelink-db` Secret) and `infra/rds.tf` (parameter group).
- The app chart (app repo, `charts/carelink`) only references the Secret; no credential is stored in Git or Terraform state.
- MySQL refuses connections without TLS (`require_secure_transport = ON`); the app connects with `sslMode=REQUIRED`.

## One-time: switch MySQL to the TLS-only parameter group

After the infra pipeline applies the parameter group, RDS shows it as `pending-reboot`: the setting is active only after one reboot (about 1-2 minutes without database).

**Staging** (`apply_immediately = true`, so only the reboot is left):
```bash
aws rds describe-db-instances --db-instance-identifier carelink-staging-mysql --query 'DBInstances[0].DBParameterGroups[0].[DBParameterGroupName,ParameterApplyStatus]' --output text
aws rds reboot-db-instance --db-instance-identifier carelink-staging-mysql
aws rds wait db-instance-available --db-instance-identifier carelink-staging-mysql
```
Expect `carelink-staging-mysql pending-reboot` before, and `in-sync` after the reboot.

**Production** (`apply_immediately = false`, so the change waits for the Sunday maintenance window unless applied now; do this in an agreed window):
```bash
aws rds modify-db-instance --db-instance-identifier carelink-production-mysql --db-parameter-group-name carelink-production-mysql --apply-immediately
aws rds wait db-instance-available --db-instance-identifier carelink-production-mysql
aws rds reboot-db-instance --db-instance-identifier carelink-production-mysql
aws rds wait db-instance-available --db-instance-identifier carelink-production-mysql
```
This sets exactly what Terraform already wants, so it creates no drift.

## Prove it (demo / evidence)

From the app repo, with `kubectl` pointed at the environment's cluster:
```bash
scripts/test-db-persistence.sh staging --tls
```
It writes an owner through the public API, reads it back 10 times (both customers-service pods), deletes **every** app pod, waits for them to return and reads the owner again. With `--tls` it also shows a MySQL client being refused without TLS (`ERROR 3159 ... insecure transport are prohibited`) and connecting with TLS.

## Password rotation

RDS rotates the master password every 7 days. External Secrets re-reads it every 5 minutes and updates `carelink-db`; Reloader then restarts the app pods one at a time (PodDisruptionBudgets keep one pod per service serving). Between the rotation and the restart (at most about 5 minutes), connections the pods already hold keep working, but new ones fail.

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| App pods `CreateContainerConfigError` | Secret `carelink-db` missing | `kubectl -n <env> get externalsecret carelink-db` must show `SecretSynced`. If `SecretSyncedError`: the operator's IAM role lost its policy (nightly cleanup); re-run the infra pipeline |
| Pods crash with `Access denied for user` | Password rotated, pods not restarted yet | `kubectl -n kube-system logs deploy/reloader-reloader`; restart manually: `kubectl -n <env> rollout restart deploy` |
| `Communications link failure` | Security group or DB down | `aws rds describe-db-instances --db-instance-identifier carelink-<env>-mysql --query 'DBInstances[0].DBInstanceStatus'`; see `db-instance-failure.md` |
| After the nightly cleanup, External Secrets shows `AccessDenied` | Its IAM policy was removed (tags cannot protect policies) | The existing Secret keeps the app running; the morning infra pipeline restores the policy |

## Known limits (state them in Q&A)

- The app uses the RDS **master** user. A least-privilege app user with access to `service_instance_db` only is the next step.
- `sslMode=REQUIRED` encrypts but does not verify the server certificate. Verifying it needs the RDS CA bundle in the app's truststore (`sslMode=VERIFY_IDENTITY`).
- The database is single-AZ (`rds_multi_az = false`). If the instance fails, the app is down until RDS replaces it (see `db-instance-failure.md`); production should be Multi-AZ.
