# ADR 0006: Staging and production isolation

- **Status:** Accepted, Option B, partly implemented (21 Nov 2026, see "Implementation status" below). Option A stays the upgrade path.
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

## Implementation status (21 Nov 2026)
Done (`oicd-bootstrap/main.tf` unless noted):
- **One role per environment, each trusting only its own GitHub environment.** The trust policies match GitHub's immutable OIDC subject exactly, with no wildcards: the staging role accepts only `repo:<owner>@<owner id>/<repo>@<repo id>:environment:staging` and the production role only `...:environment:production`, for the infra and app repositories. So staging jobs cannot assume the production role, jobs without an environment get no AWS access, and no other repository can use either role. Production jobs only start after the required reviewer approves. Applied on 21 Nov 2026 and tested with an infra pipeline run in each environment.
- **Separate state per environment, enforced by the bucket policy:** only the pipeline roles may write state, the staging role cannot write `production/*` and the production role cannot write `staging/*`; local applies are refused.
- **Reviewed merges on the app repository's main:** someone other than the last pusher must approve (`require_last_push_approval`), as on the infra repository, so code pushed after an approval cannot be merged unreviewed.
- **Cluster access per environment** (`infra/eks.tf`, `cluster_access` in `infra/variables.tf`): in production only the DevOps owner (plus the pipeline role, as cluster creator) is cluster admin; the other team members are view-only and cannot read Secrets. Staging keeps the whole team as admins. Because the list is code, production access only changes through a reviewed pull request. Limit: every cohort member still has AdministratorAccess in the shared AWS account and could grant themselves access through the EKS API; Option A (a separate production account) removes that.

Not done yet (known gaps, in priority order):
- **The deployment branches `env/staging` and `env/production` are not protected by GitHub.** The planned ruleset (only the app pipeline may write them) cannot be created here: the pipeline pushes as the GitHub Actions app, and GitHub accepts an app as a bypass actor only in an organization that owns the repository. These repositories belong to a personal account, so the apply was refused (422, see the comment in `oicd-bootstrap/main.tf`). Someone with write access to the app repository could therefore push to `env/production`, and Argo CD would deploy it without a review or the production approval. What limits this today: only `cd.yaml` (through `scripts/promote.sh`) writes these branches, by team rule; every deployment commit names the pipeline run that made it, so `git log origin/env/production` is the deployment history and an unexpected commit stands out; production pipeline runs need the required reviewer's approval. Fix: move both repositories into a GitHub organization, where the ruleset works as written, or let the production Argo CD application sync only when an approved pipeline run asks for that exact revision.
- Both pipeline roles still have `AdministratorAccess`; scope them per environment (and add the read-only plan and SRE roles), or deny the staging role on resources tagged `Environment=production`.
- No `allowed_account_ids` guard-rail in the providers.
