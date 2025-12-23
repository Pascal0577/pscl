{
    description = "Example flake with a devShell";

    inputs.nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    outputs = { self, nixpkgs}:
    let
        system = "x86_64-linux";
        pkgs = import nixpkgs { inherit system; };
    in {
        devShells.x86_64-linux.default = pkgs.mkShellNoCC {
            buildInputs = with pkgs; [
                gcc15
                wget
                python312
                pkg-config
            ];
            PYTHON = "${pkgs.python312}/bin/python3";
            shellHook = ''
                echo "Welcome to the devShell!"
                export SHELL="${pkgs.zsh}/bin/zsh"
                export MAKEFLAGS="-j$(nproc)"
                exec ${pkgs.zsh}/bin/zsh
            '';
        };
    };
}
