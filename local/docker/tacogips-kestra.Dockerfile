ARG BASE_IMAGE="ghcr.io/kestra-io/kestra-base:latest-no-plugins"
FROM ${BASE_IMAGE}

ENV PATH="/app/.venv/bin:$PATH"

COPY --chown=kestra:kestra docker /
RUN chown -R kestra:kestra /app

USER kestra
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--help"]
