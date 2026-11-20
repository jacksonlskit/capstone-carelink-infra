# ADR 0006: Staging and production isolation

- **Status:** Accepted, Option B, partly implemented (20 Nov 2026, see "Implementation status" below). Option A stays the upgrade path.
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

## Implementation status (20 Nov 2026)
Done (`oicd-bootstrap/main.tf` unless noted):
- **One role per environment, each trusting only its own GitHub environment.** The trust policies match GitHub's immutable OIDC subject exactly, with no wildcards: the staging role accepts only `repo:<owner>@<owner id>/<repo>@<repo id>:environment:staging` and the production role only `...:environment:production`, for the infra and app repositories. So staging jobs cannot assume the production role, jobs without an environment get no AWS access, and no other repository can use either role. Production jobs only start after the required reviewer approves.
- **Separate state per environment, enforced by the bucket policy:** only the pipeline roles may write state, the staging role cannot write `production/*` and the production role cannot write `staging/*`; local applies are refused.
- **Deployment branches protected:** only the app pipeline may update `env/staging` and `env/production` (ruleset `app-env-branches`), so nothing reaches Argo CD without a reviewed merge.

Not done yet (known gaps, in priority order):
- Both pipeline roles still have `AdministratorAccess`; scope them per environment (and add the read-only plan and SRE roles), or deny the staging role on resources tagged `Environment=production`.
- No `allowed_account_ids` guard-rail in the providers.
