#!/usr/bin/env bash
#
# build-ffmpeg-lgpl.sh -- build the LGPL FFmpeg that VideoFun links (#29).
#
# Produces static .xcframeworks for tvOS, tvOS Simulator, visionOS and visionOS Simulator
# (arm64 only) into Vendor/FFmpegKit-LGPL/Sources/, which is the local Swift package that
# project.yml points at. Everything is built from RELEASE TARBALLS whose SHA-256 is pinned
# below, so the exact corresponding source of every shipped binary is known -- that is an
# LGPL obligation (docs/FFMPEG-LGPL.md), not a nicety.
#
#   FFmpeg 6.1.1   LGPL-2.1+  (configured WITHOUT --enable-gpl / --enable-version3)
#   dav1d 1.1.0    BSD-2-Clause
#   GnuTLS 3.8.3   LGPL-2.1+  (TLS for https:// in FFmpeg -- same TLS stack as the GPL build)
#   Nettle 3.9.1   LGPL-3+ or GPL-2+ (dual), needed by GnuTLS
#   GMP 6.2.1      LGPL-3+ or GPL-2+ (dual), needed by Nettle's hogweed / GnuTLS
#
# FFmpeg gets the source patches in Scripts/ffmpeg-patches/: 0001 VideoToolbox buffers
# Metal-compatible (required on visionOS); 0002 TLS certificate verification on by default with an
# app-supplied CA file (#62); 0003 the mov demuxer resets after an HLS seek, backported from
# FFmpeg master (#67). The other libraries are built unmodified.
#
# FFmpeg 6.1.1 is load-bearing: Platforms/tvOS/Features/Player/dovi_rpu.h vendors that
# release's internal DOVIContext layout and calls ff_dovi_* from libavcodec. A different
# FFmpeg version is silent memory corruption, not a build error.
#
# Usage:
#   Scripts/build-ffmpeg-lgpl.sh [WORKDIR]
#     WORKDIR  scratch for tarballs + build trees (default: $TMPDIR/videofun-ffmpeg-lgpl).
#              Several GB; delete it afterwards. Only Vendor/FFmpegKit-LGPL/Sources is kept.
#   PLATFORMS="tvos xros" Scripts/build-ffmpeg-lgpl.sh   # subset (default: all four)
#
# Needs: Xcode command-line tools, meson + ninja (dav1d), pkg-config. No nasm (arm64 only).
# Takes roughly 30-60 minutes; prints [stage/total] progress lines.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-${TMPDIR:-/tmp}/videofun-ffmpeg-lgpl}"
OUT="$REPO/Vendor/FFmpegKit-LGPL/Sources"
PLATFORMS="${PLATFORMS:-tvos tvsimulator xros xrsimulator}"
JOBS="$(sysctl -n hw.ncpu)"
MIN_OS="26.0"   # project.yml deploymentTarget for both tvOS and visionOS

# name|url|sha256
SOURCES=(
  "ffmpeg-6.1.1|https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz|8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968"
  "dav1d-1.1.0|https://downloads.videolan.org/pub/videolan/dav1d/1.1.0/dav1d-1.1.0.tar.xz|fb57aae7875f28c30fb3dbae4a3683d27e2f91dde09ce5c60c22cef9bc58dfd1"
  "gnutls-3.8.3|https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.3.tar.xz|f74fc5954b27d4ec6dfbb11dea987888b5b124289a3703afcada0ee520f4173e"
  "nettle-3.9.1|https://ftp.gnu.org/gnu/nettle/nettle-3.9.1.tar.gz|ccfeff981b0ca71bbd6fbcb054f407c60ffb644389a5be80d6716d5b550c6ce3"
  "gmp-6.2.1|https://ftp.gnu.org/gnu/gmp/gmp-6.2.1.tar.xz|fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2"
)

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

# ---------------------------------------------------------------- platform table
sdk_of() { case "$1" in tvos) echo appletvos;; tvsimulator) echo appletvsimulator;; xros) echo xros;; xrsimulator) echo xrsimulator;; esac; }
triple_of() {
  case "$1" in
    tvos) echo "arm64-apple-tvos$MIN_OS";;
    tvsimulator) echo "arm64-apple-tvos$MIN_OS-simulator";;
    xros) echo "arm64-apple-xros$MIN_OS";;
    xrsimulator) echo "arm64-apple-xros$MIN_OS-simulator";;
  esac
}
meson_subsystem_of() { case "$1" in tvos) echo tvos;; tvsimulator) echo tvos-simulator;; xros) echo xros;; xrsimulator) echo xros-simulator;; esac; }

# ---------------------------------------------------------------- sources
fetch_sources() {
  mkdir -p "$WORK/src"
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name url sha <<<"$entry"
    local tarball="$WORK/src/$(basename "$url")"
    [ -f "$tarball" ] || curl -sSfL -o "$tarball" "$url"
    local got; got="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    if [ "$got" != "$sha" ]; then
      echo "error: $tarball sha256 $got != pinned $sha" >&2
      exit 1
    fi
    log "  verified $name sha256=$got"
  done
}

fresh_tree() {  # $1 = name, $2 = platform -> echoes a clean extracted source dir
  local dir="$WORK/build/$2/$1"
  rm -rf "$dir"; mkdir -p "$WORK/build/$2"
  tar -xf "$WORK/src/"$1.tar.* -C "$WORK/build/$2"
  echo "$dir"
}

# ---------------------------------------------------------------- per-library builds
setup_env() {  # $1 = platform
  PLAT="$1"
  SDK="$(xcrun --sdk "$(sdk_of "$PLAT")" --show-sdk-path)"
  TRIPLE="$(triple_of "$PLAT")"
  PREFIX="$WORK/prefix/$PLAT"
  mkdir -p "$PREFIX"
  export CC="$(xcrun --sdk "$(sdk_of "$PLAT")" -f clang)"
  export CXX="$(xcrun --sdk "$(sdk_of "$PLAT")" -f clang++)"
  export AR="$(xcrun --sdk "$(sdk_of "$PLAT")" -f ar)"
  export RANLIB="$(xcrun --sdk "$(sdk_of "$PLAT")" -f ranlib)"
  export CFLAGS="-arch arm64 -isysroot $SDK -target $TRIPLE -fno-common -O2 -I$PREFIX/include"
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS="-isysroot $SDK -target $TRIPLE -I$PREFIX/include"
  export LDFLAGS="-arch arm64 -isysroot $SDK -target $TRIPLE -L$PREFIX/lib"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  unset PKG_CONFIG_PATH
  # libxml2 (DASH demuxer) is the SDK's own system library; give pkg-config a description of it.
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat >"$PREFIX/lib/pkgconfig/libxml-2.0.pc" <<EOF
Name: libXML
Description: libxml2 from the $(sdk_of "$PLAT") SDK (system library)
Version: $(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/libxml2/libxml/xmlversion.h")
Libs: -lxml2
Cflags: -I$SDK/usr/include/libxml2
EOF
  # autotools: build != host forces cross-compilation (tvOS binaries cannot run here)
  # (the two strings differ only in spelling; autoconf compares them as strings).
  HOST="arm64-apple-darwin"
  BUILD="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin$(uname -r)"
}

build_gmp() {
  local src; src="$(fresh_tree gmp-6.2.1 "$PLAT")"
  (cd "$src" && ./configure --build="$BUILD" --host="$HOST" --prefix="$PREFIX" \
      --disable-assembly --with-pic --enable-static --disable-shared --disable-fast-install \
    && make -j"$JOBS" && make install) >"$src.log" 2>&1
}

build_nettle() {
  local src; src="$(fresh_tree nettle-3.9.1 "$PLAT")"
  (cd "$src" && ./configure --build="$BUILD" --host="$HOST" --prefix="$PREFIX" --libdir="$PREFIX/lib" \
      --disable-assembler --disable-openssl --disable-gcov --disable-documentation \
      --enable-pic --enable-static --disable-shared --disable-dependency-tracking \
    && make -j"$JOBS" && make install) >"$src.log" 2>&1
}

build_gnutls() {
  local src; src="$(fresh_tree gnutls-3.8.3 "$PLAT")"
  (cd "$src" && ./configure --build="$BUILD" --host="$HOST" --prefix="$PREFIX" \
      --with-included-libtasn1 --with-included-unistring --without-brotli --without-idn \
      --without-p11-kit --without-zlib --without-zstd --without-tpm --without-tpm2 \
      --disable-hardware-acceleration --disable-openssl-compatibility --disable-code-coverage \
      --disable-doc --disable-maintainer-mode --disable-manpages --disable-nls --disable-rpath \
      --disable-tools --disable-tests --disable-full-test-suite --disable-cxx \
      --with-pic --enable-static --disable-shared --disable-fast-install --disable-dependency-tracking \
    && make -j"$JOBS" && make install) >"$src.log" 2>&1
}

build_dav1d() {
  local src; src="$(fresh_tree dav1d-1.1.0 "$PLAT")"
  local cross="$src/cross.meson"
  cat >"$cross" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$(xcrun --sdk "$(sdk_of "$PLAT")" -f strip)'
pkgconfig = 'pkg-config'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-target', '$TRIPLE', '-fno-common']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-target', '$TRIPLE']

[host_machine]
system = 'darwin'
subsystem = '$(meson_subsystem_of "$PLAT")'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
  (cd "$src" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
      meson setup build --cross-file="$cross" --prefix="$PREFIX" --libdir=lib \
        --buildtype=release --default-library=static \
        -Denable_asm=true -Denable_tools=false -Denable_examples=false -Denable_tests=false \
    && ninja -C build && ninja -C build install) >"$src.log" 2>&1
}

# The configure line of the GPL build that shipped until 2026-10-08 (read out of its Libavutil
# with `strings`), with ONLY these changes -- see docs/FFMPEG-LGPL.md for the diff and why:
#   removed  --enable-gpl --enable-version3                     (licence)
#   removed  --enable-libsmbclient --enable-protocol=libsmbclient (GPL-3 Samba; app uses AMSMB2)
#   removed  --enable-libzvbi --enable-decoder=libzvbi_teletext  (teletext; unused)
#   removed  --enable-gmp                                        (forces version3; only rtmpe used it)
#   removed  --enable-filter=boxblur --enable-filter=delogo      (gpl-only filters; app has no avfilter use)
#   removed  vulkan / libshaderc / libplacebo / lcms2 / libsrt and their *_vulkan, libplacebo filters
#            (no app use; dropping them drops MoltenVK, shaderc, placebo, lcms2, SRT from the link)
#   removed  --enable-encoder=*_videotoolbox (the old line's tvOS branch quirk; app encodes nothing)
FFMPEG_CONFIGURE=(
  --disable-armv5te --disable-armv6 --disable-armv6t2
  --disable-bzlib --disable-gray --disable-iconv --disable-linux-perf
  --disable-shared --disable-small --disable-swscale-alpha --disable-symver --disable-xlib
  --enable-cross-compile --enable-libxml2
  --enable-optimizations --enable-pic --enable-runtime-cpudetect --enable-static --enable-thumb
  --pkg-config-flags=--static
  --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages
  --enable-avcodec --enable-avformat --enable-avutil --enable-network --enable-swresample --enable-swscale
  --disable-devices --disable-outdevs --disable-indevs --disable-postproc
  --disable-d3d11va --disable-dxva2 --disable-vaapi --disable-vdpau
  --disable-muxers
  --enable-muxer=flac --enable-muxer=dash --enable-muxer=hevc --enable-muxer=m4v --enable-muxer=matroska
  --enable-muxer=mov --enable-muxer=mp4 --enable-muxer=mpegts '--enable-muxer=webm*' --enable-muxer=nut
  --disable-encoders
  --enable-encoder=aac --enable-encoder=alac --enable-encoder=flac '--enable-encoder=pcm*'
  --enable-encoder=movtext --enable-encoder=mpeg4 --enable-encoder=prores
  --enable-protocols
  --disable-demuxers
  --enable-demuxer=aac --enable-demuxer=ac3 --enable-demuxer=aiff --enable-demuxer=amr --enable-demuxer=ape
  --enable-demuxer=asf --enable-demuxer=ass --enable-demuxer=av1 --enable-demuxer=avi --enable-demuxer=caf
  --enable-demuxer=concat --enable-demuxer=dash --enable-demuxer=data --enable-demuxer=dv --enable-demuxer=eac3
  --enable-demuxer=flac --enable-demuxer=flv --enable-demuxer=h264 --enable-demuxer=hevc --enable-demuxer=hls
  --enable-demuxer=live_flv --enable-demuxer=loas --enable-demuxer=m4v --enable-demuxer=matroska
  --enable-demuxer=mov --enable-demuxer=mp3 '--enable-demuxer=mpeg*' --enable-demuxer=nut --enable-demuxer=ogg
  --enable-demuxer=rm --enable-demuxer=rtsp --enable-demuxer=rtp --enable-demuxer=srt --enable-demuxer=vc1
  --enable-demuxer=wav --enable-demuxer=webm_dash_manifest
  --enable-bsfs
  --disable-decoders
  --enable-decoder=av1 --enable-decoder=dca --enable-decoder=dxv --enable-decoder=ffv1 --enable-decoder=ffvhuff
  --enable-decoder=flv --enable-decoder=h263 --enable-decoder=h263i --enable-decoder=h263p --enable-decoder=h264
  --enable-decoder=hap --enable-decoder=hevc --enable-decoder=huffyuv --enable-decoder=indeo5
  --enable-decoder=mjpeg --enable-decoder=mjpegb '--enable-decoder=mpeg*' --enable-decoder=mts2
  --enable-decoder=prores --enable-decoder=rv10 --enable-decoder=rv20 --enable-decoder=rv30 --enable-decoder=rv40
  --enable-decoder=snow --enable-decoder=svq3 --enable-decoder=tscc --enable-decoder=txd
  --enable-decoder=wmv1 --enable-decoder=wmv2 --enable-decoder=wmv3 --enable-decoder=vc1
  --enable-decoder=vp6 --enable-decoder=vp6a --enable-decoder=vp6f --enable-decoder=vp7 --enable-decoder=vp8
  --enable-decoder=vp9
  '--enable-decoder=aac*' '--enable-decoder=ac3*' '--enable-decoder=adpcm*' '--enable-decoder=alac*'
  '--enable-decoder=amr*' --enable-decoder=ape --enable-decoder=cook --enable-decoder=dolby_e
  '--enable-decoder=eac3*' --enable-decoder=flac '--enable-decoder=mp1*' '--enable-decoder=mp2*'
  '--enable-decoder=mp3*' --enable-decoder=opus '--enable-decoder=pcm*' --enable-decoder=sonic
  --enable-decoder=truehd --enable-decoder=tta --enable-decoder=vorbis '--enable-decoder=wma*'
  --enable-decoder=ass --enable-decoder=ccaption --enable-decoder=dvbsub --enable-decoder=dvdsub
  --enable-decoder=mpl2 --enable-decoder=movtext --enable-decoder=pgssub --enable-decoder=srt
  --enable-decoder=ssa --enable-decoder=subrip --enable-decoder=xsub --enable-decoder=webvtt
  --disable-filters
  --enable-filter=aformat --enable-filter=amix --enable-filter=anull --enable-filter=aresample
  --enable-filter=areverse --enable-filter=asetrate --enable-filter=atempo --enable-filter=atrim
  --enable-filter=bwdif --enable-filter=equalizer --enable-filter=estdif --enable-filter=firequalizer
  --enable-filter=format --enable-filter=fps --enable-filter=gblur --enable-filter=hflip
  --enable-filter=hwdownload --enable-filter=hwmap --enable-filter=hwupload --enable-filter=idet
  --enable-filter=lenscorrection '--enable-filter=lut*' --enable-filter=negate --enable-filter=null
  --enable-filter=overlay --enable-filter=palettegen --enable-filter=paletteuse --enable-filter=pan
  --enable-filter=rotate --enable-filter=scale --enable-filter=setpts --enable-filter=superequalizer
  --enable-filter=transpose --enable-filter=trim --enable-filter=vflip --enable-filter=volume
  --enable-filter=w3fdif --enable-filter=yadif
  --disable-debug --enable-stripping
  --arch=aarch64 --target-os=darwin --enable-neon --enable-asm
  --enable-videotoolbox --enable-audiotoolbox
  --enable-filter=yadif_videotoolbox --enable-filter=scale_vt --enable-filter=transpose_vt
  --disable-avdevice --disable-programs
  --enable-libdav1d --enable-decoder=libdav1d
  --enable-gnutls
)

build_ffmpeg() {
  local src; src="$(fresh_tree ffmpeg-6.1.1 "$PLAT")"
  # Our source modifications (LGPL: published alongside the tarball). See each patch header.
  # A patch that does not apply must STOP the build: the configure step below overwrites this log,
  # so a failed patch used to leave no trace and ship unpatched FFmpeg.
  for p in "$REPO"/Scripts/ffmpeg-patches/*.patch; do
    if ! patch -p1 -d "$src" <"$p" >>"$src.log" 2>&1; then
      echo "error: $(basename "$p") did not apply to $src -- see $src.log" >&2
      exit 1
    fi
  done
  (cd "$src" && ./configure --prefix="$PREFIX" --cc="$CC" --cxx="$CXX" \
      --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" \
      "${FFMPEG_CONFIGURE[@]}" \
    && make -j"$JOBS" && make install) >"$src.log" 2>&1
  # Same extra headers the FFmpegKit plugin installed, so the Swift modules expose the same API.
  cp "$src/config.h" "$PREFIX/include/libavutil/config.h"
  cp "$src/config.h" "$PREFIX/include/libavcodec/config.h"
  cp "$src/config.h" "$PREFIX/include/libavformat/config.h"
  for h in getenv_utf8 libm thread intmath mem_internal attributes_internal internal; do
    cp "$src/libavutil/$h.h" "$PREFIX/include/libavutil/$h.h"
  done
  sed -i '' 's|^#include "timer.h"|// #include "timer.h"|' "$PREFIX/include/libavutil/internal.h"
  cp "$src/libavcodec/mathops.h" "$PREFIX/include/libavcodec/mathops.h"
  cp "$src/libavformat/os_support.h" "$PREFIX/include/libavformat/os_support.h"
  cp "$src/config_components.h" "$PREFIX/ffmpeg_config_components.h"  # evidence, not shipped
}

# ---------------------------------------------------------------- packaging
excludes_for() {
  case "$1" in
    Libavcodec) echo "xvmc vdpau qsv dxva2 d3d11va mathops videotoolbox";;
    Libavutil) echo "hwcontext_vulkan hwcontext_vdpau hwcontext_vaapi hwcontext_qsv hwcontext_opencl hwcontext_dxva2 hwcontext_d3d11va hwcontext_cuda hwcontext_videotoolbox getenv_utf8 intmath libm thread mem_internal internal attributes_internal";;
    Libavformat) echo "os_support";;
    *) echo "";;
  esac
}

make_framework() {  # $1 framework name, $2 static lib path, $3 header dir, $4 platform -> echoes framework dir
  local name="$1" lib="$2" headers="$3" plat="$4"
  local fw="$WORK/frameworks/$plat/$name.framework"
  rm -rf "$fw"; mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$lib" "$fw/$name"
  cp -R "$headers"/. "$fw/Headers/"
  {
    echo "framework module $name [system] {"
    echo "    umbrella \".\""
    for h in $(excludes_for "$name"); do
      [ -f "$fw/Headers/$h.h" ] && echo "    exclude header \"$h.h\""
    done
    echo "    export *"
    echo "}"
  } >"$fw/Modules/module.modulemap"
  local supported
  case "$plat" in tvos) supported=AppleTVOS;; tvsimulator) supported=AppleTVSimulator;; xros) supported=XROS;; xrsimulator) supported=XRSimulator;; esac
  cat >"$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.bit0100bitsoftware.ffmpeg-lgpl.$(echo "$name" | tr '_' '-')</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>6.1.1</string>
  <key>CFBundleVersion</key><string>6.1.1</string>
  <key>MinimumOSVersion</key><string>$MIN_OS</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
</dict>
</plist>
EOF
  echo "$fw"
}

# framework name | static lib (relative to prefix) | header dir (relative to prefix)
FRAMEWORKS=(
  "Libavcodec|lib/libavcodec.a|include/libavcodec"
  "Libavformat|lib/libavformat.a|include/libavformat"
  "Libavutil|lib/libavutil.a|include/libavutil"
  "Libavfilter|lib/libavfilter.a|include/libavfilter"
  "Libswresample|lib/libswresample.a|include/libswresample"
  "Libswscale|lib/libswscale.a|include/libswscale"
  "libdav1d|lib/libdav1d.a|include/dav1d"
  "gnutls|lib/libgnutls.a|include/gnutls"
  "nettle|lib/libnettle.a|include/nettle"
  "hogweed|lib/libhogweed.a|include/nettle"
  "gmp|lib/libgmp.a|include/gmp-only"
)

package_all() {
  mkdir -p "$OUT"
  for p in $PLATFORMS; do
    mkdir -p "$WORK/prefix/$p/include/gmp-only"
    cp "$WORK/prefix/$p/include/gmp.h" "$WORK/prefix/$p/include/gmp-only/gmp.h"
  done
  for entry in "${FRAMEWORKS[@]}"; do
    IFS='|' read -r name lib headers <<<"$entry"
    local args=()
    for p in $PLATFORMS; do
      local fw; fw="$(make_framework "$name" "$WORK/prefix/$p/$lib" "$WORK/prefix/$p/$headers" "$p")"
      args+=(-framework "$fw")
    done
    rm -rf "$OUT/$name.xcframework"
    xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$name.xcframework" >/dev/null
    log "  packaged $name.xcframework"
  done
}

# ---------------------------------------------------------------- main
STEPS=(gmp nettle gnutls dav1d ffmpeg)
NPLAT=$(echo "$PLATFORMS" | wc -w | tr -d ' ')
TOTAL=$(( NPLAT * ${#STEPS[@]} + 2 ))
N=0
stage() { N=$((N + 1)); log "[$N/$TOTAL] $(( 100 * (N - 1) / TOTAL ))% -- $*"; }

log "work dir: $WORK   output: $OUT   platforms: $PLATFORMS"
stage "fetch + verify sources"
fetch_sources
for p in $PLATFORMS; do
  setup_env "$p"
  for s in "${STEPS[@]}"; do
    stage "$s for $p (log: $WORK/build/$p/<src>.log)"
    "build_$s"
  done
done
stage "package xcframeworks"
package_all
log "[$TOTAL/$TOTAL] 100% -- done"
for p in $PLATFORMS; do
  strings -a "$WORK/prefix/$p/lib/libavutil.a" | grep -m1 'license:' | sed "s/^/  $p: /"
done
