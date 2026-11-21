# ADR 0002: Keyless pipeline credentials with GitHub OIDC

- **Status:** Accepted
- **Date:** 2026-11-22 (records a decision taken in October; trust tightened on 21 Nov)
- **Owner:** DevSecOps Engineer

## Context
The infra and app pipelines need AWS access in two environments. The brief requires per-environment credentials, no secrets in code, and that staging credentials cannot touch production. Long-lived access keys stored in GitHub would have to be rotated and could leak.

## Decision
- An IAM OIDC provider for `token.actions.githubusercontent.com` and one role per environment, `carelink-github-staging-role` and `carelink-github-production-role`, created by `oicd-bootstrap/main.tf`.
- Each role trusts only its own GitHub environment, matched exactly (`StringEquals`, no wildcards) on GitHub's immutable subject `repo:<owner>@<owner id>/<repo>@<repo id>:environment:<environment>`, for the infra and app repositories.
- Every job that uses AWS runs in a GitHub environment, which holds that environment's role ARN (`AWS_ROLE_ARN`). The `production` environment requires the DevOps owner's approval.
- Credentials are short-lived: each job gets temporary STS credentials for about an hour.

## Alternatives considered
- **IAM user access keys as GitHub secrets:** simple, but long-lived, need rotation, and anyone who can edit a workflow can exfiltrate them.
- **A wildcard trust such as `repo:<owner>*`:** what the roles used until 21 Nov; any branch or repository of the owner could assume either role, including production.
- **Self-hosted runners with instance roles:** no tokens at all, but runners to build, patch and secure.

## Consequences
- No AWS keys are stored anywhere. A staging job cannot assume the production role, and a job without an environment gets no AWS access (tested 21 Nov in both environments).
- The bootstrap creates the roles the pipelines use, so it is applied locally by the DevOps owner and its state stays on that machine.
- Renaming or transferring a repository changes its immutable ID: the bootstrap must be re-applied.
- Still open (ADR 0006): both roles have AdministratorAccess in the shared account.
