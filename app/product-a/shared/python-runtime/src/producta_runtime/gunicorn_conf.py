"""Shared gunicorn configuration for Product A's FastAPI services.

Loaded by every Python image with

    CMD ["gunicorn", "-c", "python:producta_runtime.gunicorn_conf", "--bind", "0.0.0.0:8000", "app:app"]

Why gunicorn in front of uvicorn at all: a CPython worker that once handled a burst of large
payloads never gives that RSS back, because glibc keeps each thread's arena at its high-water
mark. The only complete cure is to recycle the worker process now and then. uvicorn's own
`--limit-max-requests` cannot do that with a single worker: with one worker uvicorn runs
in-process, so reaching the limit simply exits the server. gunicorn's arbiter respawns the worker,
keeps the listening socket open meanwhile (requests wait in the backlog for the few seconds a new
worker needs to import the app, nothing fails), and gives in-flight requests `graceful_timeout`
before the old worker is killed.

Exactly ONE worker by default, and the reason is load-bearing: a module keeps request-scoped job
state in process memory (a long analysis is started by one request and polled by later ones), so
a second worker would answer the polls with 404. One more worker also costs a full extra
interpreter plus imports (~150 MB) that a memory-limited pod does not have. Recycling, not
parallelism, is the point; scale out with replicas.

Every knob is an env var, so it can be tuned from the chart's ConfigMap without a rebuild:

    GUNICORN_WORKERS               default 1
    GUNICORN_MAX_REQUESTS          default 300   (0 disables recycling)
    GUNICORN_MAX_REQUESTS_JITTER   default 10 % of max_requests
    GUNICORN_TIMEOUT               default 600 s, a worker heartbeat, NOT a request limit
    GUNICORN_GRACEFUL_TIMEOUT      default 600 s, in-flight grace on recycle and on SIGTERM
    GUNICORN_LOG_LEVEL             default warning

Readiness probes count as requests: at one probe per 15 s an idle pod recycles every ~75 minutes
on the default 300, which is a bounded, cheap event.

The 600 s timeouts are deliberate: an analysis call runs one to several minutes and its caller
waits up to 600 s. The default graceful_timeout of 30 s would kill it on every recycle. The
chart's terminationGracePeriodSeconds is sized to match, so SIGTERM gets the same grace.
"""

from __future__ import annotations

import os


def _env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


worker_class = "uvicorn_worker.UvicornWorker"
workers = max(1, _env_int("GUNICORN_WORKERS", 1))

max_requests = max(0, _env_int("GUNICORN_MAX_REQUESTS", 300))
max_requests_jitter = max(0, _env_int("GUNICORN_MAX_REQUESTS_JITTER", max_requests // 10))

timeout = max(0, _env_int("GUNICORN_TIMEOUT", 600))
graceful_timeout = max(0, _env_int("GUNICORN_GRACEFUL_TIMEOUT", 600))
keepalive = 5

# Newer gunicorn releases open a management socket under $HOME by default. Nothing uses it, and on
# a read-only root filesystem creating it fails with an ERROR line on every boot. Older releases
# ignore the unknown setting.
control_socket_disable = True

# The app's own request log replaces gunicorn's access log (which would duplicate every request as
# an unstructured line and include the query string).
accesslog = None
loglevel = (os.environ.get("GUNICORN_LOG_LEVEL") or "warning").lower()

# Import the app in the worker, not in the arbiter, so logging setup and every module-level client
# belong to the process that gets recycled.
preload_app = False
