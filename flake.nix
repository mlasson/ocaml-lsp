{
  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    opam-nix = {
      url = "github:tweag/opam-nix";
      inputs.opam-repository.follows = "opam-repository";
    };
    opam-repository = {
      url = "github:ocaml/opam-repository";
      flake = false;
    };
  };

  outputs = { self, flake-utils, opam-nix, opam-repository, nixpkgs, ... }@inputs:
    let
      package = "ocaml-lsp-server";
      overlay = final: prev: {
        ${package} = prev.${package}.overrideAttrs (_: {
          # Do not add share/nix-support, so that dependencies from
          # the scope don't leak into dependent derivations
          doNixSupport = false;
        });
        dune-release = prev.dune-release.overrideAttrs (_: {
          doCheck = false;
        });
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { overlays = [ overlay ]; inherit system; };
        on = opam-nix.lib.${system};
        localPackages = {
          jsonrpc = "*";
          lsp = "*";
          ocaml-lsp-server = "*";
        };
        devPackages = {
          menhir = "*";
          ppx_yojson_conv = "*";
          cinaps = "*";
          ppx_expect = "*";
          ocamlfind = "1.9.2";
        };
        packagesFromNames = set:
          (builtins.map (s: builtins.getAttr s scope)
            (builtins.attrNames set));
        allPackages = localPackages // devPackages;
        scope =
          (
            let
              scope =
                on.buildOpamProject
                  {
                    repos = [ opam-repository ];
                    inherit pkgs;
                    resolveArgs = { with-test = true; };
                  }
                  package
                  ./.
                  (allPackages);
            in
            scope.overrideScope' overlay
          );
      in
      {
        packages =
          (nixpkgs.lib.filterAttrs (name: value: builtins.hasAttr name localPackages) scope) //
          { default = self.packages.${system}.${package}; };

        devShell =
          pkgs.mkShell {
            buildInputs = (with pkgs;
              [
                # dev tools
                ocamlformat_0_24_1
                yarn
                dune-release
              ]) ++ packagesFromNames devPackages;
            inputsFrom = [ self.packages.${system}.default ]
              ++ packagesFromNames localPackages;
          };
      });
}
