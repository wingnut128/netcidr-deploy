"""Cloud Run Function: forward Cloud Build status events to Slack.

Subscribes to the `cloud-builds` Pub/Sub topic. Filters events for our
netcidr build trigger (matches on the image name in the build tags) and
posts a formatted message to a Slack webhook stored in Secret Manager.
"""

from __future__ import annotations

import base64
import json
import logging
import os
from urllib import request as urlrequest

import functions_framework
from google.cloud import secretmanager

LOG = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

PROJECT_ID = os.environ["GCP_PROJECT"]
SECRET_NAME = os.environ.get("SLACK_SECRET_NAME", "slack-webhook-cloudbuild")
IMAGE_FILTER = os.environ.get("IMAGE_FILTER", "netcidr")

_STATUS_EMOJI = {
    "SUCCESS": ":white_check_mark:",
    "FAILURE": ":x:",
    "INTERNAL_ERROR": ":x:",
    "TIMEOUT": ":hourglass_flowing_sand:",
    "CANCELLED": ":no_entry_sign:",
    "WORKING": ":hammer_and_wrench:",
    "QUEUED": ":inbox_tray:",
}

# Only notify on terminal states — skip noisy WORKING/QUEUED updates.
_NOTIFY_STATUSES = {"SUCCESS", "FAILURE", "INTERNAL_ERROR", "TIMEOUT", "CANCELLED"}


def _webhook_url() -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{PROJECT_ID}/secrets/{SECRET_NAME}/versions/latest"
    return client.access_secret_version(name=name).payload.data.decode("utf-8")


def _relevant(build: dict) -> bool:
    for image in build.get("images", []) or []:
        if IMAGE_FILTER in image:
            return True
    for tag in (build.get("tags") or []):
        if IMAGE_FILTER in tag:
            return True
    substitutions = build.get("substitutions") or {}
    service = substitutions.get("_SERVICE_NAME", "")
    return IMAGE_FILTER in service


def _format_message(build: dict) -> dict:
    status = build.get("status", "UNKNOWN")
    emoji = _STATUS_EMOJI.get(status, ":grey_question:")
    build_id = build.get("id", "unknown")
    log_url = build.get("logUrl", "")
    substitutions = build.get("substitutions") or {}
    ref = substitutions.get("_NETCIDR_REF", "—")
    service = substitutions.get("_SERVICE_NAME", "netcidr")
    duration = build.get("timing", {}).get("BUILD", {})

    lines = [
        f"{emoji} *Cloud Build {status}* — `{service}` @ `{ref}`",
        f"<{log_url}|View logs> · build `{build_id[:8]}`",
    ]
    if duration.get("startTime") and duration.get("endTime"):
        lines.append(f"Duration: {duration['startTime']} → {duration['endTime']}")

    return {"text": "\n".join(lines)}


def _post_to_slack(webhook: str, payload: dict) -> None:
    req = urlrequest.Request(
        webhook,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urlrequest.urlopen(req, timeout=5) as resp:
        if resp.status >= 300:
            raise RuntimeError(f"Slack returned HTTP {resp.status}")


@functions_framework.cloud_event
def notify(event) -> None:
    message = event.data.get("message", {})
    data = message.get("data")
    if not data:
        LOG.info("Pub/Sub message has no data; skipping")
        return

    build = json.loads(base64.b64decode(data).decode("utf-8"))
    status = build.get("status", "UNKNOWN")

    if status not in _NOTIFY_STATUSES:
        LOG.info("Skipping non-terminal status: %s", status)
        return

    if not _relevant(build):
        LOG.info("Build not relevant to %s; skipping", IMAGE_FILTER)
        return

    _post_to_slack(_webhook_url(), _format_message(build))
    LOG.info("Posted %s notification for build %s", status, build.get("id"))
