FROM swift:6.2-jammy AS builder
WORKDIR /workspace
ENV http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY="" ALL_PROXY="" all_proxy=""
COPY Package.swift Package.resolved ./
COPY Packages ./Packages
COPY Vendor/AnyLanguageModel ./Vendor/AnyLanguageModel
COPY Vendor/EventSource ./Vendor/EventSource
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --product SloppyRelay
RUN mkdir -p /artifacts && \
    cp "$(find .build -type f -path '*/release/SloppyRelay' | head -n 1)" /artifacts/SloppyRelay && \
    cp -R "$(find .build -type d -path '*/release/Sloppy_ManagedRelayCore.bundle' | head -n 1)" /artifacts/Sloppy_ManagedRelayCore.bundle

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libicu70 libssl3 libstdc++6 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/lib/swift /usr/lib/swift
COPY --from=builder /artifacts/SloppyRelay /usr/bin/SloppyRelay
COPY --from=builder /artifacts/Sloppy_ManagedRelayCore.bundle /usr/bin/Sloppy_ManagedRelayCore.bundle
USER 65532:65532
EXPOSE 25111
ENTRYPOINT ["/usr/bin/SloppyRelay"]
