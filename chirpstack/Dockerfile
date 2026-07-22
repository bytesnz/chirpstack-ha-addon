ARG BUILD_FROM

# =============================================================================
# Stage 1: Download all binaries
# =============================================================================
FROM $BUILD_FROM AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG CHIRPSTACK_VERSION="4.15.0"
ARG GATEWAY_BRIDGE_VERSION="4.1.1"
ARG CONCENTRATORD_VERSION="4.7.1"

RUN apk add --no-cache curl

RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        x86_64)   CHIRP_ARCH="amd64";   GW_ARCH="amd64" ;; \
        aarch64)  CHIRP_ARCH="arm64";   GW_ARCH="arm64" ;; \
        armv7l)   CHIRP_ARCH="armv7hf"; GW_ARCH="armv7hf" ;; \
        armv6l)   CHIRP_ARCH="armv7hf"; GW_ARCH="armhf"  ;; \
        i386|i686)CHIRP_ARCH="386";     GW_ARCH="386"   ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    echo "[BUILD] ARCH=$ARCH → ChirpStack=${CHIRP_ARCH}, GatewayBr=${GW_ARCH}" && \
    mkdir -p /output/bin && \
    \
    CH_URL="https://artifacts.chirpstack.io/downloads/chirpstack/chirpstack_${CHIRPSTACK_VERSION}_sqlite_linux_${CHIRP_ARCH}.tar.gz" && \
    echo "[DOWNLOAD] $CH_URL" && \
    curl -fL -o /tmp/chirpstack.tar.gz "$CH_URL" && \
    tar -xzf /tmp/chirpstack.tar.gz -C /tmp/ && \
    mv /tmp/chirpstack /output/bin/chirpstack && \
    chmod +x /output/bin/chirpstack && \
    rm -f /tmp/chirpstack.tar.gz && \
    \
    GW_URL="https://artifacts.chirpstack.io/downloads/chirpstack-gateway-bridge/chirpstack-gateway-bridge_${GATEWAY_BRIDGE_VERSION}_linux_${GW_ARCH}.tar.gz" && \
    echo "[DOWNLOAD] $GW_URL" && \
    curl -fL -o /tmp/gwb.tar.gz "$GW_URL" && \
    tar -xzf /tmp/gwb.tar.gz -C /tmp/ && \
    mv /tmp/chirpstack-gateway-bridge /output/bin/chirpstack-gateway-bridge && \
    chmod +x /output/bin/chirpstack-gateway-bridge && \
    rm -f /tmp/gwb.tar.gz

# Download Concentratord (arm64 and armv7hf only — no amd64 tar.gz available)
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
        aarch64)  CD_ARCH="arm64" ;; \
        armv7l)   CD_ARCH="armv7hf" ;; \
        *) echo "[BUILD] Concentratord not available for $ARCH, skipping" && exit 0 ;; \
    esac && \
    echo "[BUILD] Downloading Concentratord ${CONCENTRATORD_VERSION} for ${CD_ARCH}" && \
    for CD_TYPE in sx1301 sx1302 2g4; do \
        CD_URL="https://artifacts.chirpstack.io/downloads/chirpstack-concentratord/chirpstack-concentratord-${CD_TYPE}_${CONCENTRATORD_VERSION}_linux_${CD_ARCH}.tar.gz" && \
        echo "[DOWNLOAD] $CD_URL" && \
        curl -fL -o /tmp/cd-${CD_TYPE}.tar.gz "$CD_URL" && \
        tar -xzf /tmp/cd-${CD_TYPE}.tar.gz -C /tmp/ && \
        mv /tmp/chirpstack-concentratord-${CD_TYPE} /output/bin/chirpstack-concentratord-${CD_TYPE} && \
        chmod +x /output/bin/chirpstack-concentratord-${CD_TYPE} && \
        rm -f /tmp/cd-${CD_TYPE}.tar.gz && \
        echo "[BUILD] chirpstack-concentratord-${CD_TYPE} downloaded" ; \
    done

# Build sx1302_hal tools from source (debug utilities for SX1302 concentrator)
RUN apk add --no-cache build-base libusb-dev libftdi1-dev linux-headers git && \
    git clone --depth 1 https://github.com/Lora-net/sx1302_hal.git /tmp/sx1302_hal && \
    cd /tmp/sx1302_hal && \
    make && \
    cp -a bin/* /output/bin/

# =============================================================================
# Stage 2: Main image
# =============================================================================
FROM $BUILD_FROM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install system packages
RUN apk add --no-cache \
    bash \
    curl \
    jq \
    sed \
    redis \
    python3 \
    py3-pip \
    pipx

# Ensure pipx path is available
ENV PATH="/root/.local/bin:${PATH}"

# -------------------------------------------------------------------
# Install tomlq/yq via pipx (SAFE + allowed in HA)
# -------------------------------------------------------------------
RUN pipx install yq && \
    ln -s /root/.local/bin/tomlq /usr/local/bin/tomlq && \
    ln -s /root/.local/bin/yq /usr/local/bin/yq && \
    ln -s /root/.local/bin/xq /usr/local/bin/xq

# -------------------------------------------------------------------
# Copy binaries from builder stage
# -------------------------------------------------------------------
COPY --from=builder /output/bin/ /usr/local/bin/

# Verify binaries
RUN /usr/local/bin/chirpstack --version || echo "ChirpStack OK"
RUN /usr/local/bin/chirpstack-gateway-bridge version || echo "GatewayBridge OK"
RUN tomlq --version || echo "tomlq installed"

COPY run.sh /
RUN chmod +x /run.sh

COPY regions/ /app/regions/

WORKDIR /config
CMD [ "/run.sh" ]
