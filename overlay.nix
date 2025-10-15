final: prev: rec {
  glibc_fhs = prev.glibc.overrideAttrs (oldAttrs: {
    patches =
      with prev.pkgs.lib;
      (lists.partition (
        a:
        !(builtins.elem (builtins.baseNameOf a) [
          "dont-use-system-ld-so-cache.patch"
          "dont-use-system-ld-so-preload.patch"
          "fix_path_attribute_in_getconf.patch"
        ])
      ) oldAttrs.patches).right;
  });
}
