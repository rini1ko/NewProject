"""Report builder, run as the `meetings-reports-builder` Lambda.

Same container image as the API, different command (see infra/reports.yaml):
    uvicorn app.reports.worker:app --host 0.0.0.0 --port 8000

Lambda Web Adapter forwards every non-HTTP event (EventBridge Scheduler, SQS) to POST /events
with the event JSON as the body, and returns our response body as the function result.
"""

import asyncio
import json
import logging
import os

import boto3
from fastapi import FastAPI, Request

from app.reports.weekly import build_weekly_report, previous_week, report_key

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("report-builder")

BUCKET = os.environ.get("REPORTS_BUCKET", "")
s3 = boto3.client("s3")
app = FastAPI()


def detect_trigger(event: dict) -> str:
    records = event.get("Records")
    if records and records[0].get("eventSource") == "aws:sqs":
        return "sqs"
    if event.get("source") == "schedule":
        return "schedule"
    return "direct"


async def build_and_store(payload: dict, trigger: str) -> str:
    week = payload.get("week") or previous_week()
    log.info(
        "report-builder triggered trigger=%s source=%s week=%s",
        trigger,
        payload.get("source", "-"),
        week,
    )
    data = await build_weekly_report(week)
    key = report_key(week)  # same week -> same key -> overwrite, never a duplicate
    await asyncio.to_thread(
        s3.put_object,
        Bucket=BUCKET,
        Key=key,
        Body=data,
        ContentType="text/csv; charset=utf-8",
    )
    log.info("report saved bucket=%s key=%s bytes=%d", BUCKET, key, len(data))
    return key


def fail_invocation(reason: str) -> None:
    """Make Lambda see this invocation as failed.

    Lambda Web Adapter treats any response to a non-HTTP event (SQS, Scheduler) as success and
    ignores the HTTP status code, so returning a 5xx does not fail the invocation. The only way to
    fail it is to die mid-request: the adapter loses the connection and reports an invocation
    error. SQS then shows the message again after the visibility timeout and moves it to the DLQ
    after maxReceiveCount attempts. The next invocation starts a fresh container.
    """
    log.error("failing the invocation: %s", reason)
    logging.shutdown()  # flush the log lines first
    os._exit(1)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.post("/events")
async def events(request: Request):
    event = await request.json()
    trigger = detect_trigger(event)

    if trigger == "sqs":
        failed = []
        for record in event["Records"]:
            try:
                await build_and_store(json.loads(record["body"] or "{}"), trigger)
            except Exception:
                log.exception("report failed messageId=%s", record["messageId"])
                failed.append(record["messageId"])
        if failed:
            fail_invocation(f"report failed for messages {failed}")
        return {"batchItemResponses": []}

    try:
        key = await build_and_store(event, trigger)
    except Exception:
        log.exception("report failed")
        fail_invocation("report failed")
    return {"ok": True, "key": key}