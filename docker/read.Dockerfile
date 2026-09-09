# syntax=docker/dockerfile:1.7
#
# Mooncake code-reading image.
#
# This image ships only a toolchain: the C/C++/Go build dependencies Mooncake
# needs plus code-navigation tools (clangd, gdb, ripgrep, fd, fzf, ccache). The
# source tree is bind-mounted at runtime by env.sh at the same absolute path it
# has on the host, so the compile_commands.json paths line up for clangd. The
# container runs as a non-root user whose UID/GID match the host to keep files
# writable on both sides.
FROM ubuntu:22.04

ARG DEV_USER=developer
ARG DEV_UID=1000
ARG DEV_GID=1000
# Keep in sync with .devcontainer/Dockerfile / dependencies.sh (known-good tag).
ARG GO_VERSION=1.23.8

# Docker treats these as predefined build arguments and excludes their values
# from the image history.
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG ALL_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG all_proxy
ARG no_proxy

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/${DEV_USER} \
    USER=${DEV_USER} \
    LOGNAME=${DEV_USER} \
    PATH=/usr/local/go/bin:${PATH} \
    GOPATH=/home/${DEV_USER}/go \
    CCACHE_DIR=/home/${DEV_USER}/.cache/ccache \
    CCACHE_MAXSIZE=20G \
    CMAKE_C_COMPILER_LAUNCHER=ccache \
    CMAKE_CXX_COMPILER_LAUNCHER=ccache

# 1) Mooncake build dependencies (kept aligned with dependencies.sh) and
# 2) interactive code-navigation tooling.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        make \
        ninja-build \
        pkg-config \
        patchelf \
        unzip \
        wget \
        libasio-dev \
        libboost-all-dev \
        libc-bin \
        libc6-dev \
        libcurl4-openssl-dev \
        libgflags-dev \
        libgoogle-glog-dev \
        libgrpc-dev \
        libgrpc++-dev \
        libhiredis-dev \
        libibverbs-dev \
        libjemalloc-dev \
        libjsoncpp-dev \
        libmsgpack-dev \
        libnuma-dev \
        libprotobuf-dev \
        libpython3-dev \
        libssl-dev \
        libunwind-dev \
        liburing-dev \
        libxxhash-dev \
        libyaml-cpp-dev \
        libzmq3-dev \
        libzstd-dev \
        protobuf-compiler-grpc \
        python3-dev \
        python3-pip \
        python3-venv \
        bash-completion \
        bat \
        ccache \
        clang \
        clang-format \
        clangd \
        fd-find \
        fzf \
        gdb \
        jq \
        less \
        lsof \
        ripgrep \
        sudo \
        tmux \
        tree \
        vim \
        zoxide \
    && rm -rf /var/lib/apt/lists/*

# Install Go with mirror fallback. Go is only required for the optional etcd /
# Store Go bindings, which the CPU reading build leaves off, but it is bundled
# so full builds work without touching the image.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
        aarch64) goarch=arm64 ;; \
        x86_64)  goarch=amd64 ;; \
        *) echo "Unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tarball="go${GO_VERSION}.linux-${goarch}.tar.gz"; \
    for url in \
        "https://go.dev/dl/${tarball}" \
        "https://golang.google.cn/dl/${tarball}" \
        "https://mirrors.aliyun.com/golang/${tarball}"; do \
        if curl -fsSL --connect-timeout 30 -o "/tmp/${tarball}" "${url}"; then \
            break; \
        fi; \
    done; \
    test -f "/tmp/${tarball}"; \
    tar -C /usr/local -xzf "/tmp/${tarball}"; \
    rm -f "/tmp/${tarball}"; \
    /usr/local/go/bin/go version

# Create a non-root user whose UID/GID match the host so bind-mounted files stay
# writable on both sides. Reuse an existing group/user for the requested IDs.
RUN set -eux; \
    group_name="$(getent group "${DEV_GID}" | cut -d: -f1 || true)"; \
    if [ -z "${group_name}" ]; then \
        group_name="${DEV_USER}"; \
        groupadd --gid "${DEV_GID}" "${group_name}"; \
    fi; \
    if getent passwd "${DEV_UID}" >/dev/null; then \
        existing_user="$(getent passwd "${DEV_UID}" | cut -d: -f1)"; \
        usermod --login "${DEV_USER}" --home "/home/${DEV_USER}" --move-home \
            "${existing_user}"; \
        usermod --gid "${group_name}" "${DEV_USER}"; \
    else \
        useradd --create-home --shell /bin/bash --uid "${DEV_UID}" \
            --gid "${group_name}" "${DEV_USER}"; \
    fi; \
    install -d -o "${DEV_UID}" -g "${DEV_GID}" \
        "/home/${DEV_USER}" \
        "/home/${DEV_USER}/.cache/ccache" \
        "/home/${DEV_USER}/go"; \
    echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEV_USER}"; \
    chmod 0440 "/etc/sudoers.d/${DEV_USER}"

COPY --chown=${DEV_UID}:${DEV_GID} docker/read.bashrc.template \
    /home/${DEV_USER}/.bashrc

USER ${DEV_USER}
WORKDIR /workspace

CMD ["sleep", "infinity"]
