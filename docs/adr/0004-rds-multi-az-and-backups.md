# ADR 0004: Database: RDS MySQL, Multi-AZ in production, backups everywhere

**Status:** Accepted

**Date:** 2026-11-22

## Context
The application needs a persistent MySQL database (the brief does not accept the in-memory HSQLDB). The brief requires:
- 99.9% availability in clinic hours, and no single point of failure in production;
- RPO of 24 hours or less, RTO of 4 hours or less, and a demonstrated restore;
- encryption at rest and in transit;
- a database that is not publicly accessible.

Staging can be a cost-reduced copy.

## Options Considered
**1. Amazon RDS for MySQL, Multi-AZ in production, single-AZ in staging**
- For:
  - Managed backups, point-in-time recovery, patching and encryption.
  - A synchronous standby in another AZ with automatic failover in production.
  - Staging stays cheaper.
- Against:
  - Multi-AZ doubles the production database's instance and storage cost.
  - MySQL 8.0 is now billed RDS Extended Support (ADR 0009).

**2. Amazon Aurora MySQL**
- For: faster failover and storage replicated across three AZs.
- Against: a higher minimum cost than this workload needs.

**3. MySQL in Kubernetes (StatefulSet)**
- For: cheaper on paper.
- Against: backups, failover, patching and encryption would all be ours to build and prove.

**4. Single-AZ RDS in production too**
- For: cheaper.
- Against: an AZ or instance failure would take the application down, which fails the no-single-point-of-failure constraint.

## Decision
Option 1 (`infra/rds.tf`):
- **Engine and size:** RDS for MySQL 8.0 (`db.t4g.small`), one instance per environment.
- **High availability:** production is Multi-AZ (`multi_az_in_production`, converted on 22 Nov 2026). Staging is single-AZ.
- **Backups:** automated for 7 days, with point-in-time recovery; backup window 17:00–18:00 UTC (01:00–02:00 SGT).
- **Production safeguards:** deletion protection, a final snapshot if deleted, and changes applied in the maintenance window (Sunday 18:30–19:30 UTC) rather than immediately.
- **Encryption:** storage uses the `rds` KMS key. The master password is generated into Secrets Manager (`secrets` KMS key) and reaches the application through External Secrets, never through code or state.
- **Network:** TLS required for every connection (`require_secure_transport`); private subnets only; the security group allows the database port only from the private subnets.

## Consequences
- **RPO:** minutes, thanks to point-in-time recovery.
- **Failover:** an instance or AZ failure in production fails over in minutes, well within the 4-hour RTO. A failover has not been rehearsed yet, because it means 1–2 minutes of production downtime.
- **Restore, demonstrated in staging on 22 Nov 2026:** a point-in-time restore was available after 14 min 48 s and verified after 18 min 54 s, with row counts matching the source. Runbook: `docs/sre/runbooks/db-instance-failure.md`.
- **Cost:** Multi-AZ doubles the production database's cost.
- **Not yet enabled:** database audit logging (only the `error` and `slowquery` logs are exported).
- **Cleanup candidates:** two PostgreSQL instances defined next to MySQL in `var.databases` are not used by the application.
