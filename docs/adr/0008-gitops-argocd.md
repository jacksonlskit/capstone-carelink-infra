# ADR 0008: Deployment: GitOps with Argo CD and per-environment deploy branches

**Status:** Accepted

**Date:** 2026-11-12

## Context
The app pipeline deployed by running `kubectl apply -k` from GitHub Actions against the staging cluster. That had several problems:
- no production path;
- no record in Git of what runs where;
- nothing restoring the application after the instructors' nightly cleanup without re-running the pipeline;
- an unused Helm chart and Argo CD manifest in the app repository, out of date, which would have broken staging if applied.

The brief requires feature → PR → staging → production with an approval gate, and a deployed system that matches its code. `main` must stay protected (pull request plus review).

## Options Considered
**1. Argo CD, syncing a Helm chart from a deploy branch per environment (`env/<environment>`)**
- For:
  - Git records every deployment.
  - Argo CD keeps the cluster equal to that record and undoes manual changes (self-heal).
  - A rebuilt cluster returns to the last deployment on its own.
  - The pipeline writes only to `env/*`, so it never needs to bypass the review rule on `main`.
- Against:
  - More components in each cluster (controller, repo server, API server, Redis).
  - The deploy branches themselves need protection.

**2. Keep `kubectl apply` from GitHub Actions**
- For: simplest.
- Against: no Git record of what is deployed, no drift correction, and a rebuild needs a pipeline re-run.

**3. Argo CD Image Updater**
- For: picks up new image tags automatically.
- Against: needs registry credentials in the cluster, and either writes to the protected `main` or keeps the tag only inside Argo CD (not in Git).

**4. CI opening a pull request for every image tag**
- For: every change is reviewed.
- Against: a human review for every deployment just to change a tag.

## Decision
Option 1:
- **Argo CD in each cluster**, installed by Terraform (`infra/argocd.tf`, `argo-cd` chart 10.18.0) with its Application (`argocd-apps` chart). It syncs `charts/carelink` from `env/<environment>` into the namespace `<environment>`, with automated sync, prune and self-heal.
- **The app pipeline** (`cd.yaml`) builds and scans the images, then records each deployment as a commit on `env/staging`. After the GitHub `production` approval, it copies the same images to the production ECR repositories and records the deployment on `env/production`. It waits for Argo CD to report *Synced* and *Healthy*.
- **`env/production` is locked:** a ruleset allows only the approved production job, through a deploy key (ADR 0006).
- **One source of truth:** the old Kustomize manifests and the `kubectl apply` deploy were removed.

## Consequences
- **Rebuilds:** after a nightly rebuild, the application returns to the last recorded deployment with no extra step.
- **History:** `git log origin/env/production` is the production deployment history (who, which commit, which run).
- **Drift:** manual `kubectl` changes are reverted by self-heal, so every change must go through Git.
- **The branch is the gate:** Argo CD trusts whatever is on `env/<environment>`. `env/production` only accepts the approved job; `env/staging` is not locked (staging has no approval step).
- **The UI:** first reachable only through port-forward. Since 25 Nov 2026 it has its own URL with GitHub sign-in (ADR 0010).
