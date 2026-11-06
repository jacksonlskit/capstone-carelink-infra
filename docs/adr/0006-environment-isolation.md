# ADR 0006: Staging and production isolation

- **Status:** Proposed: **team must choose and confirm**. Written assuming Option B because it is what the current account setup supports. Replace with Option A if separate accounts are created.
- **Date:** 2026-10-23
- **Owner:** DevSecOps Engineer with Solutions Architect

## Context
The brief requires different credentials per environment and that staging credentials must not be able to touch production. At the time of review, both environment roles had AdministratorAccess in one AWS account and shared a wildcard trust policy (`repo:<owner>*`), so a staging job could assume the production role and modify production resources or read its state.

## Decision
**Option B (current account, hardened):** four roles (staging apply, production apply, read-only plan, read-only SRE), each trusting only its own GitHub claim; separate state keys per environment (`staging/infra/...`, `production/infra/...`); explicit denies so the staging role cannot read production state or act on resources tagged `Environment=production`; both apply roles are denied edits to the pipeline roles and OIDC provider; a provider `allowed_account_ids` guard-rail per environment.

**Option A (upgrade path):** separate AWS accounts for staging and production under AWS Organizations, with the production role existing only in the production account. This is the strongest isolation and is the answer to give for "how would you do this in a real client engagement".

## Consequences
- Option B is quick to implement and demonstrable (a deliberate cross-environment assume-role attempt fails), but relies on tag-based denies that only cover services supporting resource tags, and both environments still share one account's quotas and blast radius.
- Option A costs account setup time and cross-account state access design.
- Evidence for the panel: the trust policy JSON, the failed cross-environment attempt, and the policy documents above.
