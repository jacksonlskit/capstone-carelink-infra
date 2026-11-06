# ADR 0007: Application region: ap-southeast-1 (Singapore)

- **Status:** Proposed: **SA to confirm**; the foundation (state bucket, bootstrap) currently sits in us-east-1.
- **Date:** 2026-10-23
- **Owner:** Solutions Architect

## Context
CareLink serves clinics in Singapore and Malaysia and handles patient data, so PDPA obligations apply. Transferring personal data out of the country requires that it keeps a comparable standard of protection, which is simplest to demonstrate when the data stays in-region. Users are also in the same time zone, so latency to a Singapore region is best. The data in this capstone is synthetic, but the architecture must be defensible as if real.

## Decision
Deploy the application stack (compute, database, logs, backups) in `ap-southeast-1`. The Terraform state bucket may stay in `us-east-1` because it contains infrastructure metadata, not patient data. Cross-region backup copies, if added, go to a region chosen deliberately and recorded here. (Malaysia's `ap-southeast-5` exists but is newer, with fewer services; revisit if data residency in Malaysia becomes a requirement.)

## Consequences
- Lower latency for clinic users and an easier answer to residency questions.
- Staging and production use the same region by default, so quotas and service availability match.
- If the team stays in us-east-1 for the demo, this ADR must say so honestly and list the residency gap as a known limitation.
- Terraform: `aws_region` defaults to `ap-southeast-1` in `variables.tf`; the backend files keep `us-east-1` for state.

## Addendum 24 Oct (team decision, confirmed by Jon)
The team uses **us-east-1** for the capstone, which matches `infra/variables.tf` and the state bucket. Status of this ADR: **accepted with a known limitation**. Do not tell the panel that patient data stays in Singapore or Malaysia. Honest wording: "synthetic data only for the demo; for real clinics we would deploy to ap-southeast-1 to meet PDPA cross-border transfer expectations, and the change is one variable."

## Decision update 25 Oct
The team confirmed the capstone runs in **us-east-1** (the default in code). Treat that as the accepted position for this project and keep the wording above: synthetic data only; a real CareLink deployment would be in ap-southeast-1 (or a Malaysian region if residency required it) for PDPA cross-border transfer reasons, and the change is the `aws_region` variable plus a new state location. Status: Accepted, with limitation.
