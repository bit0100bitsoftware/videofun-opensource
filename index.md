---
title: VideoFun — open-source components and source code
---

# VideoFun — open-source components and source code

VideoFun for Apple TV, Apple Vision Pro, Mac, iPhone and iPad is published by **bit0100bit software**. It uses the
open-source libraries below. Each one is distributed under its own licence. The full licence texts
are in the app (Settings → Licences & Acknowledgements) and inside each source archive on this page.

**This software uses libraries from the FFmpeg project under the LGPLv2.1.**

## Components, exact versions and source

Every archive is the unmodified upstream release, identified by its SHA-256. The app's build
downloads exactly these files and refuses any whose checksum differs. Copies are hosted here in
case an upstream link disappears.

| Component | Version | Licence | Source (copy here) | Upstream | SHA-256 |
|---|---|---|---|---|---|
| FFmpeg | 6.1.1 | LGPL-2.1-or-later (as configured) | [ffmpeg-6.1.1.tar.xz](sources/ffmpeg-6.1.1.tar.xz) | [ffmpeg.org](https://ffmpeg.org/releases/ffmpeg-6.1.1.tar.xz) | `8684f4b00f94b85461884c3719382f1261f0d9eb3d59640a1f4ac0873616f968` |
| GnuTLS | 3.8.3 | LGPL-2.1-or-later | [gnutls-3.8.3.tar.xz](sources/gnutls-3.8.3.tar.xz) | [gnupg.org](https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.3.tar.xz) | `f74fc5954b27d4ec6dfbb11dea987888b5b124289a3703afcada0ee520f4173e` |
| Nettle | 3.9.1 | LGPL-3.0-or-later or GPL-2.0-or-later | [nettle-3.9.1.tar.gz](sources/nettle-3.9.1.tar.gz) | [gnu.org](https://ftp.gnu.org/gnu/nettle/nettle-3.9.1.tar.gz) | `ccfeff981b0ca71bbd6fbcb054f407c60ffb644389a5be80d6716d5b550c6ce3` |
| GMP | 6.2.1 | LGPL-3.0-or-later or GPL-2.0-or-later | [gmp-6.2.1.tar.xz](sources/gmp-6.2.1.tar.xz) | [gnu.org](https://ftp.gnu.org/gnu/gmp/gmp-6.2.1.tar.xz) | `fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2` |
| dav1d | 1.1.0 | BSD-2-Clause | [dav1d-1.1.0.tar.xz](sources/dav1d-1.1.0.tar.xz) | [videolan.org](https://downloads.videolan.org/pub/videolan/dav1d/1.1.0/dav1d-1.1.0.tar.xz) | `fb57aae7875f28c30fb3dbae4a3683d27e2f91dde09ce5c60c22cef9bc58dfd1` |
| AMSMB2 (with libsmb2) | 4.0.3 | LGPL-2.1-or-later | [AMSMB2-4.0.3-with-libsmb2.tar.gz](sources/AMSMB2-4.0.3-with-libsmb2.tar.gz) | [github.com/amosavian/AMSMB2](https://github.com/amosavian/AMSMB2/tree/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0) at `1726aaaf`, libsmb2 at `aff9fa6b` | `7605278a858027a465273306101d8ffa051f0d8076e92233843d5439d8d4db32` |

The AMSMB2 archive is a copy of that exact revision, including its libsmb2 submodule. GitHub's
automatic download archives leave out the submodule.

## Our changes

- **FFmpeg:** three patches, under FFmpeg's own licence:
  - [0001-videotoolbox-metal-compatible-buffers.patch](patches/0001-videotoolbox-metal-compatible-buffers.patch)
    asks Apple's hardware decoder for Metal-compatible picture buffers instead of OpenGL-compatible
    ones; the latter do not exist on visionOS.
  - [0002-tls-verify-by-default.patch](patches/0002-tls-verify-by-default.patch) turns certificate
    verification on by default for every https connection. When no CA file is given, it uses the
    file named by `FFMPEG_TLS_DEFAULT_CA_FILE`; the app points that at its bundled copy of the
    Mozilla CA list (MPL-2.0, from curl.se/ca).
  - [0003-mov-hls-seek-reset.patch](patches/0003-mov-hls-seek-reset.patch) makes seeking work in HLS
    streams made of fragmented-MP4 segments: it backports FFmpeg's own later fix to the MP4 demuxer
    (ticket 7359), and makes the HLS demuxer judge the first packet after a seek by its
    presentation time.
- **GnuTLS, Nettle, GMP, dav1d and AMSMB2/libsmb2:** used unmodified.

## How the libraries were built

[build-ffmpeg-lgpl.sh](scripts/build-ffmpeg-lgpl.sh) is the complete build procedure:

- It fetches the archives above and checks each one's checksum.
- It applies the patches, and stops if one does not apply.
- It runs each library's `configure` with the exact options used. FFmpeg's configuration has no
  `--enable-gpl`, `--enable-version3` or `--enable-nonfree`.
- It builds the same sources, with the same options, for every platform the app runs on: Apple TV,
  Apple Vision Pro, iPhone and iPad, and Mac (plus their simulators).

The script was written for the app's own source tree. It reads the patches from
`Scripts/ffmpeg-patches/` and writes the built libraries to `Vendor/FFmpegKit-LGPL/Sources/`, both
relative to that tree. To run it on its own, place the patches in `Scripts/ffmpeg-patches/` beside
the script's parent folder. AMSMB2 is built by Xcode as an ordinary Swift package.

## Replacing a library and relinking

FFmpeg, GnuTLS, Nettle and GMP are currently linked statically into the app, on every platform. On request we will
provide the app's object files and the exact link command. With them you can rebuild the app
against a modified version of any of these libraries. Write to
[support@bit0100bitsoftware.com](mailto:support@bit0100bitsoftware.com).

## Written offer

For at least three years after we last distribute this version of the app, we will provide anyone
who asks with a complete machine-readable copy of the source code of the libraries above,
including our patch and build script. We will charge no more than our cost of physically
performing the transfer. Write to
[support@bit0100bitsoftware.com](mailto:support@bit0100bitsoftware.com), quoting the app version.
