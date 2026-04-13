final: prev: rec {
  bazel_8 = prev.callPackage ../pkgs/bazel_8/package.nix {};
  bazel_9 = prev.callPackage ../pkgs/bazel_9/package.nix {};
}
