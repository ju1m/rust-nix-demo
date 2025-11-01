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
    # when updating with:
    #   nix flake update nixpkgs
    # Override to a specific version with:
    #   nix flake update --override-input nixpkgs github:NixOS/nixpkgs/f34483be5ee2418a563545a56743b7b59c549935
    nixpkgs.url = "flake:nixpkgs";

    # git-hooks provides Git pre-commit hooks
    # to check files before committing.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # DependencyAlternative:
    # rust-overlay provides a specific rustToolchain
    # downloaded from Rust's cache instead of cache.nixos.org.
    #
    #rust-overlay = {
    #  url = "github:oxalica/rust-overlay/stable";
    #  inputs.nixpkgs.follows = "nixpkgs";
    #};

    # DependencyAlternative:
    # fenix is yet another way to provide rustToolchain:
    # > rust-overlay is bigger in size and includes all the manifests in the past
    # > fenix requires sha256 for older toolchains and depends on IFD (import-from-derivation)
    # > for things like fromToolchainFile, but is a lot smaller in size
    # https://github.com/nix-community/fenix/issues/78#issuecomment-1231779412
    #fenix.url = "github:nix-community/fenix";

    # cargo2nix generates many Nix packages (one per dependent Rust crate),
    # instead of a single Nix package (for all the dependent Rust crates).
    # See comparison here: https://nixos.wiki/wiki/Rust#Packaging_Rust_projects_with_nix
    # This avoids rebuilding crates that do not need to,
    # and enables some opportunistic sharing with other projects using the same Nix store.
    #
    # ResourceSpaceWarning:
    # cargo2nix does not populate the rust/target/ directory or provide `cargo` with the crates,
    # besides by default the artifacts are built in `release` mode, not `debug` mode
    # so cargo would rebuild them anyway.
    #
    # MaintenanceWarning: rust/Cargo.nix MUST be regenerated
    # after each change to rust/Cargo.{toml,lock},
    # this is done when entering the shell (see shellHook below).
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
              packageFun = import rust/Cargo.nix;
              #release = false;

              # Using Nixpkgs' rustToolchain
              # because it's more likely to already be on the local Nix store.
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

              # DependencyAlternative: using rust-overlay's rustToolchain
              # rustVersion = "1.86.0";

              # DependencyAlternative: using fenix's rustToolchain
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
          inherit rustPkgs;
          hello-world = rustPkgs.workspace.hello-world { };
          default = hello-world;
        }
      );

      # nix -L develop
      devShells = foreachSystem (
        args: with args; {

          # UsageExplanation:
          # workspaceShell provides the project's dependencies and environment settings
          # necessary for a regular `cargo build`.
          # It does not however provision dependent crates' built artifacts in $NIX_RUST_LINK_FLAGS
          # therefore `cargo build` will download and build crates in rust/target.
          default = rustPkgs.workspaceShell {
            nativeBuildInputs = [
              inputs.cargo2nix.packages.${system}.cargo2nix
            ];
            shellHook = ''
              ${inputs.self.checks.${system}.git-hooks-check.shellHook}

              # CodeExplanation: update Cargo.nix
              # when Cargo.lock has a newer modification time.
              if test rust/Cargo.lock -nt rust/Cargo.nix; then
                echo 2>/dev/null "$(tput rev)Updating rust/Cargo.nix$(tput sgr0)"
                (cd rust && cargo2nix --overwrite --locked)
              fi
            '';
          };

          # UsageAlternative:
          # This alternative shell is only useful to:
          # 1. Avoid downloading dependent crates twice (in nix store and in cargo's store).
          # 2. Debug in the exact same environment as nix builds the project.

          # UsageExplanation:
          # Contrary to the default shell,
          # this shell provisions dependent crates using nix
          # instead of letting cargo download them.
          # Unfortunately this has the side effect to overwrite Cargo.{toml,lock}.
          # To enter the shell with:
          #   nix -L develop .#provision-cargo
          # To rebuild (cargo build):
          #   runHook runCargo
          provision-cargo =
            (inputs.self.packages.${system}.hello-world.override (previousArgs: {
              # Increase cargoVerbosityLevel
              # and print $NIX_RUST_LINK_FLAGS and $NIX_RUST_BUILD_FLAGS
              NIX_DEBUG = 1;
            })).shell.overrideAttrs
              (previousAttrs: {
                shellHook = ''
                  cd rust
                  RUST_DIR="$PWD"
                  exitHook () {
                    cd "$RUST_DIR"
                    rm -rf build_deps .cargo .cargo-build-output deps invoke.log target
                    mv -v Cargo.original.lock Cargo.lock
                    mv -v Cargo.original.nix Cargo.nix
                    mv -v Cargo.original.toml Cargo.toml
                  }
                  trap exitHook EXIT

                  echo 2>/dev/null "$(tput rev)This Nix shell needs to overwrite Cargo.{toml,lock}.$(tput sgr0)"
                  echo 2>/dev/null "Use Ctrl-C to interrupt or any other key to continue"
                  read

                  cp -f Cargo.lock Cargo.original.lock
                  cp -f Cargo.nix Cargo.original.nix
                  eval "$configurePhase"

                  # This overrides your .cargo folder, e.g. for setting cross-compilers 
                  runHook overrideCargoManifest
                  # This sets up linker flags for the `rustc` invocations
                  runHook setBuildEnv

                  echo 2>/dev/null "$(tput rev)To run cargo build$(tput sgr0): runHook runCargo"
                '';
              });
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
