"""Agenda parser, run as the `meetings-ai-parser` Lambda behind its own function URL.

Same container image as the API, different command (see infra/ai.yml):
    uvicorn app.ai.agenda_lambda:app --host 0.0.0.0 --port 8000

The image has no Lambda runtime client, only Lambda Web Adapter, so the "handler" is an ASGI app
(exactly like the report builder). The function is NOT in the VPC: it needs no database, only
Bedrock. It never writes anything; saving goes through the normal API.

CORS is configured on the function URL itself, so there is no CORS middleware here.
"""

import asyncio
import json
import logging
import time
from datetime import date
from typing import Annotated

import anthropic
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from app.ai.agenda import PROMPT_VERSION, AgendaParseError, cost_usd, parse_agenda

# app.auth also imports the database module; that only builds an engine (no connection is made).
from app.auth import InvalidTokenError, TokenVerifier, get_verifier
from app.config import settings

logging.basicConfig(level=logging.INFO, format="%(message)s")  # one JSON object per line
log = logging.getLogger("agenda-parser")

MAX_TEXT_CHARS = 10_000
THROTTLING = {"ThrottlingException", "TooManyRequestsException", "ServiceQuotaExceededException"}

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


def fail(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse({"error": code, "message": message}, status_code=status)


@app.exception_handler(HTTPException)
async def http_error(_, error: HTTPException) -> JSONResponse:
    code = "unauthorized" if error.status_code == 401 else "error"
    return JSONResponse(
        {"error": code, "message": str(error.detail)},
        status_code=error.status_code,
        headers=error.headers,
    )


@app.exception_handler(RequestValidationError)
async def bad_request(_, error: RequestValidationError) -> JSONResponse:
    return fail(422, "bad_request", "Expected JSON with text, today (YYYY-MM-DD) and tz")


class ParseRequest(BaseModel):
    text: str
    today: date
    # Goes into the prompt, so only characters a time-zone name can have.
    tz: str = Field(pattern=r"^[A-Za-z0-9_+\-/]{1,64}$")


async def current_sub(
    verifier: Annotated[TokenVerifier, Depends(get_verifier)],
    authorization: Annotated[str | None, Header()] = None,
) -> str:
    """Every parse costs money, so only signed-in users get one (the same Cognito ID token)."""
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(401, "Not authenticated", headers={"WWW-Authenticate": "Bearer"})
    try:
        claims = await verifier.verify(token)
    except InvalidTokenError:
        raise HTTPException(
            401, "Invalid or expired token", headers={"WWW-Authenticate": "Bearer"}
        ) from None
    return claims["sub"]


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/parse")
async def parse(body: ParseRequest, sub: Annotated[str, Depends(current_sub)]):
    text = body.text.strip()
    if not text:
        return fail(422, "bad_request", "The text is empty")
    if len(text) > MAX_TEXT_CHARS:  # rejected before any model call
        return fail(413, "too_long", f"The text is longer than {MAX_TEXT_CHARS} characters")

    started = time.monotonic()
    usage = {"input_tokens": 0, "output_tokens": 0}
    outcome = "ok"
    try:
        agenda, usage = await asyncio.to_thread(parse_agenda, text, body.today, body.tz)
    except AgendaParseError as error:
        usage, outcome = error.usage, "no_agenda"
        response = fail(422, "no_agenda", str(error))
    except (anthropic.RateLimitError, ClientError, BotoCoreError, anthropic.APIError) as error:
        code = error.response["Error"]["Code"] if isinstance(error, ClientError) else ""
        if isinstance(error, anthropic.RateLimitError) or code in THROTTLING:
            outcome = "throttled"
            response = fail(429, "busy", "The AI service is busy. Try again in a minute.")
        else:  # connection, timeout, 5xx, access denied, ...
            outcome = f"upstream:{code or type(error).__name__}"
            log.exception("bedrock call failed")
            response = fail(
                502, "upstream", "The AI service is unavailable. Type the agenda by hand."
            )
    else:
        response = JSONResponse(
            {
                "agenda": agenda.model_dump(mode="json"),
                "model": settings.parser_model,
                "prompt_version": PROMPT_VERSION,
            }
        )

    # One line per parse: this is what you read in CloudWatch to know what the feature costs.
    log.info(
        json.dumps(
            {
                "event": "agenda_parsed",
                "outcome": outcome,
                "user": sub,
                "model": settings.parser_model,
                "api": settings.parser_api,
                "prompt_version": PROMPT_VERSION,
                **usage,
                "latency_ms": int((time.monotonic() - started) * 1000),
                "cost_usd": cost_usd(settings.parser_model, usage),
            }
        )
    )
    return response
