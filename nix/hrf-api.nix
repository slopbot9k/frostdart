# Reference builds of the hrf-api library.
#
# Every non-Apple target is a pure, sandboxed derivation. Apple targets need
# the pinned Xcode from the host, so build-apple.sh builds them inside the
# `apple` dev shell with the same toolchain and flags.
#
# The settings come from build-config.json, shared with the Dart hook, so the
# two build paths agree on versions, floors, and the canonical path prefixes.
{ pkgs, zig, settings, src }:
let
  inherit (pkgs) lib stdenvNoCC;
  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  toolchains = settings.toolchains;
  paths = settings.paths;
  floors = settings.floors;
  registryPath = "${paths.registry}/${paths.registryIndex}";
  crate = "hrf-api";

  seraiSrc = lib.cleanSourceWith {
    name = "serai";
    inherit src;
    filter = path: _type:
      let base = baseNameOf path;
      in base != "target" && base != ".git";
  };

  linuxTargets = [ "x86_64-unknown-linux-gnu" "aarch64-unknown-linux-gnu" ];
  androidTargets = [ "aarch64-linux-android" "armv7-linux-androideabi" "x86_64-linux-android" ];
  windowsTargets = [ "x86_64-pc-windows-msvc" ];
  appleTargets = builtins.filter (t: lib.hasInfix "-apple-" t) settings.targets;
  # Google ships no NDK host binaries for aarch64 Linux.
  androidSupported = system != "aarch64-linux";
  pureTargets = linuxTargets ++ lib.optionals androidSupported androidTargets ++ windowsTargets;

  # nixpkgs wraps cargo-zigbuild with its own zig on PATH; point it at the
  # pinned official binary instead so the pin actually takes effect.
  cargoZigbuild = pkgs.cargo-zigbuild.override { inherit zig; };

  rust = pkgs.rust-bin.stable.${settings.rust}.minimal.override {
    targets = pureTargets ++ lib.optionals isDarwin appleTargets;
  };

  # Every crate in Cargo.lock, fetched by the checksum recorded there, laid
  # out as <name>-<version> directories like a cargo registry.
  vendor = pkgs.rustPlatform.importCargoLock { lockFile = src + "/Cargo.lock"; };

  llvm = pkgs."llvmPackages_${toString toolchains.llvm}";

  androidSdk = (pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
    ndkVersions = [ toolchains.ndk ];
  }).androidsdk;
  ndkHost = if isDarwin then "darwin-x86_64" else "linux-x86_64";
  ndkBin = "${androidSdk}/libexec/android-sdk/ndk-bundle/toolchains/llvm/prebuilt/${ndkHost}/bin";
  # Google compiles each NDK host package's crtbegin objects with that
  # package's own clang, so the darwin and Linux packages ship different
  # bytes for them, and crtbegin_so.o is linked into every shared library.
  # Every host links the Linux package's objects instead. The checksum is
  # the one androidenv records for the same download.
  ndkLinuxZip = pkgs.fetchurl {
    url = toolchains.ndkLinux.url;
    sha256 = toolchains.ndkLinux.sha256;
  };
  androidCrt = pkgs.runCommand "android-ndk-crt-${toolchains.ndk}" {
    nativeBuildInputs = [ pkgs.unzip ];
  } ''
    unzip -q ${ndkLinuxZip} \
      'android-ndk-*/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/*/${toString floors.android}/crt*.o' \
      -d "$TMPDIR/ndk"
    cd "$TMPDIR"/ndk/android-ndk-*/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib
    for abi in *; do
      mkdir -p "$out/$abi"
      cp "$abi/${toString floors.android}"/crt*.o "$out/$abi/"
    done
  '';
  # Sysroot directory names differ from the Rust triples for 32-bit ARM.
  androidSysrootDir = {
    "aarch64-linux-android" = "aarch64-linux-android";
    "armv7-linux-androideabi" = "arm-linux-androideabi";
    "x86_64-linux-android" = "x86_64-linux-android";
  };

  # Windows SDK and CRT, fetched by xwin from Microsoft's CDN. The Visual
  # Studio channel manifest is pinned by its content-addressed URL and names
  # every package with a hash, so the download set is fixed. Fixed-output:
  # the first build reports the hash to put into toolchains.xwin.splatHash.
  vsChannel = pkgs.fetchurl {
    url = toolchains.xwin.channelUrl;
    sha256 = toolchains.xwin.channelSha256;
  };
  xwinSdk = stdenvNoCC.mkDerivation {
    name = "xwin-sdk";
    nativeBuildInputs = [ pkgs.xwin ];
    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash =
      if toolchains.xwin.splatHash == "" then lib.fakeHash else toolchains.xwin.splatHash;
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    buildCommand = ''
      export HOME=$TMPDIR
      # xwin only adds its case-fixing symlinks on case-sensitive file
      # systems, which would make this output differ between hosts. Skip
      # them here; the Windows build generates its own view below. Copy
      # rather than move: the build directory and the store are usually on
      # different file systems, and a rename across them fails.
      xwin --accept-license --arch x86_64 --variant desktop \
        --manifest ${vsChannel} --cache-dir "$TMPDIR/xwin-cache" \
        splat --disable-symlinks --copy --output "$out"
    '';
  };

  targetVariable = target: builtins.replaceStrings [ "-" ] [ "_" ] target;

  # Cargo mixes every dependency's metadata hash into a crate's own, and for
  # build scripts and proc macros, which are compiled for the host, that hash
  # includes rustc's `host:` line. Every crate downstream of one therefore
  # gets a host-dependent symbol hash, which also reorders the emitted code.
  # Cargo reads `rustc -vV` through RUSTC_WRAPPER, so this wrapper answers
  # that one query with a fixed host and is transparent otherwise. The fixed
  # name is a real triple that is never a build target here, so no target
  # configuration can be mistaken for host configuration.
  fixedHost = "x86_64-unknown-linux-musl";
  rustcWrapper = pkgs.writeShellScript "rustc-fixed-host" ''
    if [ "$#" -eq 2 ] && [ "$2" = "-vV" ]; then
      "$1" -vV | sed 's/^host: .*/host: ${fixedHost}/'
      exit "''${PIPESTATUS[0]}"
    fi
    exec "$@"
  '';

  # One derivation per target. The remap flags are computed at build time
  # because the sandbox build directory differs between Linux and macOS.
  mkTarget =
    { target
    , cargoTarget ? target
    , cargoSubcommand ? "build"
    , extraNativeBuildInputs ? [ ]
    , env ? { }
    , cflagPrefix ? "-ffile-prefix-map="
      # No debug info in the C objects: with it, the static libraries carry
      # compiler, include, and object paths that differ between hosts. No
      # compiler identification either: the NDK's clang stamps host-specific
      # build flags into it.
    , extraCflags ? "-g0 -fno-ident"
    , extraRustflags ? [ ]
      # Bash run before the flags are assembled; may append to the
      # extra_rustflags array and the extra_cflags string.
    , setupScript ? ""
    , outputs
    }:
    stdenvNoCC.mkDerivation ({
      name = "hrf-api-${target}";
      src = seraiSrc;
      nativeBuildInputs = [ rust ] ++ extraNativeBuildInputs;
      dontConfigure = true;
      # Fixup would strip and patch the outputs, changing their bytes.
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        export HOME=$TMPDIR
        export XDG_CACHE_HOME=$TMPDIR/cache
        export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
        export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-local
        export CARGO_HOME=$TMPDIR/cargo-home
        mkdir -p "$CARGO_HOME"
        export RUSTC_WRAPPER=${rustcWrapper}
        vendor=$TMPDIR/vendor
        cp -RL ${vendor} "$vendor"
        chmod -R u+w "$vendor"
        printf '[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "%s"\n' \
          "$vendor" > "$CARGO_HOME/config.toml"

        extra_rustflags=(${lib.escapeShellArgs extraRustflags})
        extra_cflags=${lib.escapeShellArg extraCflags}
        ${setupScript}

        # The same remapping hook/rust_build.dart applies, so the embedded
        # source paths read identically to a registry build.
        remaps=("$PWD=${paths.workspace}" "$vendor=${registryPath}")
        rustflags=()
        cflags=()
        for remap in "''${remaps[@]}"; do
          rustflags+=("--remap-path-prefix=$remap")
          cflags+=("${cflagPrefix}$remap")
        done
        rustflags+=("''${extra_rustflags[@]}")
        export CARGO_ENCODED_RUSTFLAGS=$(IFS=$'\x1f'; printf '%s' "''${rustflags[*]}")
        export CFLAGS_${targetVariable target}="''${cflags[*]} $extra_cflags"
        export SOURCE_DATE_EPOCH=0

        cargo ${cargoSubcommand} --locked --offline --release --lib --package ${crate} \
          --target ${cargoTarget} --target-dir "$TMPDIR/target"
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out/lib"
        for name in ${lib.escapeShellArgs outputs}; do
          cp "$TMPDIR/target/${target}/release/$name" "$out/lib/"
        done
        runHook postInstall
      '';
    } // env);

  # Linux: zig provides the C compiler, linker, and a glibc at the floor
  # version, so the result does not depend on the host's toolchain.
  linuxTarget = target: mkTarget {
    inherit target;
    cargoTarget = "${target}.${floors.glibc}";
    cargoSubcommand = "zigbuild";
    extraNativeBuildInputs = [ zig cargoZigbuild ];
    outputs = [ "libhrf_api.so" "libhrf_api.a" ];
  };

  # Android: the pinned NDK's clang at the API floor.
  androidTarget = target:
    let
      ndkTarget = builtins.replaceStrings [ "armv7-" ] [ "armv7a-" ] target;
      cc = "${ndkBin}/${ndkTarget}${toString floors.android}-clang";
      v = targetVariable target;
    in mkTarget {
      inherit target;
      env = {
        "CC_${v}" = cc;
        "CXX_${v}" = "${cc}++";
        "AR_${v}" = "${androidArchiver}";
        "CARGO_TARGET_${lib.toUpper v}_LINKER" = cc;
      };
      # -B makes clang take crtbegin_so.o and crtend_so.o from here first.
      extraRustflags = [ "-Clink-arg=-B${androidCrt}/${androidSysrootDir.${target}}" ];
      outputs = [ "libhrf_api.so" "libhrf_api.a" ];
    };

  # Windows: zig's clang and lld-link against the xwin SDK produce an MSVC-ABI
  # DLL without any Microsoft tool. /Brepro derives the PE timestamp from
  # the content.
  #
  # clang emits an S_OBJNAME CodeView record holding the object's absolute
  # path even with debug info off, and the build directory differs between
  # Linux and macOS sandboxes. This archiver strips the CodeView sections
  # before archiving. Its name contains "llvm-ar" so the cc crate uses
  # ar-style invocation, which stores base names rather than paths.
  windowsArchiver = pkgs.writeShellScript "llvm-ar-without-codeview" ''
    for arg in "$@"; do
      case "$arg" in
        *.o|*.obj)
          ${llvm.llvm}/bin/llvm-objcopy --remove-section='.debug$S' \
            --remove-section='.debug$T' "$arg" ;;
      esac
    done
    # llvm-ar defaults to the host's archive format, which changes member
    # naming and symbol tables and with them the link order; fix it.
    exec ${llvm.llvm}/bin/llvm-ar --format=gnu "$@"
  '';
  # The NDK's llvm-ar has the same host-dependent default.
  androidArchiver = pkgs.writeShellScript "llvm-ar-gnu" ''
    exec ${ndkBin}/llvm-ar --format=gnu "$@"
  '';
  # The C code is compiled by zig's bundled clang rather than nixpkgs'
  # clang-cl: nixpkgs builds LLVM separately per host platform and the two
  # builds emitted different code for the same input, while zig's official
  # binaries produce identical objects on every host, as the Linux targets
  # show. zig spells the target differently from clang, so the wrapper drops
  # the clang-style target the cc crate adds.
  windowsCc = pkgs.writeShellScript "zig-cc-windows-msvc" ''
    args=()
    skip=0
    for a in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$a" in
        --target=*) continue ;;
        -target) skip=1; continue ;;
      esac
      args+=("$a")
    done
    exec ${zig}/bin/zig cc -target x86_64-windows-msvc "''${args[@]}"
  '';
  windowsTarget = target:
    let v = targetVariable target;
    in mkTarget {
      inherit target;
      extraNativeBuildInputs = [ zig llvm.lld llvm.llvm ];
      env = {
        "CC_${v}" = "${windowsCc}";
        "CXX_${v}" = "${windowsCc}";
        "AR_${v}" = "${windowsArchiver}";
        "CARGO_TARGET_${lib.toUpper v}_LINKER" = "lld-link";
      };
      # clang's default for MSVC targets stamps a timestamp into every COFF
      # object for incremental linking; the cc crate disables that for
      # clang-cl with -Brepro but not for a GNU-style driver.
      extraCflags = "-g0 -fno-ident -gno-codeview-command-line -mno-incremental-linker-compatible";
      # No PDB: its content-derived GUID would otherwise land in the DLL.
      extraRustflags = [ "-Clink-arg=/Brepro" "-Clink-arg=/DEBUG:NONE" ];
      # The SDK's headers and import libraries reference each other with
      # casings that differ from the file names, and rustc asks for
      # lowercase import libraries. On a case-sensitive file system that
      # needs symlinks. Build an overlay next to the SDK with every
      # lowercase name plus every casing an #include directive uses, and
      # search both. The overlay is derived purely from the SDK contents.
      setupScript = ''
        sdk=${xwinSdk}
        overlay=$TMPDIR/xwin-overlay
        include_dirs="crt/include sdk/include/ucrt sdk/include/um sdk/include/shared"
        lib_dirs="crt/lib/x86_64 sdk/lib/um/x86_64 sdk/lib/ucrt/x86_64"
        for dir in $include_dirs $lib_dirs; do
          mkdir -p "$overlay/$dir"
          for file in "$sdk/$dir"/*; do
            printf 'file\t%s\t%s\n' "$dir" "''${file##*/}"
          done
        done > "$TMPDIR/xwin-files"
        grep -rhoE '^[[:space:]]*#[[:space:]]*include[[:space:]]*[<"][^>"]+[>"]' \
          $(printf "$sdk/%s " $include_dirs) > "$TMPDIR/xwin-refs" || true
        # Emit "dir, link name, file name" for every lowercase alias and for
        # every casing an #include directive uses that differs from the file.
        awk -F'\t' -v dirs="$include_dirs" '
          BEGIN { n = split(dirs, include, " ") }
          $1 == "file" {
            name[$2 "/" tolower($3)] = $3
            if ($3 != tolower($3)) print $2 "\t" tolower($3) "\t" $3
          }
          /^[[:space:]]*#/ && match($0, /[<"][^>"]+[>"]/) {
            base = substr($0, RSTART + 1, RLENGTH - 2)
            sub(/.*\//, "", base)
            for (i = 1; i <= n; i++) {
              key = include[i] "/" tolower(base)
              if (key in name && name[key] != base) print include[i] "\t" base "\t" name[key]
            }
          }
        ' "$TMPDIR/xwin-files" "$TMPDIR/xwin-refs" | sort -u \
          | while IFS=$'\t' read -r dir link file; do
          [ -e "$overlay/$dir/$link" ] || ln -s "$sdk/$dir/$file" "$overlay/$dir/$link"
        done
        for dir in $include_dirs; do
          extra_cflags+=" -isystem $sdk/$dir -isystem $overlay/$dir"
        done
        for dir in $lib_dirs; do
          extra_rustflags+=("-Lnative=$sdk/$dir" "-Lnative=$overlay/$dir")
        done
      '';
      outputs = [ "hrf_api.dll" "hrf_api.dll.lib" "hrf_api.lib" ];
    };

  targetPackages = lib.genAttrs pureTargets (target:
    if lib.elem target linuxTargets then linuxTarget target
    else if lib.elem target androidTargets then androidTarget target
    else windowsTarget target);

  # Every pure target this host can build, plus a SHA256SUMS to diff against
  # another host's.
  all = pkgs.runCommand "hrf-api-all" { } ''
    ${lib.concatMapStringsSep "\n" (target: ''
      mkdir -p "$out/${target}"
      cp ${targetPackages.${target}}/lib/* "$out/${target}/"
    '') pureTargets}
    cd "$out"
    find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS
  '';
in
{
  packages = targetPackages // {
    inherit vendor all;
    xwin-sdk = xwinSdk;
    default = all;
  };
  devShells = {
    default = pkgs.mkShellNoCC {
      packages = [ rust zig cargoZigbuild pkgs.jq ];
    };
  } // lib.optionalAttrs isDarwin {
    # No C compiler from nixpkgs: Apple targets must link with Xcode's.
    apple = pkgs.mkShellNoCC {
      packages = [ rust pkgs.jq pkgs.rsync ];
      # The same fixed host as the pure derivations, so crate metadata does
      # not depend on the Mac that builds.
      RUSTC_WRAPPER = rustcWrapper;
    };
  };
}
