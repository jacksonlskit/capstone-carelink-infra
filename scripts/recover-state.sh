#!/usr/bin/env bash
# =============================================================================
# Recover the Terraform state after the nightly cleanup deleted it
# =============================================================================
# Run from infra/ after `terraform init`, before `terraform plan` or `apply`:
#
#   ../scripts/recover-state.sh <staging|production>
#
# Asks Terraform what it would CREATE, looks each of those up in AWS
# (scripts/generate-imports.sh) and writes infra/imports.auto.tf with an import
# block for every one that already exists:
#
# - State is empty       -> after the nightly cleanup: Terraform would create
#                           everything, so nearly everything gets adopted.
# - State has resources  -> normal days: only resources the state does not
#                           know are checked. That catches leftovers of a
#                           FAILED apply, which creates resources in AWS but
#                           stops before recording them (seen 19 Nov: an IAM
#                           role left behind made every later apply fail with
#                           "already exists"). Usually there is nothing to do.
#
# The next `terraform plan` then shows "N to import" instead of "N to add", and
# `terraform apply` adopts the existing resources and only creates or repairs
# what is really missing (for example IAM policy attachments the cleanup
# removed). On a genuinely fresh build nothing exists, no file is written, and
# Terraform creates everything as usual.
#
# The plan here uses only -var environment, like the real plan and apply.
# Any other setting must reach BOTH, so set it as a TF_VAR_<name> environment
# variable on the job (see the staging jobs in ci.yaml and cd.yaml), never as a
# -var on the apply line alone: then this plan would not see those resources.
#
# This script itself changes nothing in AWS and nothing in the state.
# imports.auto.tf is generated per run and is not committed (.gitignore).
# =============================================================================
set -euo pipefail

ENVIRONMENT=${1:?usage: recover-state.sh <staging|production>}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT=imports.auto.tf

[[ -f providers.tf ]] || { echo "Run this from the infra/ directory." >&2; exit 2; }

# Never reuse a file from an earlier run: its IDs may be stale.
rm -f "$OUT"

if [[ -n "$(terraform state list 2>/dev/null | head -n1 || true)" ]]; then
  STATE=filled
  echo "Terraform state for $ENVIRONMENT has resources. Checking whether anything it would create already exists in AWS..."
else
  STATE=empty
  echo "Terraform state for $ENVIRONMENT is empty. Checking AWS for resources that already exist..."
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

terraform plan -input=false -lock=false -var="environment=$ENVIRONMENT" -out="$WORK/recover.tfplan" >/dev/null
terraform show -json "$WORK/recover.tfplan" >"$WORK/recover.json"

"$SCRIPT_DIR/generate-imports.sh" "$WORK/recover.json" >"$OUT"

count=$(grep -c '^import {' "$OUT" || true)
if [[ "$count" -gt 0 ]]; then
  echo "Wrote $count import blocks to infra/$OUT. The next plan shows them as 'to import'."
elif [[ "$STATE" == empty ]]; then
  rm -f "$OUT"
  echo "Nothing exists in AWS yet: this is a fresh build, Terraform will create everything."
else
  rm -f "$OUT"
  echo "Nothing to adopt: the state already knows every resource that exists."
fi
