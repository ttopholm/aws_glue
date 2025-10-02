# syntax=docker/dockerfile:1.4
# ============================================
# Multi-Architecture AWS Glue 4 with VS Code Server Support
# Supports: linux/amd64, linux/arm64
# ============================================

# Build Arguments
ARG PATCHELF_VERSION=0.18.0
ARG CT_NG_VERSION=1.27.0
ARG ALPINE_VERSION=3.22
ARG UBUNTU_VERSION=latest
ARG GLUE_VERSION=4.0.0
ARG GLUE_IMAGE_TAG=glue_libs_4.0.0_image_01
ARG UV_VERSION=latest

# Architecture-specific arguments
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETOS

# Crosstool-NG config base URL
ARG CT_CONFIG_BASE_URL="https://raw.githubusercontent.com/microsoft/vscode-linux-build-agent/main"

# GCC and glibc versions (can be overridden)
ARG GCC_VERSION=10.5.0
ARG GLIBC_VERSION=2.28

# Metadata
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=1.0.0

# ============================================
# Stage 1: Build static patchelf (musl/Alpine)
# ============================================
# Build on target platform (will be set by buildx)
FROM alpine:${ALPINE_VERSION} AS patchelf-builder
ARG PATCHELF_VERSION
ARG TARGETARCH

RUN apk add --no-cache \
    build-base \
    autoconf \
    automake \
    libtool \
    bash \
    wget \
    tar

WORKDIR /src

RUN wget -O /tmp/patchelf.tar.gz "https://github.com/NixOS/patchelf/archive/refs/tags/${PATCHELF_VERSION}.tar.gz" \
 && tar -xzf /tmp/patchelf.tar.gz -C /src --strip-components=1 \
 && ./bootstrap.sh \
 && CXXFLAGS="-O2" LDFLAGS="-static -static-libstdc++ -static-libgcc" ./configure \
 && make -j"$(nproc)" \
 && strip src/patchelf \
 && ./src/patchelf --version

# ======================================================
# Stage 2: Build cross-platform sysroot using crosstool-NG
# ======================================================
# Build on target platform (will be set by buildx)
FROM ubuntu:${UBUNTU_VERSION} AS sysroot-builder
ARG DEBIAN_FRONTEND=noninteractive
ARG CT_NG_VERSION
ARG TARGETARCH
ARG GCC_VERSION
ARG GLIBC_VERSION
ARG CT_CONFIG_BASE_URL

# Install crosstool-NG dependencies
RUN apt-get update && apt-get install -y \
    gcc g++ gperf bison flex texinfo help2man make libncurses5-dev \
    python3-dev autoconf automake libtool libtool-bin gawk wget bzip2 xz-utils unzip \
    patch rsync meson ninja-build \
 && rm -rf /var/lib/apt/lists/*
 
# Install crosstool-NG
WORKDIR /tmp
RUN wget "http://crosstool-ng.org/download/crosstool-ng/crosstool-ng-${CT_NG_VERSION}.tar.bz2" \
 && tar -xjf "crosstool-ng-${CT_NG_VERSION}.tar.bz2" \
 && cd "crosstool-ng-${CT_NG_VERSION}" \
 && ./configure --prefix=/opt/ctng \
 && make -j"$(nproc)" \
 && make install

ENV PATH="/opt/ctng/bin:${PATH}"

# Create build directory with proper permissions
RUN useradd -m -s /bin/bash builder \
 && mkdir /build \
 && chown builder:builder /build

USER builder
WORKDIR /build

# Set architecture-specific variables and download config
# If TARGETARCH is not set, detect from system
RUN ARCH="${TARGETARCH}" && \
    if [ -z "$ARCH" ]; then \
        echo "TARGETARCH not set, detecting from system..." && \
        MACHINE=$(uname -m) && \
        case $MACHINE in \
            x86_64) ARCH="amd64" ;; \
            aarch64) ARCH="arm64" ;; \
            *) echo "Unknown machine type: $MACHINE" && exit 1 ;; \
        esac && \
        echo "Detected architecture: $ARCH" ; \
    fi && \
    echo "Using architecture: $ARCH" && \
    if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then \
        CT_TUPLE="aarch64-linux-gnu"; \
        CT_ARCH="aarch64"; \
    elif [ "$ARCH" = "amd64" ] || [ "$ARCH" = "x86_64" ]; then \
        CT_TUPLE="x86_64-linux-gnu"; \
        CT_ARCH="x86_64"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    echo "Building for: ${CT_ARCH} (${CT_TUPLE})" && \
    echo "CT_TUPLE=${CT_TUPLE}" > /build/.ct_vars && \
    echo "CT_ARCH=${CT_ARCH}" >> /build/.ct_vars && \
    CONFIG_URL="${CT_CONFIG_BASE_URL}/${CT_ARCH}-gcc-${GCC_VERSION}-glibc-${GLIBC_VERSION}.config" && \
    echo "Downloading config: $CONFIG_URL" && \
    wget -O .config "$CONFIG_URL"

# Build toolchain + sysroot (use all available cores)
RUN unset CT_LOG_PROGRESS_BAR && ct-ng build.$(nproc)

USER root

# Extract the sysroot using the saved tuple
RUN . /build/.ct_vars && \
    export CT_OUT="/build/${CT_TUPLE}/${CT_TUPLE}" && \
    mkdir -p /sysroot-out && \
    rsync -a "${CT_OUT}/sysroot/" /sysroot-out/

# ======================================================
# Stage 3: Get UV binary
# ======================================================
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-source

# ======================================================
# Stage 4: Final image — AWS Glue 4 (Amazon Linux 2)
# ======================================================
# Build on target platform (will be set by buildx)
FROM docker.io/amazon/aws-glue-libs:${GLUE_IMAGE_TAG} AS final

# Re-declare ARGs needed in this stage
ARG TARGETARCH
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
ARG GLUE_VERSION
ARG GLIBC_VERSION
ARG GCC_VERSION
ARG PATCHELF_VERSION
ARG UV_VERSION

USER root

# Install runtime dependencies
RUN yum -y update && \
    yum -y install \
        krb5-devel \
        git \
        which \
        sudo \
 && yum clean all \
 && rm -rf /var/cache/yum

# Copy UV from official image
COPY --from=uv-source /uv /usr/local/bin/uv

# Configure UV environment
ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_PYTHON=python3.10

# Copy static patchelf
COPY --from=patchelf-builder /src/src/patchelf /usr/local/bin/patchelf

# Copy architecture-specific sysroot
COPY --from=sysroot-builder /sysroot-out /opt/sysroot/glibc-${GLIBC_VERSION}

# Set ownership
RUN chown -R root:root /opt/sysroot

# -----------------------
# VS Code Server Configuration
# -----------------------
# Base sysroot path
ENV SYSROOT=/opt/sysroot/glibc-${GLIBC_VERSION}

# VS Code Server environment variables (architecture-agnostic)
# The actual linker binary (e.g., ld-2.28.so) works for both architectures
ENV VSCODE_SERVER_PATCHELF_PATH="/usr/local/bin/patchelf" \
    VSCODE_SERVER_CUSTOM_GLIBC_LINKER="${SYSROOT}/lib/ld-${GLIBC_VERSION}.so" \
    VSCODE_SERVER_CUSTOM_GLIBC_PATH="${SYSROOT}/lib:${SYSROOT}/usr/lib:${SYSROOT}/lib64:${SYSROOT}/usr/lib64"

# Validate critical paths exist
RUN test -x "${VSCODE_SERVER_PATCHELF_PATH}" || (echo "patchelf not found" && exit 1) \
 && (test -f "${VSCODE_SERVER_CUSTOM_GLIBC_LINKER}" || \
     test -f "${SYSROOT}/lib/ld-${GLIBC_VERSION}.so" || \
     test -f "${SYSROOT}/lib64/ld-${GLIBC_VERSION}.so" || \
     echo "Warning: Linker ld-${GLIBC_VERSION}.so not found, will be set at runtime") \
 && (test -d "${SYSROOT}/lib" || test -d "${SYSROOT}/lib64" || (echo "Sysroot lib directory not found" && exit 1))

# Create VS Code Server directory with proper permissions
RUN mkdir -p /home/glue_user/.vscode-server \
 && chown -R glue_user /home/glue_user/.vscode-server

RUN echo "glue_user ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/glue_user \
    && chmod 0440 /etc/sudoers.d/glue_user

RUN mkdir /vscode \
 && chown glue_user /vscode

RUN chmod 777 /tmp/spark-events

# Disable any slf4j-reload4j jars (Log4j1 binding) - force the log4j2 binding
RUN for JAR in /home/glue_user/spark/jars/slf4j-reload4j-*.jar /home/glue_user/aws-glue-libs/jars/slf4j-reload4j-*.jar; do \
        if [ -f "$JAR" ]; then \
            mv "$JAR" "$JAR.disabled"; \
            echo "Disabled $JAR"; \
        fi; \
    done

COPY fix-vscode-permissions.sh /
RUN chmod +x /fix-vscode-permissions.sh

# Switch back to non-root user
USER glue_user

ENTRYPOINT [ "/fix-vscode-permissions.sh" ]
CMD [ "sleep", "infinity" ]
