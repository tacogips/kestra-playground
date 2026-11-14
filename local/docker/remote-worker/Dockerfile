FROM python:3.12-slim

RUN apt-get update \
    && apt-get install --yes --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh batch \
    && mkdir -p /run/sshd /opt/batch-inputs

COPY seed_fixtures.py /opt/seed_fixtures.py
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /usr/local/bin/remote-worker-entrypoint

RUN python /opt/seed_fixtures.py \
    && chmod 755 /usr/local/bin/remote-worker-entrypoint \
    && chmod -R a+rX /opt/batch-inputs

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/remote-worker-entrypoint"]
