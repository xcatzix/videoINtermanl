{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  buildInputs = with pkgs;
    [
       stdenv
       cmake
       git   # for TIMG_VERSION_FROM_GIT
       pkg-config
       graphicsmagick
       libjpeg
       libdeflate
       ffmpeg
       libexif
       libsixel
       librsvg cairo
       poppler

       # Don't include qoi and stb by default to see if the cmake
       # fallback to third_party/ works.
       #qoi
       #stb

       openslide
       pandoc
       llvmPackages_21.clang-tools  # clang-format
    ];
}
