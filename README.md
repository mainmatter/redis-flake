# Redis Flake

A simple Nix flake that builds Redis from GitHub or local sources.

## Features

- Builds Redis from upstream GitHub repository
- Provides both Redis server and CLI
- Configurable Redis version
- Works as a dependency in other flakes

## Usage

### Run Redis Server

```
nix run github:mainmatter/redis-flake
```

### Run Redis CLI

```
nix run github:mainmatter/redis-flake#redis-cli
```

## Using as a Dependency

Add to your `flake.nix`:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  
  # Default version (unstable branch)
  redis-flake = {
    url = "github:mainmatter/redis-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};

outputs = { self, nixpkgs, redis-flake }: {
  # Use Redis in your packages
  packages.x86_64-linux.default = redis-flake.packages.x86_64-linux.redis;
};
```

## Customizing Redis Version

To use a specific Redis version, override the `redis` input:

```nix
redis-flake = {
  url = "github:mainmatter/redis-flake";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.redis.url = "github:redis/redis/7.4.2";  # Use stable 7.4.2
};
```

## License

Same as Nix and Redis.
imple flake to compile a custom Redis from source
