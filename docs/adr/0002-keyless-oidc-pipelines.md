# ADR 0002: Keyless pipeline credentials with GitHub OIDC

**Status:** Accepted

**Date:** 2026-11-22

## Context
The infra and app pipelines (GitHub Actions) need AWS access in two environments. The brief requires:
- different credentials per environment;
- no secrets in code;
- staging credentials that cannot touch production.

Long-lived access keys stored in GitHub would have to be rotated, and anyone able to change a workflow could copy them. Both environments live in one shared cohort AWS account.

## Options Considered
**1. GitHub OIDC with one IAM role per environment, exact trust**
- For:
  - No stored keys at all.
  - Each job gets temporary STS credentials (about an hour).
  - Each role can trust exactly one GitHub environment, so staging jobs cannot assume the production role.
  - The production GitHub environment adds a human approval.
- Against:
  - The trust policies must be precise. A wildcard defeats the purpose.
  - The roles are created outside the pipelines (bootstrap), by the DevOps owner.

**2. IAM user access keys stored as GitHub secrets**
- For: simple and familiar.
- Against: long-lived keys that need rotation, and any workflow change can exfiltrate them.

**3. OIDC with a wildcard trust (`repo:<owner>*`)**
- For: quick to set up. This is what the roles used until 21 Nov.
- Against: any branch, job or repository of the owner could assume either role, including production.

**4. Self-hosted runners with instance roles**
- For: no tokens at all.
- Against: runners to build, patch and secure, and they would also be wiped every night.

## Decision
Option 1, created by `oicd-bootstrap/main.tf`:
- **Provider and roles:** an IAM OIDC provider for `token.actions.githubusercontent.com`, and the roles `carelink-github-staging-role` and `carelink-github-production-role`.
- **Exact trust:** each role trusts only its own GitHub environment, matched exactly (`StringEquals`, no wildcards) on GitHub's immutable subject `repo:<owner>@<owner id>/<repo>@<repo id>:environment:<environment>`, for the infra and app repositories.
- **Environments:** every job that uses AWS runs in a GitHub environment, which holds that environment's role ARN (`AWS_ROLE_ARN`). The `production` environment requires the DevOps owner's approval.

## Consequences
- **No keys anywhere:** no AWS access keys are stored anywhere.
- **Isolation, tested 21 Nov in both environments:** a staging job cannot assume the production role, and a job without an environment gets no AWS access.
- **Bootstrap:** it creates the roles the pipelines use, so it is applied locally by the DevOps owner, and its state stays on that machine.
- **Renames:** renaming or transferring a repository changes its immutable ID, so the bootstrap must be re-applied.
- **Still open (ADR 0006):** both roles have AdministratorAccess in the shared account.
