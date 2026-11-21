# Manage the existing Alertmanager Discord webhook secret.
# The webhook value remains in AWS Secrets Manager.
resource "aws_secretsmanager_secret" "alertmanager_discord_webhook" {
  name        = "${local.name_prefix}-discord-webhook"
  description = "CareLink ${var.environment} Discord alert webhook"
  # Our customer-managed key, like the other secrets. External Secrets may
  # decrypt with it through Secrets Manager only (app-database.tf).
  kms_key_id = aws_kms_key.this["secrets"].arn

  tags = {
    Environment = var.environment
  }
}
