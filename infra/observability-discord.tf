# Manage the existing Alertmanager Discord webhook secret.
# The webhook value remains in AWS Secrets Manager.
resource "aws_secretsmanager_secret" "alertmanager_discord_webhook" {
  name        = "${local.name_prefix}-discord-webhook"
  description = "CareLink ${var.environment} Discord alert webhook"

  tags = {
    Environment = var.environment
  }
}
