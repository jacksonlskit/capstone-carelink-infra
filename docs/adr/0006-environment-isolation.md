# ADR 0006: Staging and production isolation

**Status:** Accepted (Option B, implemented in part; Option A is the upgrade path)

**Date:** 2026-11-22

## Context
The brief requires different credentials per environment, and staging credentials must not be able to touch production. Both environments run in one shared cohort AWS account, where every cohort member has AdministratorAccess.

At the time of review (October), both pipeline roles had AdministratorAccess and shared a wildcard trust (`repo:<owner>*`). So a staging job could assume the production role, modify production resources or read its state.

## Options Considered
**1. Option A: separate AWS accounts for staging and production (AWS Organizations)**
- For: the strongest isolation. The production role exists only in the production account, and a separate production account also keeps cohort members out. This is the answer for a real client engagement.
- Against: not possible in the course's shared account; needs account setup and a cross-account design for state and pipelines.

**2. Option B: one account, hardened per environment**
- For:
  - Doable now and demonstrable.
  - Exact trust per environment, separate state with write rules, per-environment cluster access, and production deployments locked behind the approval.
- Against:
  - Both environments still share one account's quotas and blast radius.
  - Anyone with AdministratorAccess in the account can still go around it.

**3. Leave it as it was**
- For: no work.
- Against: fails the brief, because staging can act on production.

## Decision
Option B now, Option A as the upgrade path.

**Done**, mostly in `oicd-bootstrap/main.tf`:
- **One role per environment, exact trust:** each role trusts only its own GitHub environment on the immutable OIDC subject (ADR 0002). Staging jobs cannot assume the production role, jobs without an environment get no AWS access, and production jobs start only after the required reviewer approves. Tested on 21 Nov 2026.
- **Separate state per environment, enforced by the bucket policy:** only the pipeline roles may write state, and neither can write the other's key. Local applies are refused (ADR 0003).
- **Reviewed merges on `main` in both repositories:** someone other than the last pusher must approve (`require_last_push_approval`).
- **Cluster access per environment** (`cluster_access` in `infra/variables.tf`, `infra/eks.tf`):
  - In production only the DevOps owner and the pipeline role are cluster admins; the rest of the team is view-only and cannot read Secrets.
  - One exception since 25 Nov: port-forward in the `monitoring` namespace only.
  - Argo CD and Grafana sign-in follow the same split: in production, the team is read-only in Argo CD and Viewer in Grafana (ADR 0010, ADR 0011).
- **Only the approved production job can write `env/production`**, the branch Argo CD deploys to production. A ruleset blocks every push except one deploy key, whose private half GitHub releases only to the approved production job on `main`. Live since 22 Nov 2026: a direct push by the repository admin was refused with `GH013`.

**Not done yet** (known gaps):
- **`env/staging` is not locked:** staging has no approval step to protect.
- **Both pipeline roles still have AdministratorAccess.** They should be scoped per environment, or the staging role denied on resources tagged `Environment=production`.
- **No `allowed_account_ids` guard-rail** in the Terraform providers.

## Consequences
- **Staging cannot change production through the pipelines**, the state or the deployment branch. Each of these was tested.
- **Production access changes only through reviewed pull requests**, because the access lists are code.
- **The shared account is the remaining hole:** every cohort member can still grant themselves access through the AWS or EKS API. Option A (a separate production account) removes that.
- **Evidence for the panel:** the trust policies, a refused cross-environment attempt, the `GH013` refusal, and `aws eks list-associated-access-policies` showing View for the team in production.
