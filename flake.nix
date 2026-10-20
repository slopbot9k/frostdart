{
  description = "Reproducible reference builds of frostdart's Rust library (hrf-api)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Official Rust releases, fetched by hash rather than built from source.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Official zig releases, same reasoning.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, zig-overlay }:
    let
      settings = builtins.fromJSON (builtins.readFile ./build-config.json);
      # nixpkgs unstable no longer supports x86_64-darwin as a host. The
      # x86_64 macOS target is still built, from an Apple Silicon host.
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system:
        f (import ./nix/hrf-api.nix {
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
            config = {
              # The Android NDK carries Google's SDK license.
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          zig = zig-overlay.packages.${system}.${settings.toolchains.zig};
          inherit settings;
          src = ./src/serai;
        }));
    in {
      packages = forEachSystem (hrf: hrf.packages);
      devShells = forEachSystem (hrf: hrf.devShells);
    };
}
