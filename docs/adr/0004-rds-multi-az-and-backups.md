# ADR 0004: RDS MySQL, Multi-AZ in production, backups everywhere

- **Status:** Accepted
- **Date:** 2026-11-22 (records a decision taken in October; production Multi-AZ added on 21 Nov)
- **Owner:** Database owner with Solutions Architect

## Context
The app needs a persistent MySQL database. The brief requires 99.9% availability in clinic hours, no single point of failure in production, RPO of 24 hours or less, RTO of 4 hours or less, a demonstrated restore, encryption at rest and in transit, and a database that is not publicly accessible. Staging is a cost-reduced copy.

## Decision
- **Amazon RDS for MySQL 8.0** (`db.t4g.small`), one instance per environment (`infra/rds.tf`).
- **Production is Multi-AZ** (`multi_az_in_production`): a synchronous standby in another AZ with automatic failover. Staging stays single-AZ for cost.
- Automated backups for 7 days with point-in-time recovery; backup window 17:00-18:00 UTC (01:00-02:00 SGT).
- Production has deletion protection, takes a final snapshot if deleted, and applies changes in the maintenance window (Sunday 18:30-19:30 UTC) instead of immediately.
- Storage encrypted with the `rds` KMS key; the master password is generated into Secrets Manager (`secrets` KMS key) and reaches the app through External Secrets, never through code or state.
- TLS required for every connection (`require_secure_transport`); private subnets only, and the security group allows the database port only from the private subnets.

## Alternatives considered
- **Aurora MySQL:** faster failover and storage replication, but a higher minimum cost than this workload needs.
- **MySQL in Kubernetes (StatefulSet):** cheaper on paper, but backups, failover, patching and encryption would all be ours to build and prove.
- **Single-AZ in production:** cheaper, but an AZ or instance failure would take the app down, which fails the no-single-point-of-failure constraint.

## Consequences
- RPO is minutes (point-in-time recovery); an instance or AZ failure in production fails over in minutes, well within the 4-hour RTO.
- Multi-AZ doubles the production database's instance and storage cost.
- A restore still has to be demonstrated (staging is acceptable): runbook `docs/sre/runbooks/db-instance-failure.md`.
- Two PostgreSQL instances defined next to MySQL in `var.databases` are not used by the app; they are kept single-AZ and are candidates for removal.
