#!/usr/bin/env bash
# Store an Argo CD GitHub OAuth App's client ID and secret in Secrets Manager
# (carelink-<env>-argocd-github-oauth), where External Secrets picks them up for
# Dex (infra/argocd.tf, ADR 0010).
#
# Prompts for both values. The client secret is never echoed, never put on a
# command line (where other processes could see it) and never left in a file.
#
# Usage: scripts/set-argocd-oauth-secret.sh staging|production
# Runbook: docs/sre/runbooks/argocd-sso.md
set -euo pipefail

env=${1:-}
if [[ $env != staging && $env != production ]]; then
  echo "usage: $0 staging|production" >&2
  exit 2
fi
secret_id="carelink-${env}-argocd-github-oauth"
region=${AWS_REGION:-us-east-1}

# Fails early if Terraform has not created the secret yet (or the wrong account is active).
aws secretsmanager describe-secret --secret-id "$secret_id" --region "$region" --query Name --output text >/dev/null

read -r -p "Client ID of the ${env} OAuth App: " client_id
read -r -s -p "Client secret (input hidden): " client_secret
echo

if [[ ! $client_id =~ ^[A-Za-z0-9]+$ ]]; then
  echo "That does not look like a GitHub OAuth client ID; nothing stored." >&2
  exit 1
fi
if [[ ${#client_secret} -lt 20 || ! $client_secret =~ ^[A-Za-z0-9]+$ ]]; then
  echo "That does not look like a GitHub OAuth client secret; nothing stored." >&2
  exit 1
fi

umask 077
file=$(mktemp)
trap 'rm -f "$file"' EXIT
printf '{"clientID":"%s","clientSecret":"%s"}' "$client_id" "$client_secret" >"$file"
unset client_secret

version=$(aws secretsmanager put-secret-value --secret-id "$secret_id" --region "$region" \
  --secret-string "file://$file" --query VersionId --output text)
echo "Stored a new version of ${secret_id} (${version})."
echo "External Secrets copies it into argocd/argocd-dex-github within 5 minutes (runbook step 3 forces it now)."
