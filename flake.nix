{

  description = "A Python project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        python = pkgs.python312;
        preCommitCheck = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            gitleaks = {
              enable = true;
              name = "gitleaks";
              entry = "${pkgs.lib.getExe pkgs.gitleaks} git --pre-commit --redact --staged --verbose";
              language = "system";
              pass_filenames = false;
            };
          };
        };
      in
      {
        checks.pre-commit-check = preCommitCheck;

        devShells.default = pkgs.mkShell {
          packages = (with pkgs; [
            python
            uv
            go-task
            gh
            fd
            gnused
            gitleaks
            opentofu
            (google-cloud-sdk.withExtraComponents [
              google-cloud-sdk.components.gke-gcloud-auth-plugin
            ])
            kubectl
            kubernetes-helm
            kustomize
            postgresql_16
            docker_29
            docker-compose
            jq
            yq-go
            curl
            shellcheck
          ]) ++ preCommitCheck.enabledPackages;

          shellHook = ''
            ${preCommitCheck.shellHook}

            echo "Python development environment ready"
            echo "Python version: $(python --version)"
            echo "uv version: $(uv --version)"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
            echo "Gitleaks version: $(gitleaks version 2>/dev/null || echo 'not available')"
            echo "OpenTofu version: $(tofu version 2>/dev/null | head -n 1 || echo 'not available')"
            echo "gcloud version: $(gcloud version 2>/dev/null | head -n 1 || echo 'not available')"
            echo "kubectl version: $(kubectl version --client=true 2>/dev/null | head -n 1 || echo 'not available')"
            echo "helm version: $(helm version --short 2>/dev/null || echo 'not available')"
            echo "kustomize version: $(kustomize version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
