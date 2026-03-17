{
  description = "Redis flake build from GitHub";

  # USAGE GUIDE:
  #
  # 1. Run Redis server:
  #    nix run github:mainmatter/redis-flake
  #
  # 2. Run Redis CLI:
  #    nix run github:mainmatter/redis-flake#redis-cli
  #
  # 3. Development shell with Redis available:
  #    nix develop github:mainmatter/redis-flake
  #
  # 4. Use as dependency in another flake:
  #    # In your flake.nix:
  #    inputs = {
  #      nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  #
  #      # Basic usage - use the default (unstable) Redis version
  #      redis-flake = {
  #        url = "github:mainmatter/redis-flake";
  #        inputs.nixpkgs.follows = "nixpkgs";
  #      };
  #
  #      # OR: Override the Redis source in this flake to use a specific version
  #      redis-flake = {
  #        url = "github:mainmatter/redis-flake";
  #        inputs.nixpkgs.follows = "nixpkgs";
  #        inputs.redis.url = "github:redis/redis/7.4.2"; # Specific stable version
  #      };
  #    };
  #
  #    outputs = { self, nixpkgs, redis-flake }: {
  #      # Access the Redis package:
  #      packages.x86_64-linux.myPackage = redis-flake.packages.x86_64-linux.redis;
  #    };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # SOURCE CUSTOMIZATION:
    # Change this URL to use a different Redis version:
    # - For specific tag: "github:redis/redis/8.0.0"
    # - For specific commit: "github:redis/redis/abcdef123456789"
    # - For local source: use inputs.redis.url = "/path/to/local/redis";
    redis = {
      url = "github:redis/redis/unstable";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, redis }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Extract the Redis version from source code
        redisVersion = let
          versionFile = builtins.readFile "${redis}/src/version.h";
          versionMatch = builtins.match ".*#define REDIS_VERSION \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*" versionFile;
        in if versionMatch != null then builtins.elemAt versionMatch 0 else "unknown";

        # Create a customized Redis package
        customRedis = pkgs.redis.overrideAttrs (oldAttrs: {
          src = redis;
          version = redisVersion;

          # Don't run the tests because unstable might fail
          doCheck = false;
        });
      in {
        packages = {
          redis = customRedis;
          default = self.packages.${system}.redis;
        };

        # APPLICATIONS:
        # These define runnable applications in this flake.
        # Access with: nix run github:mainmatter/redis-flake#<app-name>
        apps = {
          redis = flake-utils.lib.mkApp {
            drv = self.packages.${system}.redis;
            name = "redis-server";
            exePath = "/bin/redis-server";
          };

          redis-cli = flake-utils.lib.mkApp {
            drv = self.packages.${system}.redis;
            name = "redis-cli";
            exePath = "/bin/redis-cli";
          };

          default = self.apps.${system}.redis;
        };
      }
    );
}
