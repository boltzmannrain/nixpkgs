{
  bash,
  coreutils,
  callPackage,
  gnugrep,
  lib,
  autoPatchelfHook,
  stdenv,
}:

{
  name,
  src,
  sourceRoot ? null,
  version ? null,
  targets,
  bazel,
  startupArgs ? [ ],
  commandArgs ? [ ],
  env ? { },
  serverJavabase ? null,
  registry ? null,
  bazelRepoCacheFOD ? {
    outputHash = null;
    outputHashAlgo = "sha256";
  },
  postUnpack ? null,
  bazelPreBuild ? "", # TODO: find a better interface, currently whether it is before or mkdir isn't clear
  patches ? [ ],
  installPhase,
  buildInputs ? [ ],
  nativeBuildInputs ? [ ],
  autoPatchelfIgnoreMissingDeps ? null,
}:
let
  # FOD produced by `bazel fetch`
  # Repo cache contains content-addressed external Bazel dependencies without any patching
  # Potentially this can be nixified via --experimental_repository_resolved_file
  # (Note: file itself isn't reproducible because it has lots of extra info and order
  #        isn't stable too. Parsing it into nix fetch* commands isn't trivial but might be possible)
  bazelRepoCache =
    if bazelRepoCacheFOD.outputHash == null then
      # TODO: make repo cache required now that vendor FOD is removed?
      null
    else
      (callPackage ./bazelDerivation.nix { } {
        # TODO: get rid of following steps to avoid possible bazel content-addressing issues?
        # - shrinking RPATHs of ELF executables and libraries
        # - patching script interpreter paths
        name = "bazelRepoCache";
        inherit (bazelRepoCacheFOD) outputHash outputHashAlgo;
        inherit
          src
          postUnpack
          patches
          version
          sourceRoot
          env
          buildInputs
          nativeBuildInputs
          ;
        inherit registry;
        inherit
          bazel
          targets
          startupArgs
          serverJavabase
          ;
        command = "fetch";
        outputHashMode = "recursive";
        commandArgs = [ "--repository_cache=repo_cache" ] ++ commandArgs;
        bazelPreBuild = ''
          mkdir repo_cache
        '' + bazelPreBuild;
        installPhase = ''
          mkdir -p $out/repo_cache
          cp -r --reflink=auto repo_cache/* $out/repo_cache
        '';
      });
  # Vendor deps contains unpacked&patches external dependencies, this may need Nix-specific
  # patching to address things like
  # - broken symlinks
  # - symlinks or other references to absolute nix store paths which isn't allowed for FOD
  # - autoPatchelf for externally-fetched binaries
  #
  # Either repo cache or vendor deps should be enough to build a given package
  # TODO: make vendoring stage opt-in if no patching is needed
  # TODO: also consider simple text patching ability via registry rewrites
  bazelVendorDeps = callPackage ./bazelDerivation.nix { } {
    name = "bazelVendorDeps";
    inherit
      src
      postUnpack
      patches
      version
      sourceRoot
      env
      nativeBuildInputs
      ;
    inherit registry bazelRepoCache;
    inherit
      bazel
      targets
      startupArgs
      serverJavabase
      ;
    buildInputs = lib.optional (!stdenv.hostPlatform.isDarwin) autoPatchelfHook ++ buildInputs;
    inherit autoPatchelfIgnoreMissingDeps;
    # autoPatchelf will cross-link different jdks if run on top-level, we'll run manually
    dontAutoPatchelf = true;
    command = "vendor";
    commandArgs = [ "--vendor_dir=vendor_dir" ] ++ commandArgs;
    bazelPreBuild = ''
      mkdir vendor_dir
    '' + bazelPreBuild;
    bazelPostBuild = ''
                    # remove symlinks that point to locations under bazel_src/
                    find vendor_dir -type l -lname "$HOME/*" -exec rm '{}' \;
                    # remove symlinks to temp build directory on darwin
                    find vendor_dir -type l -lname "/private/var/tmp/*" -exec rm '{}' \;
                    # remove broken symlinks
                    find vendor_dir -xtype l -exec rm '{}' \;

                    # remove .marker files referencing NIX_STORE as those references aren't allowed in FOD
                    (${gnugrep}/bin/grep -rI "$NIX_STORE/" vendor_dir --files-with-matches --include="*.marker" --null || true) \
                      | xargs -0 --no-run-if-empty rm

                    function sedVerbose() {
                      local path=$1; shift;
                      sed -i".bak-nix" "$path" "$@"
                      diff -U0 "$path.bak-nix" "$path" | sed "s/^/  /" || true
                      rm -f "$path.bak-nix"
                    }
                    # TODO: make opt-in & customizable
                    ${gnugrep}/bin/grep -rlZ --include="*.bzl" --include "BUILD.bazel" --include "BUILD" /bin/bash vendor_dir \
                      | while IFS="" read -r -d "" path; do
                          echo "$path"
                          sedVerbose "$path" \
                            -e 's!/usr/bin/bash!${bash}/bin/bash!g' \
                            -e 's!/bin/bash!${bash}/bin/bash!g'
                      done;
                    # TODO: make opt-in & customizable
                    ${gnugrep}/bin/grep -rlZ --include="*.bzl" --include "BUILD.bazel" --include "BUILD" --include "java_stub_template.txt" /usr/bin/env vendor_dir \
                      | while IFS="" read -r -d "" path; do
                          echo "$path"
                          sedVerbose "$path" \
                            -e 's!/usr/bin/env bash!${bash}/bin/bash!g' \
                            -e 's!/usr/bin/env!${coreutils}/bin/env!g'
                      done;
    '';
    installPhase = ''
      mkdir -p $out/vendor_dir
      cp -r --reflink=auto vendor_dir/* $out/vendor_dir
      # autoPatchelf may fail on some paths without permissions change
      chmod -R u+w $out/vendor_dir
      # TODO: make opt-in & customizable
      # NOTE: this can be really slow on huge vendor dirs due to per-invocation overhead
      for x in `find $out/vendor_dir -type d -maxdepth 1 -mindepth 1`; do autoPatchelf "$x"; done;
    '';

  };

  package = callPackage ./bazelDerivation.nix { } {
    inherit
      name
      src
      postUnpack
      patches
      version
      sourceRoot
      env
      buildInputs
      nativeBuildInputs
      ;
    inherit registry bazelRepoCache bazelVendorDeps;
    inherit
      bazel
      targets
      startupArgs
      serverJavabase
      commandArgs
      ;
    inherit installPhase;
    command = "build";
  };
in
package // { passthru = { inherit bazelRepoCache bazelVendorDeps; }; }
