#!/usr/bin/env bash
# =============================================================================
# Generate Terraform import blocks for resources that already exist in AWS
# =============================================================================
# Why: the instructors' nightly cleanup (aws-nuke) deletes the Terraform state
# files (S3 objects cannot be protected by the Project tag) while most of the
# tagged infrastructure survives. With an empty state Terraform would try to
# create everything again. This script rebuilds the link instead:
#
#   1. Terraform is asked what it WOULD create from an empty state
#      (terraform plan -out + terraform show -json, done by recover-state.sh).
#   2. For each of those resources this script looks up the real one in AWS by
#      its name or tags.
#   3. If it exists, an `import` block is written; if not, nothing is written
#      and Terraform creates it as usual.
#
# The lookups only read from AWS. Nothing is changed until `terraform apply`
# runs with the generated file, and the plan shows every import first.
#
# Usage: scripts/generate-imports.sh <plan.json>  > infra/imports.auto.tf
# Needs: aws CLI, jq; helm + cluster access for the Helm releases.
# =============================================================================
set -euo pipefail

PLAN_JSON=${1:?usage: generate-imports.sh <plan.json>}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
IDS="$TMP/ids.tsv"
: >"$IDS"

log() { echo "$*" >&2; }
# AWS CLI prints "None" for an empty result; treat that as "not found".
clean() { awk '$0 != "None" && $0 != "" {print; exit}'; }
aws_q() { aws "$@" --output text 2>/dev/null | clean || true; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(jq -r '.variables.aws_region.value // "us-east-1"' "$PLAN_JSON")}}
export AWS_DEFAULT_REGION=$REGION

# Every managed resource Terraform plans to create, one JSON object per line.
jq -c '.resource_changes[]
       | select(.mode == "managed" and (.change.actions | index("create")))
       | {address, type, name, index, after: .change.after}' "$PLAN_JSON" >"$TMP/resources.jsonl"

field() { jq -r "$2 // empty" <<<"$1"; }
resolved() { awk -F'\t' -v a="$1" '$1 == a {print $2; exit}' "$IDS"; }
planned_names() { jq -r --arg t "$1" 'select(.type == $t) | .after.name // empty' "$TMP/resources.jsonl"; }

# --- the VPC anchors every network lookup --------------------------------------
VPC_ID=""
vpc_row=$(jq -c 'select(.type == "aws_vpc")' "$TMP/resources.jsonl" | head -n1)
if [[ -n "$vpc_row" ]]; then
  vpc_name=$(field "$vpc_row" '.after.tags.Name')
  project=$(field "$vpc_row" '.after.tags_all.Project')
  # Name AND Project: older, empty VPCs with the same Name but no Project tag
  # are leftovers of earlier rebuilds and must not be picked up.
  matches=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$vpc_name" "Name=tag:Project,Values=$project" \
    --query 'Vpcs[].VpcId' --output text)
  if [[ $(wc -w <<<"$matches") -gt 1 ]]; then
    log "ERROR: more than one VPC named $vpc_name with Project=$project: $matches. Refusing to guess."
    exit 1
  fi
  VPC_ID=$(clean <<<"$matches" || true)
fi

CLUSTER=$(planned_names aws_eks_cluster | head -n1)
KUBECONFIG_FILE=""
kube_ready() {
  [[ -n "$KUBECONFIG_FILE" ]] && return 0
  command -v helm >/dev/null || return 1
  [[ $(aws_q eks describe-cluster --name "$CLUSTER" --query cluster.status) == "ACTIVE" ]] || return 1
  aws eks update-kubeconfig --name "$CLUSTER" --kubeconfig "$TMP/kubeconfig" >/dev/null 2>&1 || return 1
  KUBECONFIG_FILE="$TMP/kubeconfig"
}

kms_key_id() { # $1 = Name tag, $2 = Project tag -> id of the enabled key
  local arn
  for arn in $(aws resourcegroupstaggingapi get-resources --resource-type-filters kms:key \
    --tag-filters "Key=Name,Values=$1" "Key=Project,Values=$2" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text); do
    # Keys scheduled for deletion by the cleanup still show up here; skip them.
    if [[ $(aws_q kms describe-key --key-id "$arn" --query KeyMetadata.KeyState) == "Enabled" ]]; then
      echo "${arn##*/}"
      return
    fi
  done
}

lookup() { # prints the import ID for one resource, or nothing if it does not exist
  local r=$1 type name
  type=$(field "$r" .type)
  name=$(field "$r" .after.name)
  case "$type" in
    # ---- network ---------------------------------------------------------------
    aws_vpc) echo "$VPC_ID" ;;
    aws_subnet)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=cidr-block,Values=$(field "$r" .after.cidr_block)" --query 'Subnets[0].SubnetId' ;;
    aws_internet_gateway)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[0].InternetGatewayId' ;;
    aws_eip)
      aws_q ec2 describe-addresses --filters "Name=tag:Name,Values=$(field "$r" .after.tags.Name)" \
        "Name=tag:Project,Values=$(field "$r" .after.tags_all.Project)" --query 'Addresses[0].AllocationId' ;;
    aws_nat_gateway)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" \
        "Name=tag:Name,Values=$(field "$r" .after.tags.Name)" "Name=state,Values=available" \
        --query 'NatGateways[0].NatGatewayId' ;;
    aws_route_table)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=tag:Name,Values=$(field "$r" .after.tags.Name)" --query 'RouteTables[0].RouteTableId' ;;
    aws_default_security_group)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=group-name,Values=default" --query 'SecurityGroups[0].GroupId' ;;
    aws_security_group)
      [[ -n "$VPC_ID" ]] && aws_q ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=group-name,Values=$name" --query 'SecurityGroups[0].GroupId' ;;

    # ---- database --------------------------------------------------------------
    aws_db_subnet_group)
      aws_q rds describe-db-subnet-groups --db-subnet-group-name "$name" --query 'DBSubnetGroups[0].DBSubnetGroupName' ;;
    aws_db_instance)
      aws_q rds describe-db-instances --db-instance-identifier "$(field "$r" .after.identifier)" \
        --query "DBInstances[?DBInstanceStatus!='deleting'] | [0].DBInstanceIdentifier" ;;
    aws_db_event_subscription)
      aws_q rds describe-event-subscriptions --subscription-name "$name" --query 'EventSubscriptionsList[0].CustSubscriptionId' ;;

    # ---- encryption keys -------------------------------------------------------
    aws_kms_key) kms_key_id "$(field "$r" .after.tags.Name)" "$(field "$r" .after.tags_all.Project)" ;;
    aws_kms_alias)
      local key
      key=$(aws_q kms list-aliases --query "Aliases[?AliasName=='$name'] | [0].TargetKeyId")
      # An alias left pointing at a key pending deletion is a cleanup leftover:
      # remove it with scripts/clean-wipe-leftovers.sh, do not import it.
      [[ -n "$key" && $(aws_q kms describe-key --key-id "$key" --query KeyMetadata.KeyState) == "Enabled" ]] && echo "$name" ;;

    # ---- container registry ----------------------------------------------------
    aws_ecr_repository)
      aws_q ecr describe-repositories --repository-names "$name" --query 'repositories[0].repositoryName' ;;
    aws_ecr_lifecycle_policy)
      aws_q ecr get-lifecycle-policy --repository-name "$(field "$r" .after.repository)" --query repositoryName ;;

    # ---- IAM ---------------------------------------------------------------------
    aws_iam_role) aws_q iam get-role --role-name "$name" --query Role.RoleName ;;
    aws_iam_role_policy_attachment)
      local role policy
      role=$(field "$r" .after.role)
      policy=$(field "$r" .after.policy_arn)
      [[ -n $(aws_q iam list-attached-role-policies --role-name "$role" \
        --query "AttachedPolicies[?PolicyArn=='$policy'] | [0].PolicyArn") ]] && echo "$role/$policy" ;;
    aws_iam_role_policy)
      # The role is not known in the plan (it references the role's computed id),
      # so check each planned role for an inline policy with this name.
      local role
      for role in $(field "$r" .after.role) $(planned_names aws_iam_role); do
        if aws iam get-role-policy --role-name "$role" --policy-name "$name" >/dev/null 2>&1; then
          echo "$role:$name"
          return
        fi
      done ;;
    aws_iam_openid_connect_provider)
      local issuer arn
      issuer=$(aws_q eks describe-cluster --name "$CLUSTER" --query cluster.identity.oidc.issuer)
      [[ -n "$issuer" ]] || return 0
      arn="arn:aws:iam::${ACCOUNT}:oidc-provider/${issuer#https://}"
      aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 && echo "$arn" ;;

    # ---- EKS ---------------------------------------------------------------------
    aws_eks_cluster)
      aws_q eks describe-cluster --name "$name" --query "cluster.name" ;;
    aws_eks_node_group)
      local cluster ng
      cluster=$(field "$r" .after.cluster_name)
      ng=$(field "$r" .after.node_group_name)
      if [[ -n "$ng" ]]; then
        [[ -n $(aws_q eks describe-nodegroup --cluster-name "$cluster" --nodegroup-name "$ng" --query nodegroup.nodegroupName) ]] && echo "$cluster:$ng"
      else
        # node_group_name_prefix: the full name is generated, so match the prefix.
        local prefix
        prefix=$(field "$r" .after.node_group_name_prefix)
        ng=$(aws eks list-nodegroups --cluster-name "$cluster" --query "nodegroups[?starts_with(@, '$prefix')]" --output text 2>/dev/null | tr '\t' '\n' | sort | tail -n1)
        [[ -n "$ng" ]] && echo "$cluster:$ng"
      fi ;;
    aws_eks_access_entry)
      local cluster principal
      cluster=$(field "$r" .after.cluster_name)
      principal=$(field "$r" .after.principal_arn)
      aws eks describe-access-entry --cluster-name "$cluster" --principal-arn "$principal" >/dev/null 2>&1 && echo "$cluster:$principal" ;;
    aws_eks_access_policy_association)
      local cluster principal policy
      cluster=$(field "$r" .after.cluster_name)
      principal=$(field "$r" .after.principal_arn)
      policy=$(field "$r" .after.policy_arn)
      [[ -n $(aws_q eks list-associated-access-policies --cluster-name "$cluster" --principal-arn "$principal" \
        --query "associatedAccessPolicies[?policyArn=='$policy'] | [0].policyArn") ]] && echo "$cluster#$principal#$policy" ;;
    aws_autoscaling_group_tag)
      # The Auto Scaling group is created by EKS for the node group; find it there.
      local key ng asg
      key=$(field "$r" '.after.tag[0].key')
      for ng in $(aws eks list-nodegroups --cluster-name "$CLUSTER" --query nodegroups --output text 2>/dev/null); do
        asg=$(aws_q eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$ng" --query 'nodegroup.resources.autoScalingGroups[0].name')
        if [[ -n "$asg" && -n $(aws_q autoscaling describe-tags --filters "Name=auto-scaling-group,Values=$asg" "Name=key,Values=$key" --query 'Tags[0].Key') ]]; then
          echo "$asg,$key"
          return
        fi
      done ;;

    # ---- monitoring --------------------------------------------------------------
    aws_cloudwatch_log_group)
      aws_q logs describe-log-groups --log-group-name-prefix "$name" --query "logGroups[?logGroupName=='$name'] | [0].logGroupName" ;;
    aws_cloudwatch_log_metric_filter)
      local lg
      lg=$(field "$r" .after.log_group_name)
      [[ -n $(aws_q logs describe-metric-filters --log-group-name "$lg" --filter-name-prefix "$name" \
        --query "metricFilters[?filterName=='$name'] | [0].filterName") ]] && echo "$lg:$name" ;;
    aws_cloudwatch_metric_alarm)
      aws_q cloudwatch describe-alarms --alarm-names "$(field "$r" .after.alarm_name)" --query 'MetricAlarms[0].AlarmName' ;;
    aws_cloudwatch_dashboard)
      local dash
      dash=$(field "$r" .after.dashboard_name)
      aws cloudwatch get-dashboard --dashboard-name "$dash" >/dev/null 2>&1 && echo "$dash" ;;
    aws_sns_topic)
      local arn="arn:aws:sns:${REGION}:${ACCOUNT}:${name}"
      aws sns get-topic-attributes --topic-arn "$arn" >/dev/null 2>&1 && echo "$arn" ;;

    # ---- Helm releases in the cluster --------------------------------------------
    helm_release)
      local ns
      ns=$(field "$r" .after.namespace)
      kube_ready && helm --kubeconfig "$KUBECONFIG_FILE" -n "$ns" status "$name" >/dev/null 2>&1 && echo "$ns/$name" ;;

    # ---- resolved in the second pass, or never imported --------------------------
    aws_route_table_association | aws_sns_topic_policy) ;;
    aws_ec2_tag) ;; # creating a tag that already exists is harmless
    *) log "  no lookup defined for $type: it will be created (add a case to generate-imports.sh if it already exists)" ;;
  esac
  return 0
}

lookup_dependent() { # resources whose ID is built from other resources' IDs
  local r=$1 type name index
  type=$(field "$r" .type)
  name=$(field "$r" .name)
  index=$(jq -c .index <<<"$r")
  case "$type" in
    aws_route_table_association)
      # Convention in vpc.tf: aws_route_table_association.<x>[i] attaches aws_subnet.<x>[i].
      local subnet rtb
      subnet=$(resolved "aws_subnet.${name}[${index}]")
      [[ -n "$subnet" ]] || return 0
      rtb=$(aws_q ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$subnet" --query 'RouteTables[0].RouteTableId')
      [[ -n "$rtb" ]] && echo "$subnet/$rtb" ;;
    aws_sns_topic_policy)
      # Convention in monitoring.tf: aws_sns_topic_policy.<x> belongs to aws_sns_topic.<x>.
      local arn
      arn=$(resolved "aws_sns_topic.${name}")
      [[ -n "$arn" && -n $(aws_q sns get-topic-attributes --topic-arn "$arn" --query Attributes.Policy) ]] && echo "$arn" ;;
  esac
  return 0
}

total=0
found=0
missing=()
emit() { # $1 = resource JSON, $2 = import ID
  local address
  address=$(field "$1" .address)
  total=$((total + 1))
  if [[ -n "$2" ]]; then
    found=$((found + 1))
    printf '%s\t%s\n' "$address" "$2" >>"$IDS"
    printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$address" "$2"
  else
    missing+=("$address")
  fi
}

cat <<EOF
# GENERATED by scripts/generate-imports.sh on $(date -u +%FT%TZ). Do not commit.
# Each block adopts a resource that already exists in AWS into the Terraform
# state instead of creating it again. Resources without a block did not exist
# and will be created.

EOF

while IFS= read -r row; do
  case "$(field "$row" .type)" in
    aws_route_table_association | aws_sns_topic_policy) continue ;;
  esac
  emit "$row" "$(lookup "$row")"
done <"$TMP/resources.jsonl"

while IFS= read -r row; do
  case "$(field "$row" .type)" in
    aws_route_table_association | aws_sns_topic_policy) emit "$row" "$(lookup_dependent "$row")" ;;
  esac
done <"$TMP/resources.jsonl"

log "Found $found of $total planned resources already in AWS (import blocks written)."
if ((${#missing[@]} > 0)); then
  log "Not found, will be created by terraform apply:"
  printf '  %s\n' "${missing[@]}" >&2
fi
