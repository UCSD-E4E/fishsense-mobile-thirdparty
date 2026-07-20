{
  description = "Build environment for FishSense mobile third-party frameworks (OpenCV + ONNX Runtime)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pinned only for CMake: nixos-unstable ships CMake 4.x, whose Xcode-generator
    # compiler-id detection returns "unknown" with OpenCV's iOS toolchain file on
    # recent Xcode, tripping OpenCV's "requires C++11" gate. CMake 3.30 (this
    # channel) configures OpenCV + ONNX Runtime cleanly. Bump when unstable's
    # CMake works with the Apple toolchains again.
    nixpkgs-cmake.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-cmake, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

        # CMake 3.x from the pinned channel (see nixpkgs-cmake input above).
        cmakePinned = (import nixpkgs-cmake { inherit system; }).cmake;

        isDarwin = pkgs.stdenv.isDarwin;

        # Python + the build-time modules the ONNX Runtime build imports directly
        # (schema/codegen steps). These come from onnxruntime/requirements.txt
        # (flatbuffers, numpy, protobuf, sympy, packaging). Bundling them here
        # means no venv / `pip install` step — the ONNX build.py only pip-installs
        # behind flags we don't use, so an immutable Nix interpreter is fine.
        # OpenCV's Apple build needs only the interpreter itself.
        pythonEnv = pkgs.python313.withPackages (ps: with ps; [
          flatbuffers
          numpy
          protobuf
          sympy
          packaging
          setuptools
          wheel
          pip
        ]);

        # Host tooling common to every target. The heavy lifting is done by the
        # upstream build scripts, which drive CMake themselves — we pin the tools
        # that invoke them. This is the set you were installing with Homebrew.
        commonTooling = [
          pythonEnv
          cmakePinned      # 3.x — see nixpkgs-cmake input (4.x breaks Apple builds)
          pkgs.ninja       # default CMake generator (non-Xcode paths / Android)
          pkgs.git         # submodules + FetchContent
          pkgs.pkg-config
          pkgs.coreutils   # scripts assume GNU coreutils (realpath, etc.)
        ];

        # ---- Android toolchain (future work) ----------------------------------
        # NDK/SDK genuinely live in nixpkgs (unlike Xcode), so this path can be
        # made fully hermetic. onnxruntime's build.py wants
        # <ndk>/build/cmake/android.toolchain.cmake; ANDROID_NDK_ROOT points there.
        # Pin these versions to whatever OpenCV / ONNX Runtime require when the
        # Android build actually lands.
        androidComposition = pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ "34" ];
          buildToolsVersions = [ "34.0.0" ];
          includeNDK = true;
          ndkVersions = [ "26.3.11579264" ];
          cmakeVersions = [ "3.22.1" ];
        };
        androidSdk = androidComposition.androidsdk;
        androidSdkRoot = "${androidSdk}/libexec/android-sdk";
      in
      {
        devShells = {
          # `nix develop` — the iOS / default environment. Xcode itself stays
          # outside Nix (Apple licensing); you bring that. Everything else the
          # Apple build scripts need is pinned here.
          #
          # IMPORTANT: use mkShellNoCC, not mkShell. On Darwin, mkShell pulls in
          # the C-compiler stdenv, which injects DEVELOPER_DIR + an `xcrun` stub
          # that shadow the real Xcode toolchain and break the iOS build. The
          # NoCC shell leaves the system Xcode (xcrun/xcodebuild/xcode-select)
          # fully intact while still pinning cmake/python/etc.
          default = pkgs.mkShellNoCC {
            packages = commonTooling;

            shellHook = ''
              echo "fishsense-mobile-thirdparty dev shell (iOS / default)"
              echo "  python : $(python3 --version 2>&1)  (flatbuffers/numpy/protobuf/sympy bundled)"
              echo "  cmake  : $(cmake --version | head -n1)"
            '' + pkgs.lib.optionalString isDarwin ''
              if xcode-select -p >/dev/null 2>&1; then
                echo "  xcode  : $(xcode-select -p)"
              else
                echo "  xcode  : NOT FOUND — install Xcode from the App Store"
              fi
            '' + ''
              echo ""
              echo "Init submodules: git submodule update --init --recursive"
            '';
          };

          # `nix develop .#android` — scaffolded for the future Android build.
          # Also NoCC: the NDK ships its own clang toolchain, so we don't want
          # the host cc-wrapper on PATH competing with it.
          android = pkgs.mkShellNoCC {
            packages = commonTooling ++ [ androidSdk pkgs.jdk17 ];

            ANDROID_HOME = androidSdkRoot;
            ANDROID_SDK_ROOT = androidSdkRoot;
            ANDROID_NDK_ROOT = "${androidSdkRoot}/ndk-bundle";

            shellHook = ''
              echo "fishsense-mobile-thirdparty dev shell (Android)"
              echo "  ANDROID_SDK_ROOT = $ANDROID_SDK_ROOT"
              echo "  ANDROID_NDK_ROOT = $ANDROID_NDK_ROOT"
              echo "  java  : $(java -version 2>&1 | head -n1)"
            '';
          };
        };
      });
}
