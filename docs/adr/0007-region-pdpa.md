# ADR 0007: Region: us-east-1 for the capstone, ap-southeast-1 for real clinics

**Status:** Accepted, with a known limitation

**Date:** 2026-10-25

## Context
CareLink serves clinics in Singapore and Malaysia and handles patient data, so PDPA obligations apply. Transferring personal data out of the country requires a comparable standard of protection, which is simplest to show when the data stays in the region. Users are in the same time zone, so a Singapore region also gives the lowest latency.

The capstone uses **synthetic data only**. The team's tooling, the state bucket and the course's shared account were set up in us-east-1.

## Options Considered
**1. ap-southeast-1 (Singapore) for the whole application stack**
- For: data stays in the region (the easiest PDPA answer) and gives the lowest latency for clinics.
- Against: the shared account, the state bucket and the team's setup were already in us-east-1, and moving them during the course adds risk.

**2. ap-southeast-5 (Malaysia)**
- For: residency in Malaysia, if that were required.
- Against: a newer region with fewer services.

**3. us-east-1 for the capstone, with the region as one variable**
- For: matches the existing account setup and state bucket; nothing to move.
- Against: patient data would be outside Singapore and Malaysia. That's acceptable only because the data is synthetic, and it must be stated as a limitation.

## Decision
Option 3. The capstone runs in **us-east-1** (`aws_region` in `infra/variables.tf`, and the state bucket in `oicd-bootstrap/main.tf`). A real CareLink deployment would use **ap-southeast-1** (or a Malaysian region if residency there were required). That change is the `aws_region` variable plus a new state location.

Agreed by the team on 24–25 Oct 2026.

## Consequences
- **Wording for the panel:** never say that patient data stays in Singapore or Malaysia. Say: "Synthetic data only. For real clinics we would deploy to ap-southeast-1 to meet PDPA cross-border transfer expectations, and the region is one variable."
- **Same region everywhere:** staging and production use the same region, so quotas and service availability match.
- **Latency:** users in Singapore see higher latency to us-east-1, which is acceptable for the demonstration.
- **The residency gap** is listed in `docs/compliance-mapping.md` as an accepted limitation.
