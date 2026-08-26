FROM alpine:3.22.1

ARG REVISION=unknown

LABEL org.opencontainers.image.title="kestra-category-batch-routing-example"
LABEL org.opencontainers.image.description="Two batches from one category image for Kestra worker routing verification."
LABEL org.opencontainers.image.revision="${REVISION}"

WORKDIR /app

COPY batches/ /app/batches/

RUN chmod 755 /app/batches/*.sh

ENV IMAGE_REVISION="${REVISION}"
