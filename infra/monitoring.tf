# =============================================================================
# monitoring.tf  (SRE: Jon / Shilpa)  -- reconciled with infra/ on 24 Oct
#
# Drop into infra/ next to vpc.tf, kms.tf, eks.tf, rds.tf, ecr.tf.
# Uses the real names: local.name_prefix, local.cluster_id (vpc.tf),
# local.db_log_exports (rds.tf), aws_db_instance.main (for_each over var.databases),
# var.microservices, data.aws_caller_identity.current (kms.tf).
#
# Needs two small changes in OTHER owners' files (see REPO-FINDINGS.md, nothing is
# edited here):
#   rds.tf (Krisna): only for a NEW environment with manage_rds_log_groups = true: add
#                    depends_on = [aws_cloudwatch_log_group.rds] to aws_db_instance.main
#                    so retention/encryption on DB log groups are ours, not RDS defaults.
#   eks.tf (Jack)  : none required if monitoring-eks-addon.tf is accepted; the AWS Load
#                    Balancer Controller is still needed before monitor_alb can be true.
# =============================================================================

locals {
  account_id    = data.aws_caller_identity.current.account_id
  cluster_name  = local.cluster_id # "<project>-<env>-eks", defined in vpc.tf
  ci_prefix     = "/aws/containerinsights/${local.cluster_name}"
  is_production = var.environment == "production"

  app_retention   = var.app_log_retention_days != null ? var.app_log_retention_days : (local.is_production ? 90 : 14)
  audit_retention = var.audit_log_retention_days != null ? var.audit_log_retention_days : (local.is_production ? 365 : 90)

  # --- SLO arithmetic --------------------------------------------------------
  # Availability SLO 99.9% => error budget 0.1% of requests.
  # Clinic hours 08:00-20:00 SGT = 12 h/day = ~360 h per 30 days
  # => allowed downtime ~ 360 h x 60 x 0.001 = 21.6 minutes per month.
  # Burn rate = (observed error rate) / (error budget).
  #   Fast 14.4x : error rate > 1.44% -> budget gone in 360/14.4 = 25 clinic hours. PAGE.
  #   Slow  6x   : error rate > 0.6%  -> budget gone in 360/6   = 60 clinic hours. TICKET.
  error_budget_pct    = 100 - var.slo_availability_target
  fast_burn_threshold = floor(local.error_budget_pct * 14.4 * 1000 + 0.5) / 1000
  slow_burn_threshold = floor(local.error_budget_pct * 6 * 1000 + 0.5) / 1000

  # 08:00-20:00 SGT (UTC+8, no DST) = 00:00-12:00 UTC
  clinic_end_hour_utc = 12

  # HTTPCode_ELB_5XX is included because when every target is down the load
  # balancer itself returns 503 and those are NOT counted as target 5xx.
  error_rate_expression = (
    var.alert_clinic_hours_only
    ? "IF(HOUR(total) < ${local.clinic_end_hour_utc}, IF(total > 0, 100 * errs / total, 0), 0)"
    : "IF(total > 0, 100 * errs / total, 0)"
  )

  alb_arn_suffix = var.monitor_alb ? data.aws_lb.app[0].arn_suffix : ""
  services       = toset(var.microservices) # must equal the Kubernetes Service / container names

  burn_alarms = var.monitor_alb ? {
    fast = {
      period     = 300
      evaluation = 6
      datapoints = 4
      threshold  = local.fast_burn_threshold
      severity   = "PAGE"
      meaning    = "14.4x burn: error budget exhausted in ~25 clinic hours if this continues"
    }
    slow = {
      period     = 3600
      evaluation = 6
      datapoints = 5
      threshold  = local.slow_burn_threshold
      severity   = "TICKET"
      meaning    = "6x burn: error budget exhausted in ~60 clinic hours if this continues"
    }
  } : {}

  eks_cluster_alarms = var.monitor_eks ? {
    node-cpu = {
      metric    = "node_cpu_utilization"
      statistic = "Average"
      threshold = var.node_cpu_alarm_pct
      periods   = 3
      summary   = "Average node CPU above ${var.node_cpu_alarm_pct}% for 15 min: pods may be throttled, scale nodes"
    }
    node-memory = {
      metric    = "node_memory_utilization"
      statistic = "Average"
      threshold = var.node_memory_alarm_pct
      periods   = 3
      summary   = "Average node memory above ${var.node_memory_alarm_pct}% for 15 min: risk of pod eviction / OOM kills"
    }
    failed-nodes = {
      metric    = "cluster_failed_node_count"
      statistic = "Maximum"
      threshold = 0
      periods   = 1
      summary   = "One or more worker nodes are not Ready"
    }
  } : {}

  # --- Databases: one set of alarms and log groups per aws_db_instance.main entry ---
  # Same identifier formula as rds.tf, so log groups can be created without depending on
  # the instance (which would be circular).
  db_identifiers = { for k, v in var.databases : k => "${local.name_prefix}-${k}" }

  db_log_groups = merge([
    for k, v in var.databases : {
      for t in local.db_log_exports[v.engine] : "${k}/${t}" => {
        identifier = local.db_identifiers[k]
        type       = t
      }
    }
  ]...)

  rds_alarm_defs = {
    cpu = {
      metric    = "CPUUtilization"
      operator  = "GreaterThanThreshold"
      threshold = 80
      periods   = 5
      datapts   = 3
      summary   = "RDS CPU above 80%"
    }
    free-storage = {
      metric    = "FreeStorageSpace"
      operator  = "LessThanThreshold"
      threshold = var.rds_min_free_storage_gib * 1073741824
      periods   = 2
      datapts   = 2
      summary   = "RDS free storage low (disk full = outage)"
    }
    freeable-memory = {
      metric    = "FreeableMemory"
      operator  = "LessThanThreshold"
      threshold = var.rds_min_freeable_memory_mib * 1048576
      periods   = 3
      datapts   = 3
      summary   = "RDS freeable memory low"
    }
  }

  rds_alarms = {
    for p in setproduct(keys(var.databases), keys(local.rds_alarm_defs)) :
    "${p[0]}-${p[1]}" => merge(local.rds_alarm_defs[p[1]], { db = p[0], kind = p[1] })
  }

  cloudtrail_filters = var.monitor_cloudtrail ? {
    root-account-usage = {
      pattern   = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      threshold = 1
      summary   = "Root account used"
    }
    unauthorized-api-calls = {
      pattern   = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") }"
      threshold = 5
      summary   = "Burst of AccessDenied / unauthorized API calls"
    }
    console-login-without-mfa = {
      pattern   = "{ ($.eventName = \"ConsoleLogin\") && ($.additionalEventData.MFAUsed != \"Yes\") && ($.userIdentity.type = \"IAMUser\") && ($.responseElements.ConsoleLogin = \"Success\") }"
      threshold = 1
      summary   = "Console login without MFA"
    }
  } : {}
}

# -----------------------------------------------------------------------------
# ALB created by the AWS Load Balancer Controller from the Ingress (not managed
# by Terraform), found by the tag the controller sets. The controller is NOT
# installed yet, so monitor_alb defaults to false.
# -----------------------------------------------------------------------------
data "aws_lb" "app" {
  count = var.monitor_alb ? 1 : 0

  name = var.alb_name != "" ? var.alb_name : null
  tags = var.alb_name != "" ? null : { "elbv2.k8s.aws/cluster" = local.cluster_name }
}

# -----------------------------------------------------------------------------
# Encryption key for logs and alert topic. Separate from kms.tf's keys on purpose:
# log groups and SNS need service principals in the key policy, which we do not
# want on the data keys (EBS / RDS / Secrets).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "observability_kms" {
  statement {
    sid       = "EnableAccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowCloudWatchLogsToUseKey"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/containerinsights/*",
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/rds/instance/*",
        "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/eks/*",
      ]
    }
  }

  # CloudWatch alarms and EventBridge publishing into the encrypted SNS topic.
  # (The AWS-managed alias/aws/sns key does NOT allow this, a classic silent failure.)
  statement {
    sid       = "AllowAlarmsAndEventsToPublishToEncryptedTopic"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowRdsEventsToPublishToEncryptedTopic"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["events.rds.amazonaws.com", "rds.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "observability" {
  description             = "${local.name_prefix} logs and alert topic encryption"
  enable_key_rotation     = true
  deletion_window_in_days = local.is_production ? 30 : 7
  policy                  = data.aws_iam_policy_document.observability_kms.json

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-observability" })
}

resource "aws_kms_alias" "observability" {
  name          = "alias/${local.name_prefix}-observability"
  target_key_id = aws_kms_key.observability.key_id
}

# -----------------------------------------------------------------------------
# Alert destination: SNS (encrypted) -> email
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = aws_kms_key.observability.arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowOwnerAccountToManageTopic"
    actions   = ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:AddPermission", "sns:RemovePermission", "sns:DeleteTopic", "sns:Subscribe", "sns:ListSubscriptionsByTopic", "sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowAlarmsAndEventsToPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowRdsEventsToPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.rds.amazonaws.com", "rds.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# Email subscriptions stay "PendingConfirmation" until someone clicks the link.
# Confirm it BEFORE the demo, or no alert will ever arrive.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# Centralised application logs.
# Container Insights (Fluent Bit) writes ALL pod logs into ONE group per cluster.
# Pre-created so retention and encryption are ours: if the agent creates it first
# it gets "never expire" and no CMK. (If it already exists: terraform import.)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "ci_application" {
  name              = "${local.ci_prefix}/application"
  retention_in_days = local.app_retention
  kms_key_id        = aws_kms_key.observability.arn

  tags = local.common_tags
}

# Performance events (source of the pod/node metrics) are noisy and not evidence.
resource "aws_cloudwatch_log_group" "ci_performance" {
  name              = "${local.ci_prefix}/performance"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.observability.arn

  tags = local.common_tags
}

# Database logs, pre-created for the same reason. "audit" (MySQL) and "postgresql"
# (carries pgaudit lines) get the long audit retention.
# OFF by default: where the databases already exist, RDS has already created these groups
# (never expire, no CMK) and creating them here fails with "already exists". To turn on:
#   1. import each existing group once per environment, e.g.
#        tofu import 'aws_cloudwatch_log_group.rds["mysql/error"]' /aws/rds/instance/<id>/error
#      (keys are "<database>/<log type>", see local.db_log_groups)
#   2. set manage_rds_log_groups = true (default in monitoring-variables.tf, as CI passes no var-file)
# For a brand-new environment, set it true from the start and add the depends_on line to
# aws_db_instance.main in rds.tf (infra/rds-depends-on.patch in PR-B) so these groups win.
resource "aws_cloudwatch_log_group" "rds" {
  for_each = var.manage_rds_log_groups ? local.db_log_groups : {}

  name              = "/aws/rds/instance/${each.value.identifier}/${each.value.type}"
  retention_in_days = contains(["audit", "postgresql"], each.value.type) ? local.audit_retention : local.app_retention
  kms_key_id        = aws_kms_key.observability.arn

  tags = local.common_tags
}

# EKS control-plane logs (api, audit, authenticator, controllerManager, scheduler),
# enabled in eks.tf by PR #30. EKS creates this group itself with "never expire" and
# no CMK, and it is not removed on destroy. OFF by default so existing pipelines keep
# working. To turn on (Jack + Jon together):
#   1. eks.tf: add aws_cloudwatch_log_group.eks_control_plane to the cluster's depends_on
#      (the group must exist BEFORE the cluster or EKS creates its own and apply fails).
#   2. If the cluster already exists in that environment, import once, then apply:
#        tofu import 'aws_cloudwatch_log_group.eks_control_plane[0]' /aws/eks/<cluster>/cluster
#   3. set manage_eks_control_plane_log_group = true in environments/<env>/terraform.tfvars
# Audit retention (90 d staging / 365 d production) is the access-logging evidence.
resource "aws_cloudwatch_log_group" "eks_control_plane" {
  count = var.manage_eks_control_plane_log_group ? 1 : 0

  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = local.audit_retention
  kms_key_id        = aws_kms_key.observability.arn

  tags = local.common_tags
}

# ERROR lines -> metric, one per service. Pattern assumes the Fluent Bit record
# format (fields "log" and "kubernetes.container_name"). Verify in Logs Insights
# once real logs flow, and that container_name equals the service name.
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  for_each = local.services

  name           = "${local.name_prefix}-${each.key}-errors"
  log_group_name = aws_cloudwatch_log_group.ci_application.name
  pattern        = "{ ($.kubernetes.container_name = \"${each.key}\") && ($.log = \"*ERROR*\") }"

  metric_transformation {
    name          = "ErrorCount-${each.key}"
    namespace     = "Carelink/${var.environment}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_errors" {
  for_each = aws_cloudwatch_log_metric_filter.app_errors

  alarm_name          = "${local.name_prefix}-${each.key}-error-burst"
  alarm_description   = "More than ${var.app_error_threshold_per_5m} ERROR log lines in 5 min from ${each.key}. See runbook (diagnosis) and the dashboard log widget."
  namespace           = "Carelink/${var.environment}"
  metric_name         = "ErrorCount-${each.key}"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.app_error_threshold_per_5m
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SLI/SLO 1 - Availability (request success rate at the load balancer)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "slo_availability_burn" {
  for_each = local.burn_alarms

  alarm_name          = "${local.name_prefix}-slo-availability-${each.key}-burn"
  alarm_description   = "${each.value.severity}: availability SLO ${var.slo_availability_target}% burn. ${each.value.meaning}. Error rate above ${each.value.threshold}% in ${each.value.datapoints} of ${each.value.evaluation} periods."
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.threshold
  evaluation_periods  = each.value.evaluation
  datapoints_to_alarm = each.value.datapoints
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "req"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.alb_arn_suffix }
    }
  }

  metric_query {
    id          = "t5"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.alb_arn_suffix }
    }
  }

  metric_query {
    id          = "l5"
    return_data = false

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      period      = each.value.period
      stat        = "Sum"
      dimensions  = { LoadBalancer = local.alb_arn_suffix }
    }
  }

  metric_query {
    id          = "errs"
    expression  = "FILL(t5, 0) + FILL(l5, 0)"
    label       = "5xx responses"
    return_data = false
  }

  metric_query {
    id          = "total"
    expression  = "IF(errs > FILL(req, 0), errs, FILL(req, 0))"
    label       = "Total requests (never less than errors)"
    return_data = false
  }

  metric_query {
    id          = "rate"
    expression  = local.error_rate_expression
    label       = "Error rate (%)"
    return_data = true
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# SLI/SLO 2 - Latency (p95 target response time)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "slo_latency_p95" {
  count = var.monitor_alb ? 1 : 0

  alarm_name          = "${local.name_prefix}-slo-latency-p95"
  alarm_description   = "p95 response time above ${var.slo_latency_p95_seconds}s in 3 of 5 five-minute windows. Check dashboard latency widget, then DB CPU/connections."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = local.alb_arn_suffix }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = var.slo_latency_p95_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Failure mode - lost redundancy: fewer than 2 running pods for a service.
# NOTE: a deleted pod is replaced within seconds, usually faster than this alarm's
# 2 x 60 s window. To trip it on demand, scale the Deployment to 1 replica.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "pods_running_low" {
  for_each = var.monitor_eks ? local.services : toset([])

  alarm_name          = "${local.name_prefix}-${each.key}-redundancy-lost"
  alarm_description   = "${each.key} has fewer than ${var.min_running_pods_per_service} running pods. May still be up on one pod, but there is now a single point of failure. See runbook."
  namespace           = "ContainerInsights"
  metric_name         = "service_number_of_running_pods"
  dimensions          = { ClusterName = local.cluster_name, Namespace = var.k8s_namespace, Service = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.min_running_pods_per_service
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = local.is_production ? "breaching" : "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Cluster saturation (nodes)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "eks_cluster" {
  for_each = local.eks_cluster_alarms

  alarm_name          = "${local.name_prefix}-eks-${each.key}"
  alarm_description   = each.value.summary
  namespace           = "ContainerInsights"
  metric_name         = each.value.metric
  dimensions          = { ClusterName = local.cluster_name }
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Databases: saturation alarms per instance + lifecycle events
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = local.rds_alarms

  alarm_name          = "${local.name_prefix}-rds-${each.value.db}-${each.value.kind}"
  alarm_description   = "${each.value.db}: ${each.value.summary}"
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main[each.value.db].identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.datapts
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = local.is_production ? "breaching" : "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}

# "It's 9am Monday and the database just died": this is how we find out in
# minutes, not when a clinic phones. The backup category also gives daily
# evidence that automated backups (RPO) are running.
resource "aws_db_event_subscription" "rds" {
  name        = "${local.name_prefix}-rds-events"
  sns_topic   = aws_sns_topic.alerts.arn
  source_type = "db-instance"
  source_ids  = [for k, v in aws_db_instance.main : v.identifier]
  enabled     = true

  event_categories = [
    "availability",
    "backup",
    "failover",
    "failure",
    "low storage",
    "recovery",
    "restoration",
  ]

  tags = local.common_tags

  depends_on = [aws_sns_topic_policy.alerts]
}

# -----------------------------------------------------------------------------
# "Who can read patient records and how would you know?" - detective controls on
# the management plane (CloudTrail -> CloudWatch Logs). The trail itself is not in
# the repo yet (SA/security); this watches it once it exists.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "cloudtrail" {
  for_each = local.cloudtrail_filters

  name           = "${local.name_prefix}-${each.key}"
  log_group_name = var.cloudtrail_log_group_name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.key
    namespace = "Carelink/Security"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "cloudtrail" {
  for_each = local.cloudtrail_filters

  alarm_name          = "${local.name_prefix}-security-${each.key}"
  alarm_description   = each.value.summary
  namespace           = "Carelink/Security"
  metric_name         = each.key
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = local.common_tags

  depends_on = [aws_cloudwatch_log_metric_filter.cloudtrail]
}

# -----------------------------------------------------------------------------
# Dashboard: answers "is the system healthy right now?" for a non-team-member.
# -----------------------------------------------------------------------------
locals {
  all_alarm_arns = concat(
    [for a in aws_cloudwatch_metric_alarm.slo_availability_burn : a.arn],
    aws_cloudwatch_metric_alarm.slo_latency_p95[*].arn,
    [for a in aws_cloudwatch_metric_alarm.pods_running_low : a.arn],
    [for a in aws_cloudwatch_metric_alarm.eks_cluster : a.arn],
    [for a in aws_cloudwatch_metric_alarm.app_errors : a.arn],
    [for a in aws_cloudwatch_metric_alarm.rds : a.arn],
    [for a in aws_cloudwatch_metric_alarm.cloudtrail : a.arn],
  )

  dash_header = [
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 3
      properties = {
        markdown = "# CareLink ${var.environment}: is it healthy right now?\n**All tiles below green = healthy.** Any red tile = a user-visible risk; see the runbook. SLO: **${var.slo_availability_target}% availability** during clinic hours (08:00-20:00 SGT, about ${floor(360 * 60 * local.error_budget_pct / 100 * 10 + 0.5) / 10} min allowed downtime per 30 days), and **p95 latency under ${var.slo_latency_p95_seconds}s**."
      }
    },
    {
      type   = "alarm"
      x      = 0
      y      = 3
      width  = 24
      height = 4
      properties = {
        title  = "Alarm status (green = OK, red = in alarm, grey = insufficient data)"
        alarms = local.all_alarm_arns
      }
    },
  ]

  dash_alb = [
    {
      type   = "metric"
      x      = 0
      y      = 7
      width  = 8
      height = 6
      properties = {
        title  = "Availability SLI: % of requests succeeding (SLO ${var.slo_availability_target}%)"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "Sum"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { id = "req", visible = false }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { id = "t5", visible = false }],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { id = "l5", visible = false }],
          [{ expression = "100 - IF(req > 0, 100 * (FILL(t5, 0) + FILL(l5, 0)) / req, 0)", label = "Success %", id = "sli" }],
        ]
        yAxis       = { left = { min = 95, max = 100 } }
        annotations = { horizontal = [{ label = "SLO", value = var.slo_availability_target }] }
      }
    },
    {
      type   = "metric"
      x      = 8
      y      = 7
      width  = 8
      height = 6
      properties = {
        title  = "Traffic and errors"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "Sum"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { label = "Requests" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { label = "5xx from app" }],
          ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { label = "5xx from load balancer" }],
        ]
      }
    },
    {
      type   = "metric"
      x      = 16
      y      = 7
      width  = 8
      height = 6
      properties = {
        title  = "Latency SLI: p95 response time (SLO ${var.slo_latency_p95_seconds}s)"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "p95"
        metrics = [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { label = "p95 seconds" }],
        ]
        annotations = { horizontal = [{ label = "SLO", value = var.slo_latency_p95_seconds }] }
      }
    },
  ]

  dash_eks = [
    {
      type   = "metric"
      x      = 0
      y      = 13
      width  = 12
      height = 6
      properties = {
        title  = "Running pods per service (2 = redundant, 1 = single point of failure)"
        region = var.aws_region
        view   = "timeSeries"
        period = 60
        stat   = "Minimum"
        metrics = [
          for svc in var.microservices :
          ["ContainerInsights", "service_number_of_running_pods", "ClusterName", local.cluster_name, "Namespace", var.k8s_namespace, "Service", svc, { label = svc }]
        ]
        yAxis = { left = { min = 0 } }
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 13
      width  = 12
      height = 6
      properties = {
        title  = "Cluster nodes: CPU % and memory %"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "Average"
        metrics = [
          ["ContainerInsights", "node_cpu_utilization", "ClusterName", local.cluster_name, { label = "Node CPU %" }],
          ["ContainerInsights", "node_memory_utilization", "ClusterName", local.cluster_name, { label = "Node memory %" }],
        ]
      }
    },
  ]

  dash_rds = [
    {
      type   = "metric"
      x      = 0
      y      = 19
      width  = 12
      height = 6
      properties = {
        title  = "Databases: CPU %"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "Average"
        metrics = [
          for k, v in aws_db_instance.main :
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", v.identifier, { label = "${k} CPU %" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 19
      width  = 12
      height = 6
      properties = {
        title  = "Databases: free storage (GiB)"
        region = var.aws_region
        view   = "timeSeries"
        period = 300
        stat   = "Average"
        # concat, not flatten: flatten() also flattens each metric row, and the
        # dashboard API then rejects "metrics" (it must be an array of arrays).
        metrics = concat(
          [for k, v in aws_db_instance.main : ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", v.identifier, { id = "fs_${k}", visible = false }]],
          [for k, v in aws_db_instance.main : [{ expression = "fs_${k} / 1073741824", label = "${k} free GiB", id = "fsg_${k}" }]],
        )
      }
    },
  ]

  dash_logs = [
    {
      type   = "log"
      x      = 0
      y      = 25
      width  = 24
      height = 8
      properties = {
        title  = "Recent application errors (all services, newest first)"
        region = var.aws_region
        view   = "table"
        query  = "SOURCE '${aws_cloudwatch_log_group.ci_application.name}' | fields @timestamp, kubernetes.container_name as service, log | filter log like /ERROR|Exception/ | sort @timestamp desc | limit 50"
      }
    },
  ]

  dashboard_widgets = concat(
    local.dash_header,
    [for w in local.dash_alb : w if var.monitor_alb],
    [for w in local.dash_eks : w if var.monitor_eks],
    local.dash_rds,
    local.dash_logs,
  )
}

resource "aws_cloudwatch_dashboard" "health" {
  dashboard_name = "${local.name_prefix}-health"
  dashboard_body = jsonencode({ widgets = local.dashboard_widgets })
}
