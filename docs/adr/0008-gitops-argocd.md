# ADR 0008: Deliver the application with Argo CD (GitOps)

- **Status:** Accepted
- **Date:** 2026-11-12
- **Owner:** DevSecOps Engineer

## Context
The app pipeline deployed by running `kubectl apply -k` from GitHub Actions against the staging cluster. That gave no production path, no record in Git of what runs where, and nothing restoring the app after the instructors' nightly cleanup without re-running the pipeline. An unused Helm chart and an Argo CD manifest in the app repo were out of date and would have broken staging if applied. The brief requires feature → PR → staging → production with an approval gate, and a deployed system that matches its code.

## Decision
- Argo CD runs in each cluster, installed by Terraform (`infra/argocd.tf`, `argo-cd` chart 10.18.0) together with its one Application (`argocd-apps` chart). It syncs the app repo's Helm chart `charts/carelink` from the branch `env/<environment>` into the namespace `<environment>`, with automated sync, prune and self-heal.
- The app pipeline (`cd.yaml`) builds and scans images, then records each deployment as a commit on `env/staging`. After the GitHub `production` environment approval, it copies the same images to the production ECR repositories and records the deployment on `env/production`. It waits for Argo CD to report *Synced* and *Healthy* before passing.
- `main` stays protected (PR plus one review). The `env/*` branches are deployment records written only by the pipeline. This avoids CI needing to bypass the review rule to change image tags.
- The Kustomize manifests (`k8s/`) and the `kubectl apply` deploy were removed, leaving one source of truth.

## Alternatives considered
- **Keep `kubectl apply` from GitHub Actions:** simpler, but no Git record of what is deployed, no drift correction, and a rebuild needs a pipeline re-run.
- **Argo CD Image Updater:** tracks new image tags automatically, but it needs registry credentials in the cluster and either writes to the protected `main` or keeps the tag only inside Argo CD (not in Git).
- **CI opening a pull request per image tag:** every deployment would need a human review just to bump a tag.

## Consequences
- After a nightly rebuild, Terraform reinstalls Argo CD and the Application, and the app returns to the last recorded deployment with no extra step.
- `git log origin/env/production` is the production deployment history (who, which commit, which run).
- Manual `kubectl` changes are reverted by self-heal: changes must go through Git.
- Argo CD adds components to operate in each cluster (application controller, repo server, API server, Redis, ApplicationSet controller). Its UI is not exposed publicly (port-forward only), so there is no extra internet-facing surface.
- The pipeline's GITHUB_TOKEN can push to `env/*`, so access to edit workflows on `main` (protected by review) is what guards production, together with the `production` environment approval.
