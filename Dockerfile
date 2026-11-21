FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    unzip \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Download and install official Xray-core
ARG XRAY_VERSION=26.11.9
RUN set -eux; \
    curl -fsSL -o /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"; \
    mkdir -p /usr/local/share/xray /usr/local/etc/xray; \
    unzip -q /tmp/xray.zip xray -d /usr/local/bin/; \
    unzip -q /tmp/xray.zip geoip.dat geosite.dat -d /usr/local/share/xray/ || true; \
    rm -f /tmp/xray.zip; \
    chmod +x /usr/local/bin/xray; \
    xray version

# Setup directories for just1knode runtime
RUN mkdir -p /etc/just1knode /var/lib/xray-api /run /var/log/xray /opt/just1knode

WORKDIR /opt/just1knode

# Install python dependencies for xray_api
COPY scripts/xray_api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy node application files
COPY . .

# Ensure entrypoint is executable
RUN chmod +x docker-entrypoint.sh

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/opt/just1knode/scripts/xray_api

EXPOSE 8444

ENTRYPOINT ["./docker-entrypoint.sh"]
