#!/usr/bin/env bash
# Builds the Android release APKs on this machine as CI does, one per CPU
# type, into dist/. They are signed with the release key, so they install over
# CI's builds and the other way round, keeping the app's data.
#
#   packaging/android/build-apks.sh
#
# Needs the release key in app/android/key.properties (see the README), or in
# the ANDROID_KEYSTORE_* variables as in CI.
set -euo pipefail

here=$(dirname "$(realpath "$0")")
root=$(realpath "$here/../..")

# Without the key, Gradle would sign with the debug key: such an APK cannot
# update an installed Hanashi.
if [[ ! -f "$root/app/android/key.properties" && -z "${ANDROID_KEYSTORE_PATH:-}" ]]; then
  echo "No release key: create app/android/key.properties (see \"Builds and releases\" in the README)." >&2
  exit 1
fi

# Named like CI's builds.
version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$root/app/pubspec.yaml")
commit=$(git -C "$root" rev-parse --short=7 HEAD)
git -C "$root" diff --quiet HEAD || commit+=-dirty

(cd "$root/app" && flutter build apk --release --split-per-abi --build-name="$version")
mkdir -p "$root/dist"
for abi in arm64-v8a armeabi-v7a x86_64; do
  cp "$root/app/build/app/outputs/flutter-apk/app-$abi-release.apk" "$root/dist/hanashi-$version-$commit-android-$abi.apk"
done
ls -l "$root/dist"/hanashi-"$version-$commit"-android-*.apk
