# The machine build-appimage.sh builds Linux releases on: Ubuntu 22.04, as
# CI's Linux job, so that the packages run on distributions that old. The
# script passes in the Flutter and appimagetool of .github/workflows/ci.yml.
FROM ubuntu:22.04

# CI's build dependencies (keep in step with its Linux job), and what its
# runner has besides: git, curl and the archivers for Flutter, a C toolchain
# and Perl for openmls (with the OpenSSL it builds), dpkg-dev for the .deb,
# and jq and rsync for container-build.sh.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev \
    libsecret-1-dev libmpv-dev libepoxy-dev libx11-dev libxi-dev libpipewire-0.3-dev patchelf zsync \
    build-essential ca-certificates curl dpkg-dev file git jq perl rsync unzip xz-utils zip \
  && rm -rf /var/lib/apt/lists/*

# /work is the volume of pub's and Cargo's downloads and the last build; /out
# gets the packages.
RUN useradd --create-home builder && mkdir /work /out && chown builder: /work /out
USER builder
WORKDIR /home/builder
ENV RUSTUP_HOME=/home/builder/rustup CARGO_HOME=/home/builder/cargo
ENV PATH=/home/builder/cargo/bin:/home/builder/flutter/bin:$PATH

# Stable Rust as of the image's build, for openmls.
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable

ARG FLUTTER_VERSION
RUN curl -sSfL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz" \
    | tar -xJ \
  && flutter --disable-analytics \
  && flutter precache --linux

ARG APPIMAGETOOL_URL
ARG APPIMAGETOOL_SHA256
RUN curl -sSfL -o appimagetool "$APPIMAGETOOL_URL" \
  && echo "$APPIMAGETOOL_SHA256  appimagetool" | sha256sum --check --quiet \
  && chmod +x appimagetool

COPY container-build.sh /usr/local/bin/
