#!/usr/bin/env bash
# Packages a Linux release bundle (`flutter build linux --release`) as an
# AppImage, a .deb and a .tar.gz:
#
#   packaging/linux/package.sh BUNDLE OUT_DIR NAME VERSION [UPDATE_INFO]
#
#   BUNDLE       app/build/linux/x64/release/bundle
#   NAME         file name without extension, e.g. hanashi-0.2.0-linux-x64
#   VERSION      package version, e.g. 0.2.0+123
#   UPDATE_INFO  optional AppImage update information, e.g.
#                "gh-releases-zsync|owner|repo|latest|hanashi-*-linux-x64.AppImage.zsync"
#
# All three carry the libraries a desktop may lack (libmpv and what it
# needs, libsecret), found through RUNPATH rather than
# LD_LIBRARY_PATH, so nothing leaks into programs the app starts. The host
# provides the C library, graphics drivers, sound and GTK 3: libraries whose
# names are the same on every distribution and that every desktop has.
# (Others, like libjpeg.so.8 here and libjpeg.so.62 on Debian, are bundled
# even where GTK uses them; so are VDPAU and Vulkan, which find the host's
# drivers themselves.) VA-API, video decoding on the GPU, is the host's too,
# where it has one: see fallback below.
# Run it on the oldest distribution the packages should support: the C
# library it was built against is the minimum.
#
# Needs: patchelf, ldd; for the AppImage APPIMAGETOOL (path to appimagetool)
# and zsyncmake for UPDATE_INFO; for the .deb dpkg-deb and dpkg-shlibdeps.
set -euo pipefail

bundle=$(realpath "$1")
out=$(realpath "$2")
name=$3
version=$4
update_info=${5:-}
here=$(dirname "$(realpath "$0")")
app_id=app.nullpointr.hanashi
binary=hanashi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

# The libraries the host must provide.
host_only='^(ld-linux.*|linux-vdso|libc|libm|libdl|libpthread|librt|libresolv|libutil|libnsl|libanl|libmvec|libcrypt'
host_only+='|libstdc\+\+|libgcc_s|libz|libexpat|libuuid|libblkid|libmount|libselinux|libffi|libpcre.*|libdbus-1'
host_only+='|libsystemd|libudev|libcap|libgcrypt|libgpg-error|liblzma|libzstd|liblz4'
host_only+='|libGL.*|libEGL.*|libOpenGL|libGLdispatch|libgbm|libdrm.*'
# X11 as GTK and Mesa use it; extensions beyond that (screensaver, video)
# are bundled.
host_only+='|libX11|libX11-xcb|libXext|libXrender|libXi|libXfixes|libXrandr|libXcursor|libXinerama|libXcomposite'
host_only+='|libXdamage|libXau|libXdmcp|libxcb|libxcb-render|libxcb-shm|libxkbcommon|libwayland-.*|libxshmfence'
host_only+='|libasound|libpulse.*|libpipewire-.*'
host_only+='|libfontconfig|libfreetype|libharfbuzz.*|libfribidi|libgraphite2|libpng16'
host_only+='|libgtk-3|libgdk-3|libgdk_pixbuf-2\.0|libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0|libgthread-2\.0'
host_only+='|libpango-1\.0|libpangocairo-1\.0|libpangoft2-1\.0|libcairo|libcairo-gobject|libatk-1\.0|libatk-bridge-2\.0'
host_only+='|libatspi|libepoxy'
# Shared with the host's GTK and GIO plugins (icons, TLS) under the same
# names: a bundled older copy, loaded first, would break those plugins.
host_only+='|librsvg-2|libgnutls|libnettle|libhogweed|libgmp|libp11-kit|libtasn1|libidn2)\.so'

# libdartjni is only loaded for Java interop (Android); its libjvm is no
# dependency on the desktop.
not_needed='^libjvm\.so$'

# VA-API loads the host's drivers, and a driver loads only into a libva as new
# as the one it was built for: one bundled from here (1.14) takes none of a
# current distribution's, and video decodes on the CPU. So the host's libva,
# where it has all of it; the bundled one goes apart, in lib/fallback, for a
# host without (see the launcher below), where the app would not start
# otherwise: libmpv needs it.
fallback='^libva(-drm|-x11|-wayland)?\.so'

# The app and the libraries it needs, ready to install under /usr/lib/hanashi.
stage=$work/hanashi
cp -a "$bundle" "$stage"
# The license goes with every copy (AGPL-3.0).
install -m644 "$here/../../LICENSE" "$stage/LICENSE"
lib=$stage/lib
chmod 755 "$lib"/*.so
declare -A bundled=()
for f in "$lib"/*.so; do bundled[$(basename "$f")]=1; done
missing=()
while read -r soname path; do
  soname=${soname##*/} # Newer glibc lists the loader by its path.
  [[ -n "${bundled[$soname]:-}" ]] && continue
  [[ "$soname" =~ $host_only || "$soname" =~ $not_needed ]] && continue
  if [[ "$path" == "not" ]]; then
    missing+=("$soname")
    continue
  fi
  if [[ "$soname" =~ $fallback ]]; then
    mkdir -p "$lib/fallback"
    cp -L "$path" "$lib/fallback/$soname"
  else
    cp -L "$path" "$lib/$soname"
  fi
  bundled[$soname]=1
done < <(for f in "$stage/$binary" "$lib"/*.so; do ldd "$f"; done | awk '$2 == "=>" { print $1, $3 }' | sort -u)
if ((${#missing[@]})); then
  echo "Libraries not found: ${missing[*]}" >&2
  exit 1
fi
# Everything in lib/ finds its neighbours there (plugins otherwise point at
# the build machine's directories).
for f in "$lib"/*.so*; do
  chmod u+w "$f"
  patchelf --set-rpath '$ORIGIN' "$f"
done
echo "Bundled from the system: $(cd "$lib" && ls | grep -v -e '^libapp\.so$' -e '^libflutter_linux_gtk\.so$' \
  -e '_plugin\.so$' -e '^libopenmls_frb\.so$' -e '^libsqlite3mc\.so$' -e '^libdartjni\.so$' -e '^libcnativeapi\.so$' \
  -e '^fallback$' | tr '\n' ' ')"
fallbacks=$([[ -d "$lib/fallback" ]] && cd "$lib/fallback" && ls | tr '\n' ' ' || true)
echo "Only for a host without them: $fallbacks"

# Every library resolves inside the package or from the host.
unresolved=$(for f in "$stage/$binary" "$lib"/*.so*; do
  [[ "$(basename "$f")" == libdartjni.so ]] || env -u LD_LIBRARY_PATH ldd "$f"
done | awk '$3 == "not" { print $1 }' | sort -u)
if [[ -n "$unresolved" ]]; then
  echo "Unresolved after staging: $unresolved" >&2
  exit 1
fi

# media_kit opens libmpv as "libmpv.so" first, the name of the development
# symlink. Without one here, that finds the host's libmpv where it is
# installed (Gentoo, Arch), while the video plugin uses the bundled one: two
# libmpv in one process, and playing a video crashes. (libmpv.so.1 where built
# on Ubuntu 22.04, libmpv.so.2 later.)
for f in "$lib"/libmpv.so.[0-9]*; do
  [[ -e "$f" ]] && ln -s "$(basename "$f")" "$lib/libmpv.so"
done

# The way in, the AppImage's too: VA-API from the host where it has all of it,
# else the one in lib/fallback, through LD_LIBRARY_PATH (only it is there).
cat > "$stage/hanashi" <<EOF
#!/bin/sh
here="\$(dirname "\$(readlink -f "\$0")")"
host="\$(/sbin/ldconfig -p 2>/dev/null)"
for lib in $fallbacks; do
  case "\$host" in
    *"\$lib (libc6,x86-64"*) ;;
    *)
      export LD_LIBRARY_PATH="\$here/lib/fallback\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
      break
      ;;
  esac
done
exec "\$here/$binary" "\$@"
EOF
chmod 755 "$stage/hanashi"

# A folder to unpack anywhere and run hanashi/hanashi from.
tar -C "$work" -czf "$out/$name.tar.gz" hanashi

install_shared() { # $1: root of an installed tree
  install -Dm644 "$here/$app_id.desktop" "$1/usr/share/applications/$app_id.desktop"
  install -Dm644 "$here/$app_id.png" "$1/usr/share/icons/hicolor/256x256/apps/$app_id.png"
}

# AppImage
if [[ -n "${APPIMAGETOOL:-}" ]]; then
  appdir=$work/AppDir
  mkdir -p "$appdir/usr/lib"
  cp -a "$stage" "$appdir/usr/lib/hanashi"
  install_shared "$appdir"
  cp "$here/$app_id.desktop" "$here/$app_id.png" "$appdir/"
  ln -s "$app_id.png" "$appdir/.DirIcon"
  cat > "$appdir/AppRun" <<EOF
#!/bin/sh
# Libraries are found through RUNPATH; the launcher sees to VA-API.
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/usr/lib/hanashi/hanashi" "\$@"
EOF
  chmod +x "$appdir/AppRun"
  args=()
  [[ -n "$update_info" ]] && args=(-u "$update_info")
  # Without FUSE (containers, CI) the tool runs extracted.
  (cd "$out" && ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run "${args[@]}" "$appdir" "$name.AppImage")
fi

# .deb
if command -v dpkg-deb > /dev/null; then
  root=$work/deb
  mkdir -p "$root/usr/lib" "$root/usr/bin" "$root/DEBIAN"
  cp -a "$stage" "$root/usr/lib/hanashi"
  # VA-API comes with the package's dependencies: no fallback to choose.
  rm -r "$root/usr/lib/hanashi/hanashi"
  rm -rf "$root/usr/lib/hanashi/lib/fallback"
  ln -s ../lib/hanashi/$binary "$root/usr/bin/hanashi"
  install_shared "$root"
  install -Dm644 "$here/../../LICENSE" "$root/usr/share/doc/hanashi/copyright"
  # What the host must provide, from the libraries' own records.
  mkdir -p "$work/shlibs/debian"
  printf 'Source: hanashi\n\nPackage: hanashi\nArchitecture: amd64\n' > "$work/shlibs/debian/control"
  elfs=("$root/usr/lib/hanashi/$binary")
  for f in "$root/usr/lib/hanashi/lib"/*.so*; do
    [[ -L "$f" || "$(basename "$f")" == libdartjni.so ]] || elfs+=("$f")
  done
  depends=$(cd "$work/shlibs" && dpkg-shlibdeps -O --ignore-missing-info \
    -l"$root/usr/lib/hanashi/lib" "${elfs[@]}" 2> "$work/shlibdeps.log" | sed -n 's/^shlibs:Depends=//p')
  [[ -n "$depends" ]] || { cat "$work/shlibdeps.log" >&2; exit 1; }
  # Flutter opens OpenGL ES at run time, past dpkg-shlibdeps.
  depends+=", libgles2"
  cat > "$root/DEBIAN/control" <<EOF
Package: hanashi
Version: $version
Architecture: amd64
Maintainer: ${DEB_MAINTAINER:-Hanashi <hanashi@localhost>}
Installed-Size: $(du -sk "$root/usr" | cut -f1)
Depends: $depends
Section: net
Priority: optional
${DEB_HOMEPAGE:+Homepage: $DEB_HOMEPAGE
}Description: End-to-end encrypted chat on your own server
 Hanashi is a self-hosted chat app: direct and group chats, files, and one
 account on many devices, all end-to-end encrypted.
EOF
  dpkg-deb --root-owner-group -Zxz --build "$root" "$out/$name.deb"
fi

ls -l "$out"
