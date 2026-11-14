FROM python:3.12-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh batch \
    && mkdir -p /run/sshd /opt/batch-inputs

COPY local/docker/remote-worker/seed_fixtures.py /opt/seed_fixtures.py
COPY local/docker/remote-worker/sshd_config /etc/ssh/sshd_config
COPY local/docker/remote-worker/entrypoint.sh /usr/local/bin/remote-worker-entrypoint

# Local workers install the shared batch library from the working tree; live SSH
# targets install the published wheel from the private GCP Artifact Registry instead.
COPY batch-common /opt/batch-common

RUN python -m pip install --no-cache-dir /opt/batch-common \
    && python /opt/seed_fixtures.py \
    && chmod 755 /usr/local/bin/remote-worker-entrypoint \
    && chmod -R a+rX /opt/batch-inputs

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/remote-worker-entrypoint"]
