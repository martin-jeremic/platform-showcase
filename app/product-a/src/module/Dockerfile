# syntax=docker/dockerfile:1
# product-a-module image (Python / FastAPI behind gunicorn).
#
# Build context is the MONOREPO ROOT, like the .NET images: that is what lets this image install
# the shared Python runtime from shared/python-runtime, exactly as the .NET images reach their
# shared class library.
#   docker build -f src/module/Dockerfile -t product-a-module .
#
# Stages:
#   build - installs every dependency into a virtualenv (/opt/venv) that has no pip of its own.
#   final - the same Python base plus only that venv and the app code, non-root, no installer.

# One base for both stages: the venv's interpreter is a symlink to this image's Python.
ARG PYTHON_IMAGE=python:3.13-slim

FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
# A venv WITHOUT pip: the base image's pip installs into it (`--python`), so the venv copied into
# `final` carries no installer. pip vendors its own urllib3, requests and friends, and every copy
# of it in the runtime image shows up in the vulnerability scan.
RUN python -m venv --without-pip /opt/venv

COPY src/module/requirements.txt /tmp/requirements.txt
RUN pip --python /opt/venv/bin/python install -r /tmp/requirements.txt

# Shared runtime (JSON log contract + gunicorn config), installed BY PATH from the monorepo and
# after the pinned requirements, so editing it does not invalidate the dependency layer above.
COPY shared/python-runtime/ /tmp/python-runtime/
RUN pip --python /opt/venv/bin/python install /tmp/python-runtime

FROM ${PYTHON_IMAGE} AS final
ARG VERSION=0.0.0-local
ARG REVISION=unknown
ARG SOURCE=unknown
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.source=$SOURCE

# Nothing installs packages at run time, and the venv cannot see system site-packages anyway, so
# the base image's own pip goes too.
RUN python -m pip uninstall --yes pip

# Same UID and GID as the .NET images' `app` user (1654:1654), so one pod security policy and one
# set of file ownership rules covers both. Both IDs are given explicitly: with --user-group alone,
# `useradd --system` picks the group ID from the system range. Numeric, so runAsNonRoot can
# verify it.
RUN groupadd --system --gid 1654 app \
 && useradd --system --uid 1654 --gid 1654 --no-create-home app

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
# Tests, charts, pipelines and docs are kept out by the root .dockerignore (anchored per folder).
# The code stays root-owned: the service writes nothing but /tmp, so it cannot modify itself.
COPY src/module/ .

# Compile at build time: the non-root user cannot write __pycache__ next to root-owned code, and
# without this every cold start compiles everything again.
RUN python -m compileall -q /app /opt/venv

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Memory hygiene. MALLOC_ARENA_MAX bounds glibc's per-thread arenas (the default is 8 x cores, and
# each one keeps its high-water mark); MALLOC_TRIM_THRESHOLD_ returns freed memory sooner;
# GUNICORN_MAX_REQUESTS recycles the worker (see producta_runtime/gunicorn_conf.py). All three can
# be overridden from the chart's ConfigMap.
ENV MALLOC_ARENA_MAX=2 \
    MALLOC_TRIM_THRESHOLD_=131072 \
    GUNICORN_MAX_REQUESTS=300

EXPOSE 8000
USER 1654:1654

CMD ["gunicorn", "-c", "python:producta_runtime.gunicorn_conf", "--bind", "0.0.0.0:8000", "app:app"]
