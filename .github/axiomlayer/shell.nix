{ system ? builtins.currentSystem }:

let
  nixpkgs = builtins.fetchGit {
    url = "https://github.com/NixOS/nixpkgs.git";
    ref = "nixos-26.05";
    rev = "c3eea5b2156db11c7eeeada3dc737711255b253e";
    shallow = true;
  };
  pkgs = import nixpkgs { inherit system; };
in
pkgs.mkShellNoCC {
  packages = with pkgs; [
    bash
    cacert
    coreutils
    curl
    git
    gnutar
    gzip
    jq
    openssl
    ripgrep
    unzip
  ];
}
