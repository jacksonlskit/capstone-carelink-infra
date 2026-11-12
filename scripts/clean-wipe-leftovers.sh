#!/usr/bin/env bash
# =============================================================================
# Remove leftovers of the instructors' nightly AWS cleanup that block a rebuild
# =============================================================================
# When the Terraform state is empty but some named resources survived the
# cleanup, `terraform apply` fails with "already exists". Two kinds survive:
#
#   1. KMS aliases alias/carelink-*: the cleanup schedules the KMS *key* for
#      deletion (PendingDeletion) but leaves the alias. An alias pointing at a
#      key pending deletion is useless, so it is safe to delete.
#   2. IAM roles carelink-<env>-eks-nodes left with no policies and no instance
#      profile, i.e. not used by any node group.
#
# Anything still in use (alias on a live key, role with policies or an
# instance profile) is kept. Safe to run every morning before the infra deploy.
#
# Usage:
#   scripts/clean-wipe-leftovers.sh           # dry run: only lists what it would delete
#   scripts/clean-wipe-leftovers.sh --apply   # delete
# =============================================================================
set -euo pipefail

APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

run() {
  if $APPLY; then
    "$@"
    echo "    deleted"
  else
    echo "    [dry run] would run: $*"
  fi
}

echo "KMS aliases whose key is pending deletion:"
aws kms list-aliases \
  --query "Aliases[?starts_with(AliasName, 'alias/carelink-')].[AliasName,TargetKeyId]" \
  --output text |
  while read -r alias key; do
    [[ -z "${key:-}" || "$key" == "None" ]] && continue
    state=$(aws kms describe-key --key-id "$key" --query KeyMetadata.KeyState --output text)
    if [[ "$state" == "PendingDeletion" ]]; then
      echo "  $alias -> $key ($state)"
      run aws kms delete-alias --alias-name "$alias"
    else
      echo "  $alias -> $key ($state): in use, kept"
    fi
  done

echo "Orphaned EKS node roles:"
for env in staging production; do
  role="carelink-${env}-eks-nodes"
  if ! aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    echo "  $role: does not exist"
    continue
  fi
  attached=$(aws iam list-attached-role-policies --role-name "$role" --query 'length(AttachedPolicies)' --output text)
  inline=$(aws iam list-role-policies --role-name "$role" --query 'length(PolicyNames)' --output text)
  profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'length(InstanceProfiles)' --output text)
  if [[ "$attached" == "0" && "$inline" == "0" && "$profiles" == "0" ]]; then
    echo "  $role (no policies, no instance profile)"
    run aws iam delete-role --role-name "$role"
  else
    echo "  $role: in use ($attached attached, $inline inline policies, $profiles instance profiles), kept"
  fi
done

$APPLY || echo "Dry run only. Re-run with --apply to delete."
