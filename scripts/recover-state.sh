#!/usr/bin/env bash
# =============================================================================
# Recover the Terraform state after the nightly cleanup deleted it
# =============================================================================
# Run from infra/ after `terraform init`, before `terraform plan` or `apply`:
#
#   ../scripts/recover-state.sh <staging|production>
#
# - State has resources  -> does nothing.
# - State is empty       -> asks Terraform what it would create, looks each of
#                           those up in AWS (scripts/generate-imports.sh) and
#                           writes infra/imports.auto.tf with an import block
#                           for everything that already exists.
#
# The next `terraform plan` then shows "N to import" instead of "N to add", and
# `terraform apply` adopts the existing resources and only creates or repairs
# what is really missing (for example IAM policy attachments the cleanup
# removed). On a genuinely fresh build nothing exists, no file is written, and
# Terraform creates everything as usual.
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
  echo "Terraform state for $ENVIRONMENT has resources: nothing to recover."
  exit 0
fi

echo "Terraform state for $ENVIRONMENT is empty. Checking AWS for resources that already exist..."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

terraform plan -input=false -lock=false -var="environment=$ENVIRONMENT" -out="$WORK/empty.tfplan" >/dev/null
terraform show -json "$WORK/empty.tfplan" >"$WORK/empty.json"

"$SCRIPT_DIR/generate-imports.sh" "$WORK/empty.json" >"$OUT"

count=$(grep -c '^import {' "$OUT" || true)
if [[ "$count" -eq 0 ]]; then
  rm -f "$OUT"
  echo "Nothing exists in AWS yet: this is a fresh build, Terraform will create everything."
else
  echo "Wrote $count import blocks to infra/$OUT. The next plan shows them as 'to import'."
fi
