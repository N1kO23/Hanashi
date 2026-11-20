#!/usr/bin/env bash
# Builds the Linux release and packages it as CI does, into dist/: an
# AppImage, a .deb and a .tar.gz.
#
#   packaging/linux/build-appimage.sh [--rebuild-image]
#
# The build runs in a container of Ubuntu 22.04 (packaging/linux/Dockerfile),
# as in CI: the packages need at least the C library they were built against,
# so built on this machine they would not run on older distributions. The
# image has the versions of Flutter and appimagetool that CI uses, and the
# volume hanashi-linux-build keeps pub's and Cargo's downloads and the last
# build, for faster builds next time (`docker volume rm hanashi-linux-build`
# starts afresh). --rebuild-image builds the image again from scratch, for
# Ubuntu's updates and a newer Rust.
#
# Needs: docker (or DOCKER=podman), git.
set -euo pipefail

here=$(dirname "$(realpath "$0")")
root=$(realpath "$here/../..")
docker=${DOCKER:-docker}
image=hanashi-linux-build
volume=hanashi-linux-build
container=hanashi-linux-build-$$

rebuild=()
[[ "${1:-}" == --rebuild-image ]] && rebuild=(--pull --no-cache)

# Named like CI's builds; commits counted here where CI counts its runs.
version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' "$root/app/pubspec.yaml")
commit=$(git -C "$root" rev-parse --short=7 HEAD)
git -C "$root" diff --quiet HEAD || commit+=-dirty
number=$(git -C "$root" rev-list --count HEAD)
name=hanashi-$version-$commit-linux-x64

ci_env() { # The value of $1 in the env of .github/workflows/ci.yml.
  local value
  value=$(sed -n "s/^  $1: *//p" "$root/.github/workflows/ci.yml")
  [[ -n "$value" ]] || { echo "No $1 in .github/workflows/ci.yml" >&2; return 1; }
  echo "$value"
}
flutter_version=$(ci_env FLUTTER_VERSION)
appimagetool_url=$(ci_env APPIMAGETOOL_URL)
appimagetool_sha256=$(ci_env APPIMAGETOOL_SHA256)

"$docker" build "${rebuild[@]}" -t "$image" \
  --build-arg FLUTTER_VERSION="$flutter_version" \
  --build-arg APPIMAGETOOL_URL="$appimagetool_url" \
  --build-arg APPIMAGETOOL_SHA256="$appimagetool_sha256" \
  "$here"

# The working tree goes in as git sees it (without build output and local
# data), and the packages come out with docker cp, owned by whoever runs this.
trap '"$docker" rm -f "$container" > /dev/null 2>&1 || true' EXIT
git -C "$root" ls-files -z --cached --others --exclude-standard |
  while IFS= read -r -d '' f; do
    # Deleted, though still in the index.
    if [[ -e "$root/$f" || -L "$root/$f" ]]; then printf '%s\0' "$f"; fi
  done |
  tar -C "$root" --null -T - -c -f - |
  "$docker" run -i --init --name "$container" -v "$volume:/work" -e DEB_MAINTAINER -e DEB_HOMEPAGE "$image" \
    container-build.sh "$name" "$version" "$number"
mkdir -p "$root/dist"
"$docker" cp "$container:/out/." "$root/dist/"
