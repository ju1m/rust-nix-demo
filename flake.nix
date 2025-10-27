{
  description = "A project";

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
    # An alternative is fenix:
    # https://github.com/nix-community/fenix/issues/78#issuecomment-1231779412
    rust-overlay = {
      url = "github:oxalica/rust-overlay/stable";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # cargo2nix generate many Nix packages (one per dependent Rust crate),
    # instead of a single Nix package (for all the dependent Rust crates).
    # See comparison here: https://nixos.wiki/wiki/Rust#Packaging_Rust_projects_with_nix
    #
    # MaintenanceWarning: rust/Cargo.nix MUST be regenerated
    # after each change to rust/Cargo.{toml,lock} by using:
    #
    # (cd rust && cargo2nix)
    #
    cargo2nix = {
      url = "github:cargo2nix/cargo2nix/release-0.12";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
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
              rustVersion = "1.83.0";
              packageFun = import rust/Cargo.nix;

              # MaintenanceNote: can be set to use fenix instead of rust-overlay.
              # rustToolchain =

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
              inputs.cargo2nix.packages.${system}.default

              # ToDo: add something using this
              pkgs.nodejs_22
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
