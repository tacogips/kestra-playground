FROM kestra/kestra:latest

ARG REVISION=unknown
ARG SOURCE_REPOSITORY=https://github.com/tacogips/kestra-playground

LABEL org.opencontainers.image.title="kestra-playground-runtime"
LABEL org.opencontainers.image.description="Kestra runtime image with playground flows, fixtures, and batch source."
LABEL org.opencontainers.image.source="${SOURCE_REPOSITORY}"
LABEL org.opencontainers.image.revision="${REVISION}"

USER root

WORKDIR /opt/kestra-playground

COPY kestra/ /opt/kestra-playground/kestra/
COPY src/ /opt/kestra-playground/src/
COPY pyproject.toml uv.lock README.md /opt/kestra-playground/

ENV KESTRA_PLAYGROUND_HOME=/opt/kestra-playground
