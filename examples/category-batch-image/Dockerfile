FROM alpine:3.22.1

ARG REVISION=unknown
ARG LOGIC_VERSION=0.0.0

LABEL org.opencontainers.image.title="kestra-category-batch-routing-example"
LABEL org.opencontainers.image.description="Two batches from one category image for Kestra worker routing verification."
LABEL org.opencontainers.image.revision="${REVISION}"
LABEL org.opencontainers.image.version="${LOGIC_VERSION}"
LABEL io.kestra.playground.category="orders"

WORKDIR /app

COPY batches/ /app/batches/

RUN chmod 755 /app/batches/*.sh

ENV IMAGE_REVISION="${REVISION}"
ENV LOGIC_REVISION="${REVISION}"
ENV LOGIC_VERSION="${LOGIC_VERSION}"
