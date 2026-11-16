# Build environment for the Tracktion Engine benchmark driver.
#   bench/tracktion/build.sh    (enters this shell itself)
# Pinned to the nixpkgs the flake uses when build.sh sets NIX_PATH.
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [ cmake ninja pkg-config gcc ];
  # JUCE's GUI modules are compiled in (Tracktion depends on them), so they
  # need the X11 headers, but the driver never opens a window.
  buildInputs = with pkgs; [
    alsa-lib freetype fontconfig curl
    libx11 libxext libxrandr libxinerama libxcursor libxcomposite libxrender libxi
  ];
}
