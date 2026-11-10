# =============================================================================
# monitoring-variables.tf  (SRE: Jon / Shilpa)  -- reconciled with infra/ on 24 Oct
#
# Own file so it cannot collide with variables.tf. Re-uses what already exists:
#   var.project, var.environment, var.aws_region, var.tags, var.microservices,
#   var.databases, local.name_prefix, local.common_tags, local.cluster_id,
#   local.db_log_exports (rds.tf), data.aws_caller_identity.current (kms.tf).
#
# IMPORTANT: the workflows pass only -var="environment=..." and the tfvars files
# are empty and git-ignored. Every variable here therefore has a safe default,
# and per-environment differences are derived from var.environment in code.
# =============================================================================

variable "alert_email" {
  description = "Destination for alarm and RDS event notifications. Empty = no email subscription is created (alarms still exist). Do NOT commit a real address (public repo): pass it from CI as TF_VAR_alert_email taken from a GitHub variable named ALERT_EMAIL. The subscription must then be confirmed from the email AWS sends."
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be empty or look like an email address."
  }
}

# ---- Feature switches --------------------------------------------------------

variable "manage_eks_control_plane_log_group" {
  description = "Manage /aws/eks/<cluster>/cluster in Terraform (retention + CMK). Needs the depends_on in eks.tf and, for an existing cluster, a one-time import. See monitoring.tf."
  type        = bool
  default     = false
}

variable "manage_rds_log_groups" {
  description = "Manage the RDS log groups (retention + KMS) in Terraform. Leave false where the databases already exist: RDS has already created these groups and the first apply would fail with 'already exists'. Import them first (see the comment above aws_cloudwatch_log_group.rds in monitoring.tf), then set true."
  type        = bool
  default     = false
}

variable "monitor_eks" {
  description = "Create pod/node alarms and dashboard widgets that read Container Insights metrics. Leave false until the amazon-cloudwatch-observability add-on is installed (PR-B: monitoring-eks-addon.tf), otherwise these alarms have no data and the production ones (treat_missing_data = breaching) go red on the first apply."
  type        = bool
  default     = false
}

variable "monitor_alb" {
  description = "Create ALB-based SLO alarms and dashboard widgets. Requires an Ingress handled by the AWS Load Balancer Controller (which is NOT installed yet), so keep false until the app is reachable through an ALB."
  type        = bool
  default     = false
}

variable "alb_name" {
  description = "Optional: look the ALB up by name. Empty = look it up by the tag the AWS Load Balancer Controller sets (elbv2.k8s.aws/cluster = <cluster name>)."
  type        = string
  default     = ""
}

variable "monitor_cloudtrail" {
  description = "Create security metric filters and alarms on a CloudTrail log group."
  type        = bool
  default     = false
}

variable "cloudtrail_log_group_name" {
  description = "CloudWatch Logs group CloudTrail delivers to (required when monitor_cloudtrail = true)."
  type        = string
  default     = ""
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the PetClinic services run in."
  type        = string
  default     = "petclinic"
}

# ---- SLOs --------------------------------------------------------------------

variable "slo_availability_target" {
  description = "Availability SLO (%) during clinic hours 08:00-20:00 SGT. Brief hard constraint: 99.9."
  type        = number
  default     = 99.9

  validation {
    condition     = var.slo_availability_target >= 90 && var.slo_availability_target < 100
    error_message = "slo_availability_target must be >= 90 and < 100."
  }
}

variable "slo_latency_p95_seconds" {
  description = "Latency SLO: p95 response time target (seconds) at the load balancer."
  type        = number
  default     = 1
}

variable "alert_clinic_hours_only" {
  description = "If true, SLO burn alarms only count 00:00-12:00 UTC (= 08:00-20:00 SGT). Leave false for demos, otherwise an evening demo will not alarm."
  type        = bool
  default     = false
}

# ---- Thresholds --------------------------------------------------------------

variable "min_running_pods_per_service" {
  description = "Alarm when a service has fewer running pods than this (2 = redundancy lost, the 'survive one instance failure' signal)."
  type        = number
  default     = 2
}

variable "app_error_threshold_per_5m" {
  description = "Alarm when a service logs more than this many ERROR lines in 5 minutes."
  type        = number
  default     = 20
}

variable "node_cpu_alarm_pct" {
  description = "Alarm when average node CPU across the cluster exceeds this %."
  type        = number
  default     = 80
}

variable "node_memory_alarm_pct" {
  description = "Alarm when average node memory across the cluster exceeds this %."
  type        = number
  default     = 85
}

variable "rds_min_free_storage_gib" {
  description = "Alarm when RDS free storage falls below this many GiB (initial allocation is 20 GiB)."
  type        = number
  default     = 5
}

variable "rds_min_freeable_memory_mib" {
  description = "Alarm when RDS freeable memory falls below this many MiB (db.t4g.small has about 2 GiB in total)."
  type        = number
  default     = 128
}

# ---- Log retention (null = environment default: staging 14/90 days, production 90/365) ----

variable "app_log_retention_days" {
  description = "Retention for application logs. Null = 14 days in staging, 90 in production."
  type        = number
  default     = null

  validation {
    condition     = var.app_log_retention_days == null ? true : contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731], var.app_log_retention_days)
    error_message = "Must be null or a retention value CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731)."
  }
}

variable "audit_log_retention_days" {
  description = "Retention for database audit-type logs (evidence of who accessed patient data). Null = 90 days in staging, 365 in production."
  type        = number
  default     = null

  validation {
    condition     = var.audit_log_retention_days == null ? true : contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731], var.audit_log_retention_days)
    error_message = "Must be null or a retention value CloudWatch Logs accepts."
  }
}
