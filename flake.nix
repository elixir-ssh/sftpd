{
  description = "Development environment for sftp-s3";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {inherit system;};
        lib = pkgs.lib;

        toolVersions =
          builtins.listToAttrs
          (builtins.filter
            (entry: entry != null)
            (map (
                line: let
                  parts = builtins.filter (part: part != "") (lib.splitString " " line);
                in
                  if builtins.length parts >= 2
                  then {
                    name = builtins.elemAt parts 0;
                    value = builtins.elemAt parts 1;
                  }
                  else null
              )
              (lib.splitString "\n" (builtins.readFile ./.tool-versions))));

        erlangMajor = builtins.elemAt (lib.splitString "." toolVersions.erlang) 0;
        elixirVersion = builtins.elemAt (lib.splitString "-otp-" toolVersions.elixir) 0;
        elixirParts = lib.splitString "." elixirVersion;
        elixirMajorMinor = "${builtins.elemAt elixirParts 0}_${builtins.elemAt elixirParts 1}";

        beamPackages = pkgs.beam.packages."erlang_${erlangMajor}";
        erlang = let
          package = beamPackages.erlang;
        in
          assert package.version == toolVersions.erlang; package;
        elixir = let
          package = beamPackages."elixir_${elixirMajorMinor}";
        in
          assert package.version == elixirVersion; package;
        rebar3 = beamPackages.rebar3.overrideAttrs (old: {
          doCheck = false;
          postPatch =
            (old.postPatch or "")
            + ''
              for file in \
                rebar.config \
                apps/rebar/rebar.config \
                vendor/erlware_commons/rebar.config \
                vendor/bbmustache/rebar.config \
                vendor/relx/rebar.config
              do
                substituteInPlace "$file" \
                  --replace-fail "warnings_as_errors" "nowarn_export_var_subexpr, nowarn_match_alias_pats, warnings_as_errors"
              done
            '';
        });
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs =
            [
              erlang
              elixir
              beamPackages.hex
              beamPackages.rebar
              rebar3
              beamPackages.rebar3-nix
              pkgs.git
              pkgs.gh
              pkgs.cspell
              pkgs.alejandra
              pkgs.nil
            ]
            ++ lib.optional pkgs.stdenv.isLinux pkgs.libnotify
            ++ lib.optional pkgs.stdenv.isLinux pkgs.inotify-tools
            ++ lib.optional pkgs.stdenv.isDarwin pkgs.terminal-notifier
            ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs.darwin.apple_sdk.frameworks; [CoreFoundation CoreServices]);
          shellHook = ''
            gh auth switch --user mjc
            export ERL_AFLAGS="-kernel shell_history enabled"
          '';
        };
      }
    );
}
