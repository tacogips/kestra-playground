FROM kestra/kestra:v1.3.39
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
ARG PLUGIN_VERSION=0.1.0-SNAPSHOT
COPY build/libs/plugin-python-task-${PLUGIN_VERSION}.jar /app/plugins/plugin-python-task.jar
COPY examples/ /opt/python-task-examples/
