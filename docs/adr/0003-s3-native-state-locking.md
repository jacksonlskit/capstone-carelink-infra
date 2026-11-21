# ADR 0003: Terraform state in S3 with native locking

- **Status:** Accepted
- **Date:** 2026-11-22 (records a decision taken in October)
- **Owner:** DevOps Engineer

## Context
Two environments share one AWS account. Their Terraform state must be durable, encrypted, separate per environment, and locked so that a pull-request plan and a deployment never write at the same time. The instructors' nightly cleanup also deletes the state objects, so the design has to survive losing them.

## Decision
- One S3 bucket created by the bootstrap: versioning on, server-side encryption (AES256), public access blocked.
- One state key per environment, passed by the pipelines: `staging/terraform.tfstate` and `production/terraform.tfstate`.
- **S3 native locking** (`use_lockfile = true` in `infra/backend.tf`, Terraform 1.10 or newer): the lock is a `.tflock` object written with a conditional request.
- The bucket policy lets only the two pipeline roles write state, and neither role can write the other environment's key. A laptop can still run `terraform plan -lock=false`, but cannot apply.
- After the nightly cleanup, `scripts/recover-state.sh` and `scripts/generate-imports.sh` adopt the resources that still exist (import blocks), so nothing is recreated or duplicated.

## Alternatives considered
- **A DynamoDB lock table:** the classic setup, but an extra resource to pay for, protect from the cleanup and keep in sync; native S3 locking makes it unnecessary.
- **Terraform Cloud / HCP:** an external service with its own credentials and cost.
- **Local state:** no collaboration and no pipeline.

## Consequences
- No lock table to manage. A stuck lock is one `.tflock` object; the break-glass steps are in the comments of `oicd-bootstrap/main.tf`.
- State can only change through the reviewed pipelines.
- A wiped state is rebuilt by import, not by creating new resources. Before the `Project` tag and the import scripts existed (until 12 Nov), each rebuild created a new VPC; the leftovers were removed on 21 Nov.
