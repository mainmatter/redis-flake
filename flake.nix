{
  description = "Redis flake build from GitHub";

  # USAGE GUIDE:
  #
  # 1. Run Redis server:
  #    nix run github:chesedo/redis-flake
  #
  # 2. Run Redis CLI:
  #    nix run github:chesedo/redis-flake#redis-cli
  #
  # 3. Development shell with Redis available:
  #    nix develop github:chesedo/redis-flake
  #
  # 4. Use as dependency in another flake:
  #    # In your flake.nix:
  #    inputs = {
  #      nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  #
  #      # Basic usage - use the default (unstable) Redis version
  #      redis-flake = {
  #        url = "github:chesedo/redis-flake";
  #        inputs.nixpkgs.follows = "nixpkgs";
  #      };
  #
  #      # OR: Override the Redis source in this flake to use a specific version
  #      redis-flake = {
  #        url = "github:chesedo/redis-flake";
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
      url = "git+ssh://git@github.com/redislabsdev/Redis.git?ref=rsd_big2_8.4";
      flake = false;
    };

    # SPEEDB DEPENDENCY:
    # This Redis Labs fork requires speedb (a RocksDB fork) as a submodule dependency
    # for its block storage drivers (bs_speedb.so). The Makefile expects speedb to be
    # in ../speedb/ relative to the src/ directory. We fetch it as a separate flake input
    # instead of using git submodules because:
    # 1. Nix flake inputs don't preserve git submodule information
    # 2. This approach gives us more control over the speedb version
    # 3. We can copy speedb to a writable location during the build
    speedb = {
      url = "git+ssh://git@github.com/redislabsdev/speedb-ent?rev=4b8b34b8c290da817a34a37c1cc821d0ccd13e4b";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, redis, speedb }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Extract the Redis version from source code
        redisVersion = let
          versionFile = builtins.readFile "${redis}/src/version.h";
          versionMatch = builtins.match ".*#define REDIS_VERSION \"([0-9]+\\.[0-9]+\\.[0-9]+)\".*" versionFile;
        in if versionMatch != null then builtins.elemAt versionMatch 0 else "unknown";

        # Create a customized Redis package
        # This Redis Labs fork (rl_big2_8.0 branch) has custom block storage drivers
        # (bs_dummy.so and bs_speedb.so) that require special build configuration
        customRedis = pkgs.redis.overrideAttrs (oldAttrs: {
          src = redis;
          version = redisVersion;

          # Don't run the tests because unstable might fail
          doCheck = false;

          # DEPENDENCY: zlib
          # Required for compilation of this Redis fork
          buildInputs = (oldAttrs.buildInputs or []) ++ [ pkgs.zlib pkgs.liburing ];

          # BUILD TOOLS:
          # - cmake: Required to build the speedb dependency (a RocksDB fork)
          # - makeBinaryWrapper: Needed to wrap binaries with LD_LIBRARY_PATH in postInstall
          nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ [ pkgs.cmake pkgs.makeBinaryWrapper ];

          # CMAKE CONFIGURATION:
          # Disable cmake's automatic configure phase because Redis itself uses Make, not CMake.
          # We only need cmake available in PATH to build the speedb submodule dependency.
          # Without this flag, Nix would try to run cmake on the Redis source and fail.
          dontUseCmakeConfigure = true;

          # SPEEDB DEPENDENCY SETUP:
          # The Redis Labs Makefile expects speedb to be in ../speedb (relative to src/).
          # We need to copy (not symlink) speedb because:
          # 1. The build process needs to create speedb/build/ directory for cmake output
          # 2. Nix store paths are read-only, so we can't create directories in a symlink target
          # 3. chmod -R u+w is needed because files copied from Nix store are read-only by default
          preBuild = ''
            # Create speedb directory and link the speedb source
            rm -rf speedb/
            cp -r ${speedb} speedb
            chmod -R u+w speedb

            # Patch Redis src/Makefile: replace static liburing link with dynamic
            sed -i 's/-l:liburing\.a/-luring/g' src/Makefile

            # Patch speedb's Finduring.cmake to search for "uring" instead of "liburing.a"
            # "liburing.a" doesn't exist in Nix - only the dynamic library is available
            # Inspired by https://github.com/NixOS/nixpkgs/blob/44bae273f9f82d480273bab26f5c50de3724f52f/pkgs/by-name/ro/rocksdb/package.nix#L32-L34
            sed -i 's/NAMES liburing\.a liburing/NAMES uring/' speedb/cmake/modules/Finduring.cmake

            # Patch speedb header to include cstdint
            # This is only temporarily needed until the speedb source is fixed upstream
            sed -i '1i #include <cstdint>' speedb/db/blob/blob_file_meta.h
            sed -i '1i #include <cstdint>' speedb/include/rocksdb/trace_record.h
          '';

          # LIBRARY DIRECTORY CREATION:
          # The Redis Labs Makefile installs block storage driver .so files to $PREFIX/lib/
          # via this loop in the Makefile (line 666):
          #   for driver in $(BIGSTORE_LIBS:.so=); do 
          #     install $$driver.so $(REDIS_INSTALL_LIBRARY_PATH)/$$driver$(BIN_SUFFIX).so
          #   done
          # Where BIGSTORE_LIBS = bs_dummy.so bs_speedb.so
          # The lib directory doesn't exist by default, causing install to fail with:
          # "cannot create regular file '/nix/store/.../lib/bs_dummy.so': No such file or directory"
          preInstall = ''
            mkdir -p $out/lib
          '';

          # LD_LIBRARY_PATH CONFIGURATION:
          # The block storage driver .so files are installed to $out/lib and need to be
          # found at runtime by the Redis binaries. We wrap each binary to add $out/lib
          # to LD_LIBRARY_PATH so the dynamic linker can find bs_dummy.so and bs_speedb.so.
          postInstall = ''
            for bin in $out/bin/*; do
              wrapProgram $bin --prefix LD_LIBRARY_PATH : $out/lib
            done
          '';
        });
      in {
        packages = {
          redis = customRedis;
          default = self.packages.${system}.redis;
        };

        # APPLICATIONS:
        # These define runnable applications in this flake.
        # Access with: nix run github:chesedo/redis-flake#<app-name>
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
