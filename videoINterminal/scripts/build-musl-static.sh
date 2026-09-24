#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build-musl-static}"
WITH_VIDEO="${WITH_VIDEO:-1}"
WITH_VIDEO_DEVICE="${WITH_VIDEO_DEVICE:-1}"
FFMPEG_STATIC_PREFIX="${FFMPEG_STATIC_PREFIX:-/opt/ffmpeg-static}"
TURBOJPEG_MODE="${TURBOJPEG_MODE:-auto}"
TURBOJPEG_STATIC_PREFIX="${TURBOJPEG_STATIC_PREFIX:-/opt/turbojpeg-static}"
WITH_PDF="${WITH_PDF:-1}"
PDF_STATIC_PREFIX="${PDF_STATIC_PREFIX:-/opt/pdf-static}"
USE_DOCKER="${USE_DOCKER:-0}"

# GraphicsMagick, librsvg, OpenSlide and libsixel are kept off because they
# have no convenient fully-static builds. Video (FFmpeg) and PDF (poppler/
# cairo) are built from source below; both default on, disable with
# WITH_VIDEO=0 / WITH_PDF=0.
CMAKE_OPTS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/musl-static-minimal.cmake
  -DWITH_OPENSLIDE_SUPPORT=Off
  -DWITH_GRAPHICSMAGICK=Off
  -DWITH_RSVG=Off
  -DWITH_LIBSIXEL=Off
  -DWITH_STB_IMAGE=On
)

if [ "${WITH_PDF}" = "1" ]; then
  CMAKE_OPTS+=(-DWITH_POPPLER=On)
else
  CMAKE_OPTS+=(-DWITH_POPPLER=Off)
fi

if [ "${WITH_VIDEO}" = "1" ]; then
  CMAKE_OPTS+=(-DWITH_VIDEO_DECODING=On)
  CMAKE_OPTS+=(-DCMAKE_PREFIX_PATH="${FFMPEG_STATIC_PREFIX}")
  if [ "${WITH_VIDEO_DEVICE}" = "1" ]; then
    CMAKE_OPTS+=(-DWITH_VIDEO_DEVICE=On)
  else
    CMAKE_OPTS+=(-DWITH_VIDEO_DEVICE=Off)
  fi
else
  CMAKE_OPTS+=(-DWITH_VIDEO_DECODING=Off -DWITH_VIDEO_DEVICE=Off)
fi

# Optional: set DOCKER_PLATFORM to cross-build (e.g. linux/arm64).
# Cross-builds can only run in Docker (the local toolchain is x86_64-only),
# so setting DOCKER_PLATFORM forces USE_DOCKER=1.
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
DOCKER_PLATFORM_ARGS=()
if [ -n "${DOCKER_PLATFORM}" ]; then
  DOCKER_PLATFORM_ARGS=(--platform "${DOCKER_PLATFORM}")
  USE_DOCKER=1
fi

if [ "${USE_DOCKER}" != "1" ]; then
  if ! command -v x86_64-linux-musl-g++ >/dev/null 2>&1; then
    echo "USE_DOCKER is not set but x86_64-linux-musl-g++ is not on PATH." >&2
    echo "Install a local musl C++ toolchain, or set USE_DOCKER=1 to build in Alpine Docker." >&2
    exit 2
  fi
  HAS_STATIC_TURBOJPEG=0
  if find /usr/lib /usr/local/lib -name libturbojpeg.a -print -quit 2>/dev/null | grep -q . \
    && find /usr/lib /usr/local/lib -name libexif.a -print -quit 2>/dev/null | grep -q .; then
    HAS_STATIC_TURBOJPEG=1
  fi
  case "${TURBOJPEG_MODE}" in
    on|ON)
      if [ "${HAS_STATIC_TURBOJPEG}" -ne 1 ]; then
        echo "TURBOJPEG_MODE=on requested, but static libturbojpeg.a/libexif.a not found" >&2
        exit 2
      fi
      CMAKE_OPTS+=(-DWITH_TURBOJPEG=On)
      ;;
    off|OFF)
      CMAKE_OPTS+=(-DWITH_TURBOJPEG=Off)
      ;;
    auto|AUTO)
      if [ "${HAS_STATIC_TURBOJPEG}" -eq 1 ]; then
        CMAKE_OPTS+=(-DWITH_TURBOJPEG=On)
      else
        CMAKE_OPTS+=(-DWITH_TURBOJPEG=Off)
      fi
      ;;
    *)
      echo "Invalid TURBOJPEG_MODE='${TURBOJPEG_MODE}'. Use auto|on|off." >&2
      exit 2
      ;;
  esac

  if [ "${WITH_PDF}" = "1" ]; then
    # Expects a prebuilt static poppler/cairo stack at PDF_STATIC_PREFIX
    # (the Alpine Docker path below builds one automatically).
    export PKG_CONFIG="pkg-config --static"
    export PKG_CONFIG_PATH="${PDF_STATIC_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  fi

  echo "Building with local musl toolchain into ${BUILD_DIR}"
  rm -rf "${BUILD_DIR}"
  cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" "${CMAKE_OPTS[@]}" \
    -DCMAKE_C_COMPILER=x86_64-linux-musl-gcc \
    -DCMAKE_CXX_COMPILER=x86_64-linux-musl-g++
  cmake --build "${BUILD_DIR}" -j"$(nproc)"
else
  echo "Building in Alpine Docker${DOCKER_PLATFORM:+ (platform: ${DOCKER_PLATFORM})}"
  CMAKE_OPTS_STR="$(printf '%q ' "${CMAKE_OPTS[@]}")"
  docker run --rm \
    "${DOCKER_PLATFORM_ARGS[@]}" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e TURBOJPEG_MODE="${TURBOJPEG_MODE}" \
    -e TURBOJPEG_STATIC_PREFIX="${TURBOJPEG_STATIC_PREFIX}" \
    -e WITH_PDF="${WITH_PDF}" \
    -e PDF_STATIC_PREFIX="${PDF_STATIC_PREFIX}" \
    -v "${ROOT_DIR}":/src \
    -w /src \
    alpine:3.20 \
    sh -euxc '
      APK_PKGS="build-base cmake pkgconf git libdeflate-dev libdeflate-static"
      if [ "'"${WITH_VIDEO}"'" = "1" ]; then
        # linux-headers: FFmpeg only enables the v4l2 input device if
        # linux/videodev2.h is present at configure time.
        APK_PKGS="${APK_PKGS} nasm yasm linux-headers"
      fi
      if [ "${WITH_PDF}" = "1" ]; then
        APK_PKGS="${APK_PKGS} meson samurai xz glib-dev glib-static"
        APK_PKGS="${APK_PKGS} pixman-dev pixman-static freetype-dev freetype-static"
        APK_PKGS="${APK_PKGS} fontconfig-dev fontconfig-static expat-dev expat-static"
        APK_PKGS="${APK_PKGS} libpng-dev libpng-static zlib-dev zlib-static"
        APK_PKGS="${APK_PKGS} brotli-static bzip2-static pcre2-dev libffi-dev"
        APK_PKGS="${APK_PKGS} gettext-static util-linux-dev util-linux-static libeconf-dev"
        APK_PKGS="${APK_PKGS} libjpeg-turbo-dev libjpeg-turbo-static"
      fi
      if [ "${TURBOJPEG_MODE}" != "off" ] && [ "${TURBOJPEG_MODE}" != "OFF" ]; then
        APK_PKGS="${APK_PKGS} autoconf automake gettext gettext-dev libtool libjpeg-turbo-dev libjpeg-turbo-static libexif-dev"
        if apk search -x libexif-static 2>/dev/null | grep -qE '^libexif-static-[0-9]'; then
          APK_PKGS="${APK_PKGS} libexif-static"
        fi
      fi
      apk add --no-cache \
        ${APK_PKGS}

      HAS_STATIC_TURBOJPEG=0
      if [ -f /usr/lib/libturbojpeg.a ] && [ -f /usr/lib/libexif.a ]; then
        HAS_STATIC_TURBOJPEG=1
      fi

      JPEG_PREFIX="${TURBOJPEG_STATIC_PREFIX}"
      if [ "${TURBOJPEG_MODE}" != "off" ] && [ "${TURBOJPEG_MODE}" != "OFF" ] && [ "${HAS_STATIC_TURBOJPEG}" -ne 1 ]; then
        echo "Building static turbojpeg/exif dependencies into ${JPEG_PREFIX}"
        rm -rf "${JPEG_PREFIX}" /tmp/libjpeg-turbo-src /tmp/libjpeg-turbo-build /tmp/libexif-src /tmp/libexif-build
        mkdir -p "${JPEG_PREFIX}" /tmp/libjpeg-turbo-src /tmp/libjpeg-turbo-build /tmp/libexif-src /tmp/libexif-build

        wget -qO- https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.0.3.tar.gz \
          | tar xz -C /tmp/libjpeg-turbo-src --strip-components=1
        cmake -S /tmp/libjpeg-turbo-src -B /tmp/libjpeg-turbo-build \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="${JPEG_PREFIX}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DENABLE_SHARED=OFF \
          -DENABLE_STATIC=ON
        cmake --build /tmp/libjpeg-turbo-build -j"$(getconf _NPROCESSORS_ONLN)"
        cmake --install /tmp/libjpeg-turbo-build

        LIBEXIF_TARBALL=/tmp/libexif.tar.xz
        for libexif_url in \
          https://deb.debian.org/debian/pool/main/libe/libexif/libexif_0.6.25.orig.tar.gz \
          https://deb.debian.org/debian/pool/main/libe/libexif/libexif_0.6.24.orig.tar.gz; do
          if wget -qO "${LIBEXIF_TARBALL}" "${libexif_url}"; then
            break
          fi
        done
        if [ ! -s "${LIBEXIF_TARBALL}" ]; then
          echo "Failed to download libexif source tarball." >&2
          exit 2
        fi
        tar xf "${LIBEXIF_TARBALL}" -C /tmp/libexif-src --strip-components=1
        cd /tmp/libexif-src
        autoreconf -fi
        cd /tmp/libexif-build
        /tmp/libexif-src/configure \
          --prefix="${JPEG_PREFIX}" \
          --enable-static \
          --disable-nls \
          --disable-shared
        make -j"$(getconf _NPROCESSORS_ONLN)"
        make install
        cd /src

        if [ -f "${JPEG_PREFIX}/lib/libturbojpeg.a" ] && [ -f "${JPEG_PREFIX}/lib/libexif.a" ]; then
          HAS_STATIC_TURBOJPEG=1
        fi
      fi
      case "${TURBOJPEG_MODE}" in
        on|ON)
          if [ "${HAS_STATIC_TURBOJPEG}" -ne 1 ]; then
            echo "TURBOJPEG_MODE=on requested, but static libturbojpeg.a/libexif.a not found" >&2
            exit 2
          fi
          TURBOJPEG_CMAKE_ARG="-DWITH_TURBOJPEG=On"
          ;;
        off|OFF)
          TURBOJPEG_CMAKE_ARG="-DWITH_TURBOJPEG=Off"
          ;;
        auto|AUTO)
          if [ "${HAS_STATIC_TURBOJPEG}" -eq 1 ]; then
            TURBOJPEG_CMAKE_ARG="-DWITH_TURBOJPEG=On"
          else
            TURBOJPEG_CMAKE_ARG="-DWITH_TURBOJPEG=Off"
          fi
          ;;
        *)
          echo "Invalid TURBOJPEG_MODE=${TURBOJPEG_MODE}. Use auto|on|off." >&2
          exit 2
          ;;
      esac

      CMAKE_PREFIX_PATH_VALUE=""
      if [ "'"${WITH_VIDEO}"'" = "1" ]; then
        CMAKE_PREFIX_PATH_VALUE="'"${FFMPEG_STATIC_PREFIX}"'"
      fi
      if [ "${HAS_STATIC_TURBOJPEG}" -eq 1 ]; then
        if [ -n "${CMAKE_PREFIX_PATH_VALUE}" ]; then
          CMAKE_PREFIX_PATH_VALUE="${CMAKE_PREFIX_PATH_VALUE};${JPEG_PREFIX}"
        else
          CMAKE_PREFIX_PATH_VALUE="${JPEG_PREFIX}"
        fi
      fi

      if [ "'"${WITH_VIDEO}"'" = "1" ]; then
        FFMPEG_PREFIX="'"${FFMPEG_STATIC_PREFIX}"'"
        rm -rf /tmp/ffmpeg-src "${FFMPEG_PREFIX}"
        git clone --depth=1 --branch n6.1.1 https://github.com/FFmpeg/FFmpeg.git /tmp/ffmpeg-src
        cd /tmp/ffmpeg-src
        if [ "'"${WITH_VIDEO_DEVICE}"'" = "1" ]; then
          # --disable-autodetect also disables v4l2-m2m, and FFmpeg only
          # probes linux/videodev2.h (needed by the v4l2 indev) when
          # v4l2-m2m is enabled. Request both explicitly so configure
          # fails loudly instead of silently dropping device input.
          VIDEO_DEVICE_ARG="--enable-avdevice --enable-v4l2-m2m --enable-indev=v4l2"
        else
          VIDEO_DEVICE_ARG="--disable-avdevice"
        fi
        ./configure \
          --prefix="${FFMPEG_PREFIX}" \
          --enable-static \
          --disable-shared \
          --disable-programs \
          --disable-doc \
          --disable-debug \
          --disable-network \
          --disable-postproc \
          --disable-avfilter \
          --disable-autodetect \
          ${VIDEO_DEVICE_ARG}
        if [ "'"${WITH_VIDEO_DEVICE}"'" = "1" ]; then
          if ! grep -q "^CONFIG_V4L2_INDEV=yes" ffbuild/config.mak; then
            echo "FFmpeg configure did not enable the v4l2 input device;" >&2
            echo "video device support would be silently broken (is linux-headers installed?)." >&2
            exit 2
          fi
          echo "FFmpeg v4l2 input device enabled."
        fi
        make -j"$(getconf _NPROCESSORS_ONLN)"
        make install
        cd /src

        for lib in \
          "${FFMPEG_PREFIX}/lib/libavcodec.a" \
          "${FFMPEG_PREFIX}/lib/libavutil.a" \
          "${FFMPEG_PREFIX}/lib/libavformat.a" \
          "${FFMPEG_PREFIX}/lib/libswscale.a"; do
          if [ ! -f "${lib}" ]; then
            echo "Missing static FFmpeg library: ${lib}" >&2
            echo "Failed to build static FFmpeg archives needed for video support." >&2
            exit 2
          fi
        done
        if [ "'"${WITH_VIDEO_DEVICE}"'" = "1" ] && [ ! -f "${FFMPEG_PREFIX}/lib/libavdevice.a" ]; then
          echo "Missing static FFmpeg library: ${FFMPEG_PREFIX}/lib/libavdevice.a" >&2
          exit 2
        fi
      fi

      if [ "${WITH_PDF}" = "1" ]; then
        PDF_PREFIX="${PDF_STATIC_PREFIX}"
        rm -rf "${PDF_PREFIX}" /tmp/cairo-src /tmp/cairo-build /tmp/poppler-src /tmp/poppler-build
        mkdir -p /tmp/cairo-src /tmp/poppler-src

        # Cairo without the X11 backends: Alpine has no static X libraries,
        # and its cairo-static drags them into the closure.
        wget -qO- https://cairographics.org/releases/cairo-1.18.4.tar.xz \
          | tar xJ -C /tmp/cairo-src --strip-components=1
        meson setup /tmp/cairo-build /tmp/cairo-src \
          --default-library=static \
          --prefix="${PDF_PREFIX}" --libdir=lib \
          -Dxlib=disabled -Dxcb=disabled -Dxlib-xcb=disabled \
          -Dquartz=disabled -Ddwrite=disabled -Dglib=disabled \
          -Dspectre=disabled -Dsymbol-lookup=disabled -Dtests=disabled \
          -Dfontconfig=enabled -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled
        ninja -C /tmp/cairo-build -j"$(getconf _NPROCESSORS_ONLN)"
        ninja -C /tmp/cairo-build install

        wget -qO- https://poppler.freedesktop.org/poppler-24.02.0.tar.xz \
          | tar xJ -C /tmp/poppler-src --strip-components=1
        PKG_CONFIG_PATH="${PDF_PREFIX}/lib/pkgconfig" \
          cmake -S /tmp/poppler-src -B /tmp/poppler-build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${PDF_PREFIX}" \
            -DCMAKE_INSTALL_LIBDIR=lib \
            -DBUILD_SHARED_LIBS=OFF \
            -DENABLE_GLIB=ON \
            -DENABLE_QT5=OFF -DENABLE_QT6=OFF -DENABLE_CPP=OFF \
            -DENABLE_UTILS=OFF -DENABLE_BOOST=OFF \
            -DENABLE_LIBOPENJPEG=none -DENABLE_DCTDECODER=libjpeg \
            -DENABLE_LCMS=OFF -DENABLE_LIBCURL=OFF -DENABLE_LIBTIFF=OFF \
            -DENABLE_NSS3=OFF -DENABLE_GPGME=OFF \
            -DENABLE_GOBJECT_INTROSPECTION=OFF \
            -DBUILD_GTK_TESTS=OFF -DBUILD_MANUAL_TESTS=OFF \
            -DRUN_GPERF_IF_PRESENT=OFF
        cmake --build /tmp/poppler-build -j"$(getconf _NPROCESSORS_ONLN)"
        cmake --install /tmp/poppler-build

        for lib in \
          "${PDF_PREFIX}/lib/libcairo.a" \
          "${PDF_PREFIX}/lib/libpoppler.a" \
          "${PDF_PREFIX}/lib/libpoppler-glib.a"; do
          if [ ! -f "${lib}" ]; then
            echo "Missing static PDF library: ${lib}" >&2
            exit 2
          fi
        done

        # Upstream poppler .pc files do not declare the private static
        # link closure; without these the final -static link underlinks.
        printf "Requires.private: libjpeg freetype2 fontconfig zlib\n" \
          >> "${PDF_PREFIX}/lib/pkgconfig/poppler.pc"
        sed -i "s/^Requires.private: poppler = .*/& gio-2.0/" \
          "${PDF_PREFIX}/lib/pkgconfig/poppler-glib.pc"
        # Alpine blkid.pc (pulled in via gio -> mount) misses libeconf.
        grep -q "econf" /usr/lib/pkgconfig/blkid.pc \
          || printf "Libs.private: -leconf\n" >> /usr/lib/pkgconfig/blkid.pc

        # Make timg final link resolve the full static closure of
        # poppler-glib/cairo through pkg-config.
        export PKG_CONFIG="pkg-config --static"
        export PKG_CONFIG_PATH="${PDF_PREFIX}/lib/pkgconfig"
      fi
      rm -rf /src/build-musl-static
      if [ -n "${CMAKE_PREFIX_PATH_VALUE}" ]; then
        CMAKE_PREFIX_PATH_ARG="-DCMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH_VALUE}"
        cmake -S /src -B /src/build-musl-static '"${CMAKE_OPTS_STR}"' "${TURBOJPEG_CMAKE_ARG}" "${CMAKE_PREFIX_PATH_ARG}"
      else
        cmake -S /src -B /src/build-musl-static '"${CMAKE_OPTS_STR}"' "${TURBOJPEG_CMAKE_ARG}"
      fi
      cmake --build /src/build-musl-static -j"$(getconf _NPROCESSORS_ONLN)"
      chown -R "${HOST_UID}:${HOST_GID}" /src/build-musl-static
    '
fi

BIN="${BUILD_DIR}/src/timg"
if [ ! -x "${BIN}" ]; then
  echo "Expected binary not found at ${BIN}" >&2
  exit 1
fi

echo
file "${BIN}"
if command -v ldd >/dev/null 2>&1; then
  ldd "${BIN}" || true
fi

# Only run the binary for feature summary if it's executable on this host.
# Cross-compiled binaries (e.g. ARM on x86_64) can't run natively.
if "${BIN}" --version > /dev/null 2>&1; then
  echo
  echo "Feature summary:"
  VERSION_OUT="$(mktemp)"
  "${BIN}" --version > "${VERSION_OUT}"
  grep -E '^timg |Turbo JPEG|QOI image loading|STB image loading|JPEG loading|Video decoding|Resize:|libdeflate|sixel output|GraphicsMagick|librsvg|OpenSlide|poppler' "${VERSION_OUT}" || true
  rm -f "${VERSION_OUT}"
else
  echo
  echo "Cross-compiled binary; skipping feature summary."
fi
