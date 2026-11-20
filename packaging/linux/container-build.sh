#!/usr/bin/env bash
# Builds the Linux release in the image of packaging/linux/Dockerfile and
# packages it into /out, as CI's Linux job does. build-appimage.sh runs it:
#
#   container-build.sh NAME VERSION NUMBER < SOURCE.tar
#
#   SOURCE.tar  the repository's files, without what git ignores
#
# /work, a volume, keeps pub's and Cargo's downloads and the last build
# between runs.
set -euo pipefail

name=$1
version=$2
number=$3
src=/work/src
export PUB_CACHE=/work/pub-cache
export CARGO_HOME=/work/cargo

# The source replaces the last run's, past its build output.
mkdir -p /tmp/source "$src"
tar -x -f - -C /tmp/source
rsync -a --delete --exclude=.dart_tool/ --exclude=/app/build/ --exclude=/app/linux/flutter/ephemeral/ \
  /tmp/source/ "$src/"

cd "$src"
flutter pub get

# openmls's published binary needs glibc 2.38; built here, it runs wherever
# the rest of the app does. Its build hook prefers a library in its
# rust/target/release/, beside the crate version and lock file it was built
# from. (As CI's "Build openmls for this C library".)
openmls=$(jq -r '.packages[] | select(.name == "openmls") | .rootUri | sub("^file://"; "")' .dart_tool/package_config.json)
export CARGO_TARGET_DIR=/work/openmls-target
cargo build --release --locked --manifest-path "$openmls/rust/Cargo.toml"
mkdir -p "$openmls/rust/target/release"
cp "$CARGO_TARGET_DIR/release/libopenmls_frb.so" "$openmls/rust/target/release/"
sed -n 's/^version = "\([^"]*\)".*/\1/p;T;q' "$openmls/rust/Cargo.toml" > "$openmls/rust/target/release/.crate-version"
cp "$openmls/rust/Cargo.lock" "$openmls/rust/target/release/.cargo-lock"

(cd app && flutter build linux --release --build-name="$version" --build-number="$number")
APPIMAGETOOL=$HOME/appimagetool packaging/linux/package.sh app/build/linux/x64/release/bundle /out "$name" "$version+$number"
