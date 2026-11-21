FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates build-essential clang cmake ninja-build \
    git pkg-config libssl-dev nlohmann-json3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
CMD ["bash"]
