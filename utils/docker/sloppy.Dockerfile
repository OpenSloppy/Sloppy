# Multi-stage image for the `sloppy` Core binary (Linux).
# Build: from repo root — podman build -f utils/docker/sloppy.Dockerfile .
# Plain RUN steps (no BuildKit cache mounts) so Podman works without BuildKit.

FROM swift:6.2-jammy AS builder
RUN apt-get update && apt-get install -y libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
# Podman/Docker may inject HTTP(S)_PROXY to host.containers.internal; SwiftPM/git then cannot reach GitHub.
ENV http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" all_proxy=""
ARG SWIFT_BUILD_CONFIGURATION=release
COPY Package.swift Package.resolved ./
COPY Packages ./Packages
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
COPY docs ./docs
RUN set -eux; \
    swift build -c "${SWIFT_BUILD_CONFIGURATION}" --product sloppy; \
    mkdir -p /artifacts; \
    mkdir -p /artifacts/Sloppy_sloppy.resources; \
    mkdir -p /artifacts/Sloppy_sloppy.bundle; \
    mkdir -p /artifacts/Sloppy_SloppyRuntime.resources; \
    mkdir -p /artifacts/Sloppy_SloppyRuntime.bundle; \
    SLOPPY_BIN="$(find .build -type f -path "*/${SWIFT_BUILD_CONFIGURATION}/sloppy" | head -n 1)"; \
    strip "$SLOPPY_BIN" || true; \
    cp "$SLOPPY_BIN" /artifacts/sloppy; \
    RESOURCE_DIR="$(find .build -type d \( -name 'Sloppy_sloppy.resources' -o -name 'Sloppy_sloppy.bundle' \) | head -n 1 || true)"; \
    if [ -n "${RESOURCE_DIR}" ]; then \
    cp -R "$RESOURCE_DIR"/. "/artifacts/$(basename "$RESOURCE_DIR")"; \
    fi; \
    RUNTIME_RESOURCE_DIR="$(find .build -type d \( -name 'Sloppy_SloppyRuntime.resources' -o -name 'Sloppy_SloppyRuntime.bundle' \) | head -n 1 || true)"; \
    if [ -n "${RUNTIME_RESOURCE_DIR}" ]; then \
    cp -R "$RUNTIME_RESOURCE_DIR"/. "/artifacts/$(basename "$RUNTIME_RESOURCE_DIR")"; \
    fi

FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV SLOPPY_DEPLOYMENT_KIND=docker
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    tzdata \
    libsqlite3-dev \
    libcurl4 \
    libxml2 \
    libicu70 \
    libbsd0 \
    libedit2 \
    libncursesw6 \
    zlib1g \
    libgcc-s1 \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /root
RUN mkdir -p /root/.sloppy /etc/sloppy /var/lib/sloppy
COPY --from=builder /usr/lib/swift /usr/lib/swift
COPY --from=builder /artifacts/sloppy /usr/bin/sloppy
COPY --from=builder /artifacts/Sloppy_sloppy.resources /usr/bin/Sloppy_sloppy.resources
COPY --from=builder /artifacts/Sloppy_sloppy.bundle /usr/bin/Sloppy_sloppy.bundle
COPY --from=builder /artifacts/Sloppy_SloppyRuntime.resources /usr/bin/Sloppy_SloppyRuntime.resources
COPY --from=builder /artifacts/Sloppy_SloppyRuntime.bundle /usr/bin/Sloppy_SloppyRuntime.bundle
COPY --from=builder /workspace/docs /root/docs
EXPOSE 25101
CMD ["/usr/bin/sloppy", "run"]
