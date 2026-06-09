{ pkgs ? import <nixpkgs> {
  overlays = [
    (import ./overlay/overlay.nix)
  ];
} }:

pkgs.bazel_9
