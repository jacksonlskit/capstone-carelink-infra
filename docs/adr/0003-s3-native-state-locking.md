# ADR 0003: Terraform state in S3 with native locking

**Status:** Accepted

**Date:** 2026-11-22

## Context
Two environments share one AWS account. Their Terraform state must be:
- durable and encrypted;
- separate per environment;
- locked, so that a pull-request plan and a deployment never write at the same time.

The instructors' nightly cleanup also deletes the state objects, so the design has to survive losing them. Only the reviewed pipelines should be able to change state.

## Options Considered
**1. S3 with native locking (`use_lockfile`)**
- For:
  - One bucket and nothing else.
  - The lock is a `.tflock` object written with a conditional request (Terraform 1.10 or newer).
  - A bucket policy can decide who may write which environment's state.
- Against: needs a recent Terraform version, and a stuck lock must be removed by hand (break-glass).

**2. S3 with a DynamoDB lock table**
- For: the classic, well-known setup.
- Against: an extra resource to pay for, protect from the nightly cleanup and keep in sync; native S3 locking makes it unnecessary.

**3. Terraform Cloud / HCP Terraform**
- For: hosted state, locking and runs.
- Against: an external service with its own credentials and cost, outside our AWS controls.

**4. Local state**
- For: none for a team.
- Against: no collaboration and no pipeline.

## Decision
Option 1:
- **The bucket:** one S3 bucket created by the bootstrap, with versioning on, server-side encryption (AES256) and public access blocked.
- **One key per environment**, passed by the pipelines: `staging/terraform.tfstate` and `production/terraform.tfstate`. Locking is `use_lockfile = true` in `infra/backend.tf`.
- **Writes:** the bucket policy lets only the two pipeline roles write state, and neither can write the other environment's key. A laptop can run `terraform plan -lock=false`, but cannot apply.
- **Recovery:** after the nightly cleanup, `scripts/recover-state.sh` and `scripts/generate-imports.sh` adopt the resources that still exist (import blocks), so nothing is recreated or duplicated.

## Consequences
- **No lock table to manage:** a stuck lock is one `.tflock` object, and the break-glass steps are in the comments of `oicd-bootstrap/main.tf`.
- **Only the reviewed pipelines can change state:** local applies are refused.
- **Wiped state is rebuilt by import**, not by creating new resources. Every morning's recovery run reports how many resources it imported and shows 0 destroyed.
- **Before the import scripts existed** (until 12 Nov), each rebuild created a new VPC. The leftovers were removed on 21 Nov.
