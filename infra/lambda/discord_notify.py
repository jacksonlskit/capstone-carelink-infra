"""SNS -> Discord bridge for the CareLink alert topic.

Reads the webhook URL from Secrets Manager (never from env vars or Terraform
state), turns CloudWatch alarm / EventBridge / plain SNS messages into one
Discord embed, and posts it. Raises on failure so SNS retries the delivery.
"""
import json
import os
import time
import urllib.error
import urllib.request

import boto3

SECRET_ID = os.environ["WEBHOOK_SECRET_ID"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "unknown")
_secrets = boto3.client("secretsmanager")
_cache = {"url": None, "at": 0.0}

COLOURS = {"ALARM": 0xE74C3C, "OK": 0x2ECC71, "INSUFFICIENT_DATA": 0x95A5A6}


def webhook_url():
    # Cache for 5 min so a rotated webhook is picked up without a redeploy.
    if _cache["url"] is None or time.time() - _cache["at"] > 300:
        secret = _secrets.get_secret_value(SecretId=SECRET_ID)["SecretString"]
        try:  # accept either a bare URL or {"url": "..."}
            secret = json.loads(secret)["url"]
        except (ValueError, KeyError, TypeError):
            pass
        _cache.update(url=secret.strip(), at=time.time())
    return _cache["url"]


def build_embed(subject, message):
    try:
        data = json.loads(message)
    except ValueError:
        data = None

    if isinstance(data, dict) and "AlarmName" in data:  # CloudWatch alarm
        state = data.get("NewStateValue", "UNKNOWN")
        return {
            "title": f"[{ENVIRONMENT}] {state}: {data['AlarmName']}"[:250],
            "description": (data.get("NewStateReason") or "")[:1500],
            "color": COLOURS.get(state, 0x95A5A6),
            "fields": [
                {"name": "Was", "value": str(data.get("OldStateValue", "-")), "inline": True},
                {"name": "Metric", "value": str(data.get("Trigger", {}).get("MetricName", "-"))[:200], "inline": True},
                {"name": "Description", "value": (data.get("AlarmDescription") or "-")[:900]},
            ],
            "timestamp": data.get("StateChangeTime"),
        }
    if isinstance(data, dict) and "detail" in data:  # EventBridge (e.g. RDS events)
        d = data["detail"]
        text = d.get("Message") or d.get("EventID") or json.dumps(d)
        return {
            "title": f"[{ENVIRONMENT}] {data.get('detail-type', 'AWS event')}"[:250],
            "description": str(text)[:1500],
            "color": 0xF39C12,
            "fields": [{"name": "Source", "value": str(data.get("source", "-"))[:200]}],
        }
    return {  # anything else (RDS event subscription text, manual publish)
        "title": f"[{ENVIRONMENT}] {subject or 'AWS notification'}"[:250],
        "description": (message or "")[:1500],
        "color": 0x3498DB,
    }


def post(payload):
    req = urllib.request.Request(
        webhook_url(),
        data=json.dumps(payload).encode(),
        # Discord rejects the default Python user agent with HTTP 403.
        headers={"Content-Type": "application/json", "User-Agent": "carelink-alerts/1.0"},
    )
    for attempt in range(2):
        try:
            urllib.request.urlopen(req, timeout=10).read()
            return
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt == 0:  # rate limited: honour Retry-After once
                time.sleep(min(float(e.headers.get("Retry-After", "1")), 5))
                continue
            raise


def handler(event, _context):
    for record in event["Records"]:
        sns = record["Sns"]
        post({"username": "CareLink alerts", "embeds": [build_embed(sns.get("Subject"), sns.get("Message", ""))]})
    return {"delivered": len(event["Records"])}
