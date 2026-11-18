"""product-a-module - STUB of an LLM analysis module (FastAPI).

The real module ran a multi-step LLM extraction and called the platform's tools over MCP. All of
that is gone; what is left is the platform contract:

  * configuration from environment variables only (ConfigMap via envFrom, secrets via secretKeyRef);
  * /health/live = the process answers; /health/ready = the configuration is complete;
  * JSON logs on stdout through the shared runtime (same field names as the .NET services);
  * SIGTERM is handled by gunicorn (graceful_timeout), the app only logs its shutdown.
"""

from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, fields

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from producta_runtime import configure_logging

SERVICE = "product-a-module"
configure_logging(SERVICE)
log = logging.getLogger("module")


@dataclass(frozen=True)
class Settings:
    """Everything the module needs, read once at import. Field name == env var name, lower-cased."""

    api_base_url: str
    llm_base_url: str
    llm_deployment: str
    m2m_token_url: str
    m2m_client_id: str
    # The two below come from the Key Vault-synced Secret with `optional: true`: the pod starts
    # without them and reports itself not ready (below) instead of crash-looping with a stack trace.
    llm_api_key: str
    m2m_client_secret: str

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(**{f.name: (os.environ.get(f.name.upper()) or "").strip() for f in fields(cls)})

    def missing(self) -> list[str]:
        # Names only, never values: this list ends up in a log line and in a probe response.
        return [f.name.upper() for f in fields(self) if not getattr(self, f.name)]


settings = Settings.from_env()


@asynccontextmanager
async def lifespan(_: FastAPI):
    missing = settings.missing()
    if missing:
        log.warning("Configuration incomplete, readiness will fail", extra={"missing": missing})
    log.info("Module started", extra={"llm_deployment": settings.llm_deployment or None})
    yield
    # gunicorn turns SIGTERM into a graceful worker stop: in-flight requests finish (up to
    # graceful_timeout), then the lifespan ends here.
    log.info("Module stopping")


app = FastAPI(title=SERVICE, lifespan=lifespan, docs_url=None, redoc_url=None)


@app.middleware("http")
async def request_log(request: Request, call_next):
    started = time.perf_counter()
    response = await call_next(request)
    probe = request.headers.get("user-agent", "").startswith("kube-probe/")
    if not (probe and response.status_code < 400):
        log.info(
            "HTTP %s %s responded %s",
            request.method,
            request.url.path,  # path only: the query string is never logged
            response.status_code,
            extra={
                "http_method": request.method,
                "http_path": request.url.path,
                "http_status": response.status_code,
                "duration_ms": int((time.perf_counter() - started) * 1000),
            },
        )
    return response


@app.get("/health/live")
def live() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/health/ready")
def ready() -> JSONResponse:
    missing = settings.missing()
    if missing:
        return JSONResponse(status_code=503, content={"status": "not-ready", "missing": missing})
    return JSONResponse(content={"status": "ready"})


@app.post("/analyze")
def analyze() -> dict[str, str]:
    # Stub: the real endpoint ran the extraction pipeline for one document.
    return {"status": "stub"}
