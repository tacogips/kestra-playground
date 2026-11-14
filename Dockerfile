ARG KESTRA_BASE_IMAGE=kestra/kestra:v1.3.15
FROM ${KESTRA_BASE_IMAGE}

ARG REVISION=unknown
ARG SOURCE_REPOSITORY=https://github.com/tacogips/kestra-playground

LABEL org.opencontainers.image.title="kestra-playground-runtime"
LABEL org.opencontainers.image.description="Kestra runtime image with playground flows, fixtures, and batch source."
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.revision="${REVISION}"

USER root

WORKDIR /app/kestra-playground

COPY kestra/ /app/kestra-playground/kestra/
COPY batches/ /app/kestra-playground/batches/
COPY src/ /app/kestra-playground/src/
COPY pyproject.toml uv.lock README.md /app/kestra-playground/

RUN chmod +x /app/kestra-playground/batches/resource_probe/run.sh

ENV KESTRA_PLAYGROUND_HOME=/app/kestra-playground
