# ------------------------------------------------------------------------------
# Alert destination 2: SNS -> Lambda -> Discord (webhook kept in Secrets Manager)
#
# Email (monitoring.tf) stays as the fallback. SNS cannot post to Discord
# directly because Discord expects its own JSON shape, hence the small Lambda.
#
# Off by default. To switch on:
#   1. Set discord_alerts_enabled = true (e.g. TF_VAR_discord_alerts_enabled from CI).
#   2. Apply once; this creates an EMPTY secret.
#   3. Put the webhook in it out of band (never in Git, tfvars or state):
#        aws secretsmanager put-secret-value --secret-id <output discord_webhook_secret_name> \
#          --secret-string 'https://discord.com/api/webhooks/...'
#   4. Test: aws sns publish --topic-arn <alerts topic> --subject test --message "hello"
# ------------------------------------------------------------------------------

variable "discord_alerts_enabled" {
  description = "Create the SNS -> Discord bridge (Lambda + empty secret). The webhook value is set outside Terraform."
  type        = bool
  default     = false
}

locals {
  discord_on = var.discord_alerts_enabled
}

resource "aws_secretsmanager_secret" "discord_webhook" {
  count = local.discord_on ? 1 : 0

  name                    = "${local.name_prefix}-discord-webhook"
  description             = "Discord webhook URL for the alert bridge. Value is set with put-secret-value, not Terraform."
  kms_key_id              = aws_kms_key.this["secrets"].arn
  recovery_window_in_days = local.is_production ? 7 : 0

  tags = local.common_tags
}

data "archive_file" "discord_notify" {
  count = local.discord_on ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/discord_notify.py"
  output_path = "${path.module}/.build/discord_notify.zip"
}

resource "aws_cloudwatch_log_group" "discord_notify" {
  count = local.discord_on ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-discord-notify"
  retention_in_days = local.app_retention
  kms_key_id        = aws_kms_key.observability.arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "discord_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "discord_notify" {
  count = local.discord_on ? 1 : 0

  name               = "${local.name_prefix}-discord-notify"
  assume_role_policy = data.aws_iam_policy_document.discord_assume.json
  tags               = local.common_tags
}

# Least privilege: read ONE secret, decrypt with its key, write its own logs.
data "aws_iam_policy_document" "discord_notify" {
  count = local.discord_on ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.discord_webhook[0].arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this["secrets"].arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.discord_notify[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "discord_notify" {
  count = local.discord_on ? 1 : 0

  name   = "discord-notify"
  role   = aws_iam_role.discord_notify[0].id
  policy = data.aws_iam_policy_document.discord_notify[0].json
}

resource "aws_lambda_function" "discord_notify" {
  count = local.discord_on ? 1 : 0

  function_name    = "${local.name_prefix}-discord-notify"
  role             = aws_iam_role.discord_notify[0].arn
  runtime          = "python3.12"
  handler          = "discord_notify.handler"
  filename         = data.archive_file.discord_notify[0].output_path
  source_code_hash = data.archive_file.discord_notify[0].output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      WEBHOOK_SECRET_ID = aws_secretsmanager_secret.discord_webhook[0].name
      ENVIRONMENT       = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.discord_notify, aws_iam_role_policy.discord_notify]
  tags       = local.common_tags
}

resource "aws_lambda_permission" "sns_invoke_discord" {
  count = local.discord_on ? 1 : 0

  statement_id  = "AllowAlertsTopicToInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.discord_notify[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "discord" {
  count = local.discord_on ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.discord_notify[0].arn
}

output "discord_webhook_secret_name" {
  description = "Put the Discord webhook URL here with aws secretsmanager put-secret-value."
  value       = local.discord_on ? aws_secretsmanager_secret.discord_webhook[0].name : null
}
