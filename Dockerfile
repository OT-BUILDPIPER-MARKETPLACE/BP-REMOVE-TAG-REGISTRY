FROM alpine:3.19


RUN apk update && apk add --no-cache \
    bash \
    jq \
    docker-cli \
    coreutils \
    python3 \
    py3-pip \
    python3-dev \
    build-base \
    libffi-dev \
    openssl-dev \
    curl \
    unzip


RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip


RUN addgroup -g 65522 buildpiper && \
    adduser -D -u 65522 -G buildpiper -h /home/buildpiper buildpiper && \
    chown -R buildpiper:buildpiper /home/buildpiper


RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel && \
    /opt/venv/bin/pip install --no-cache-dir \
        tabulate \
        cryptography


ENV PATH="/opt/venv/bin:$PATH"


ENV DOCKER_CONFIG=/tmp/.docker
RUN mkdir -p /tmp/.docker && chmod 700 /tmp/.docker


RUN mkdir -p \
    /src/reports \
    /bp/data \
    /bp/execution_dir \
    /opt/buildpiper/shell-functions \
    /opt/buildpiper/data \
    /bp/workspace && \
    chown -R buildpiper:buildpiper /src /bp /opt /home/buildpiper /tmp/.docker

COPY --chown=buildpiper:buildpiper build.sh /home/buildpiper/build.sh
COPY --chown=buildpiper:buildpiper BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/

RUN chmod +x /home/buildpiper/build.sh

USER buildpiper
WORKDIR /home/buildpiper

ENV SLEEP_DURATION=5s \
    MAX_ALLOWED_IMAGE_SIZE=180 \
    VALIDATION_FAILURE_ACTION=FAILURE \
    ACTIVITY_SUB_TASK_CODE=IMAGE_SIZE_VALIDATOR

ENTRYPOINT ["./build.sh"]
