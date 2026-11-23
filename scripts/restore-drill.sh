#!/usr/bin/env bash
# Timed RDS restore drill (STAGING ONLY). Fills the "Drill record" table in
# docs/sre/runbooks/db-instance-failure.md with measured numbers.
#
# Needs: aws CLI (logged in to the staging account), kubectl pointed at the
# staging cluster, a few cents of RDS cost. Never touches the source instance.
#
# Usage:  ./restore-drill.sh            # run the drill
#         ./restore-drill.sh cleanup    # delete the drill instance afterwards
set -euo pipefail

ENVIRONMENT=staging
SRC="carelink-${ENVIRONMENT}-mysql"
DST="${SRC}-drill"
DB=service_instance_db
NS="${ENVIRONMENT}"
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"

# Preflight: fail early with a clear message instead of halfway through the restore
if [[ "${1:-}" != "cleanup" ]]; then
  echo "Preflight checks..."
  aws sts get-caller-identity --query Arn --output text || { echo "AWS login problem"; exit 1; }
  kubectl get ns "$NS" >/dev/null 2>&1 || { echo "kubectl cannot reach namespace '$NS' (run: aws eks update-kubeconfig --name <staging cluster> --region us-east-1)"; exit 1; }
  aws rds describe-db-instances --db-instance-identifier "carelink-${ENVIRONMENT}-mysql" >/dev/null 2>&1 \
    || { echo "Source instance carelink-${ENVIRONMENT}-mysql not found: check the name with: aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'"; exit 1; }
  echo "Preflight OK. Tip: do not start this close to the daily cleanup time."
fi

ts()  { date -u +%s; }
now() { date -u +%H:%M:%SZ; }
say() { printf '[%s] %s\n' "$(now)" "$*"; }

if [[ "${1:-}" == "cleanup" ]]; then
  say "Deleting $DST (no final snapshot; it is a drill copy)"
  aws rds delete-db-instance --db-instance-identifier "$DST" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  say "Delete requested. Confirm in the console that only $SRC remains."
  exit 0
fi

[[ "$ENVIRONMENT" == "staging" ]] || { echo "staging only"; exit 1; }
SRC_ID=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].DBInstanceIdentifier' --output text)
say "Source instance: $SRC_ID"

# Copy the settings PITR does not carry over (these are in the runbook warning)
read -r SUBNET_GRP PARAM_GRP CLASS < <(aws rds describe-db-instances \
  --db-instance-identifier "$SRC" --query \
  'DBInstances[0].[DBSubnetGroup.DBSubnetGroupName,DBParameterGroups[0].DBParameterGroupName,DBInstanceClass]' \
  --output text)
SG_IDS=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output text)
SECRET_ARN=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

# 1. Baseline row counts on the source (data check, "before")
count_rows() {  # $1 = host
  local pw
  pw=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" \
        --query SecretString --output text | python3 -c 'import sys,json;print(json.load(sys.stdin)["password"])')
  kubectl -n "$NS" run "drill-mysql-$RANDOM" --rm -i --restart=Never --quiet \
    --image=mysql:8.0 --env="MYSQL_PWD=$pw" --command -- \
    mysql -h "$1" -u dbadmin --ssl-mode=REQUIRED -N -B "$DB" -e \
    "SELECT 'owners',COUNT(*) FROM owners UNION ALL SELECT 'pets',COUNT(*) FROM pets UNION ALL SELECT 'vets',COUNT(*) FROM vets UNION ALL SELECT 'visits',COUNT(*) FROM visits;"
}
SRC_HOST=$(aws rds describe-db-instances --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
say "Row counts BEFORE (source):"; BEFORE=$(count_rows "$SRC_HOST" || true); echo "$BEFORE"

# 2. Declare T+0 and restore
T0=$(ts); say "T+0: simulated failure declared. Starting point-in-time restore."
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier "$SRC" --target-db-instance-identifier "$DST" \
  --use-latest-restorable-time --db-instance-class "$CLASS" \
  --db-subnet-group-name "$SUBNET_GRP" --db-parameter-group-name "$PARAM_GRP" \
  --vpc-security-group-ids $SG_IDS --no-publicly-accessible --no-multi-az \
  --copy-tags-to-snapshot >/dev/null

aws rds wait db-instance-available --db-instance-identifier "$DST"
T1=$(ts); say "Restored instance AVAILABLE after $(( (T1-T0)/60 )) min $(( (T1-T0)%60 )) s"

# 3. Verify through the data path ("after")
DST_HOST=$(aws rds describe-db-instances --db-instance-identifier "$DST" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
say "Row counts AFTER (restored):"; AFTER=$(count_rows "$DST_HOST" || true); echo "$AFTER"
T2=$(ts)

cat <<REC

===== DRILL RECORD (paste into db-instance-failure.md section 6) =====
Date / environment            : $(date -u +%F) / $ENVIRONMENT
Restore method                : PITR, --use-latest-restorable-time
Start to 'available'          : $(( (T1-T0)/60 )) min $(( (T1-T0)%60 )) s
Start to data verified        : $(( (T2-T0)/60 )) min $(( (T2-T0)%60 )) s   (excludes app cutover)
Data check                    : before vs after below ($( [[ -n "$BEFORE" && "$BEFORE" == "$AFTER" ]] && echo MATCH || echo NOT-VERIFIED-counts-empty-or-different ))
Total vs 4 h RTO              : $(( (T2-T0)/60 )) min of 240
$BEFORE
--- after ---
$AFTER
=======================================================================
Not measured here: app cutover (secret/endpoint change + rollout), see runbook 3B step 4.
Clean up now:  $0 cleanup
REC
