{
  description = "A project";

  # MaintenanceOpinion:
  # https://devenv.sh/blog/2025/08/22/closing-the-nix-gap-from-environments-to-packaged-applications-for-rust/
  #
  # > Developers don't want to compare crate2nix vs cargo2nix vs naersk vs crane—they want a tested solution that works.
  # > devenv now provides languages.rust.import, which packages Rust applications using crate2nix.
  # > We evaluated the available tools and chose crate2nix, so you don't have to.
  # > We've done this before. In PR #1500, we replaced fenix with rust-overlay for Rust toolchains
  # > because rust-overlay was better maintained.

  inputs = {
    # Reuse the host's nixpkgs in (nix registry list)
    # when updating with: nix flake update nixpkgs
    nixpkgs.url = "flake:nixpkgs";

    # git-hooks provides Git pre-commit hooks
    # to check files before committing.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # rust-overlay provides a specific Rust toolchain version
    # downloaded from Rust's cache.
    #
    #rust-overlay = {
    #  url = "github:oxalica/rust-overlay/stable";
    #  inputs.nixpkgs.follows = "nixpkgs";
    #};

    # An alternative to rust-overlay is fenix:
    # https://github.com/nix-community/fenix/issues/78#issuecomment-1231779412
    #fenix.url = "github:nix-community/fenix";

    # cargo2nix generates many Nix packages (one per dependent Rust crate),
    # instead of a single Nix package (for all the dependent Rust crates).
    # See comparison here: https://nixos.wiki/wiki/Rust#Packaging_Rust_projects_with_nix
    # This avoids rebuilding crates that do not need to,
    # and enables some opportunistic sharing with other projects using the same Nix store.
    # It does not however populate the rust/target/ directory when using `cargo` manually,
    # and the artifacts are built in `release` mode, not `debug` mode,
    # So cargo would rebuild them anyway.
    #
    # MaintenanceWarning: rust/Cargo.nix MUST be regenerated
    # after each change to rust/Cargo.{toml,lock} by using:
    #
    # (cd rust && cargo2nix)
    #
    cargo2nix = {
      url = "github:cargo2nix/cargo2nix/release-0.12";
      inputs.nixpkgs.follows = "nixpkgs";
      #inputs.rust-overlay.follows = "rust-overlay";
    };
  };

  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;
      foreachSystem =
        doWithArgs:
        lib.genAttrs lib.systems.flakeExposed (
          system:
          doWithArgs rec {
            inherit system;
            pkgs = import inputs.nixpkgs {
              inherit system;
              config = {
              };
              overlays = [
                inputs.cargo2nix.overlays.default
              ];
            };
            # Create the workspace & dependencies package set
            rustPkgs = pkgs.rustBuilder.makePackageSet {
              # MaintenanceNote: currently is the same version
              # as the one used by cargo2nix.
              rustVersion = pkgs.rustPlatform.rustc.version;
              packageFun = import rust/Cargo.nix;

              # Using Nixpkgs' rustToolchain
              rustToolchain =
                pkgs.symlinkJoin {
                  name = "rust-toolchain";
                  paths = [
                    pkgs.cargo
                    pkgs.rustc
                  ];
                }
                // {
                  inherit (pkgs.rustc) version;
                };
              # Using fenix rustToolchain
              /*
                rustToolchain =
                  with inputs.fenix.packages.x86_64-linux;
                  combine [
                    default.cargo
                    default.rustc
                    default.clippy
                    #targets.${target}.latest.rust-std
                  ]
                  // {
                    inherit (default.rustc.version) version;
                  };
              */

              # Filter-in only required files to build the package.
              # This is currently no better than ./rust
              workspaceSrc =
                with lib.fileset;
                toSource {
                  root = ./rust;
                  fileset = unions [
                    rust/Cargo.lock
                    rust/Cargo.toml
                    (fileFilter (file: lib.any file.hasExt [ "rs" ]) ./rust/src)
                  ];
                };
            };
          }
        );
    in
    {
      # nix -L build
      packages = foreachSystem (
        args: with args; rec {
          hello-world = rustPkgs.workspace.hello-world { };
          default = hello-world;
        }
      );

      # nix -L develop
      devShells = foreachSystem (
        args: with args; {
          default = pkgs.mkShell {
            inputsFrom = [
              inputs.self.packages.${system}.default
            ];
            nativeBuildInputs = [
              # Provides the cargo2nix executable
              inputs.cargo2nix.packages.${system}.cargo2nix
            ];
            shellHook = ''
              ${inputs.self.checks.${system}.git-hooks-check.shellHook}
            '';
          };
        }
      );

      # nix flake check
      checks = foreachSystem (
        args: with args; {
          git-hooks-check = inputs.git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt-rfc-style.enable = true;
              rustfmt.enable = true;
              reuse = {
                enable = true;
                entry = "${pkgs.reuse}/bin/reuse lint";
                pass_filenames = false;
              };
            };
          };
        }
      );

      # nix fmt
      formatter = foreachSystem (
        args:
        with args;
        let
          config = inputs.self.checks.${system}.git-hooks-check.config;
          inherit (config) package configFile;
          script = ''
            ${lib.getExe package} run --all-files --config ${configFile}
          '';
        in
        pkgs.writeShellScriptBin "pre-commit-run" script
      );
    };

}
