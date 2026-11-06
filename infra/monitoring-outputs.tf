# =============================================================================
# monitoring-outputs.tf  (SRE)  -- separate file so it cannot collide with the
# shared outputs.tf. Evidence for the demo and README.
# =============================================================================

output "alerts_topic_arn" {
  description = "SNS topic receiving all alarms and RDS events."
  value       = aws_sns_topic.alerts.arn
}

output "observability_kms_key_arn" {
  description = "CMK encrypting log groups and the alert topic."
  value       = aws_kms_key.observability.arn
}

output "app_log_group_name" {
  description = "Central application log group (all pods, via Container Insights / Fluent Bit)."
  value       = aws_cloudwatch_log_group.ci_application.name
}

output "rds_log_group_names" {
  description = "RDS log type => log group (empty unless manage_rds_log_groups is true)."
  value       = { for k, g in aws_cloudwatch_log_group.rds : k => g.name }
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.health.dashboard_name
}

output "dashboard_url" {
  description = "Open this during the demo and share with the panel."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.health.dashboard_name}"
}

output "alarm_arns" {
  description = "Every alarm created by monitoring.tf."
  value       = local.all_alarm_arns
}

output "slo_burn_thresholds_pct" {
  description = "Error-rate thresholds derived from the availability SLO (fast = page, slow = ticket)."
  value = {
    error_budget_pct = local.error_budget_pct
    fast_burn_14_4x  = local.fast_burn_threshold
    slow_burn_6x     = local.slow_burn_threshold
  }
}
