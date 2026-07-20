# fishsense-mobile-thirdparty

Builds the third-party native dependencies (OpenCV + ONNX Runtime) into mobile
frameworks for FishSense. The libraries are vendored as git submodules and
built by CI on tag push (`v*.*`), which publishes the artifacts as a GitHub
release. See [`.github/workflows/build.yml`](.github/workflows/build.yml).

## Dev environment (Nix flake)

The flake pins everything the build scripts need — the tools you used to
`brew install` (CMake, Ninja, git, pkg-config, coreutils) plus a Python 3.13
with the ONNX Runtime build modules already bundled (flatbuffers, numpy,
protobuf, sympy, packaging). No manual `pip install` / venv step. Bring your own
machine, get the same toolchain.

### iOS / default

```sh
git submodule update --init --recursive
nix develop
```

Xcode is **not** provided by Nix (Apple licensing) — you supply it. The shell is
deliberately built with `mkShellNoCC` so it does **not** shadow your system
Xcode toolchain (`xcrun`, `xcodebuild`, `xcode-select`); those keep pointing at
`/Applications/Xcode.app`.

First-time Xcode setup: the build drives CMake's Xcode generator, which needs a
fully provisioned Xcode. If `xcodebuild` complains about a missing
`CoreSimulator.framework` / a plug-in failing to load, install the additional
components once:

```sh
sudo xcodebuild -runFirstLaunch   # or: xcrun simctl list runtimes
```

Then run the same commands CI runs. **OpenCV XCFramework:**

```sh
# The CFLAGS/CXXFLAGS prefix is required on Xcode 26 / AppleClang 21 — see below.
CFLAGS="-Xarch_arm64 -march=armv8.2-a+fp16" \
CXXFLAGS="-Xarch_arm64 -march=armv8.2-a+fp16" \
python3 ./opencv/platforms/apple/build_xcframework.py \
  --out ./opencv/build \
  --iphoneos_deployment_target 17.0 \
  --iphoneos_archs arm64 \
  --iphonesimulator_archs arm64 \
  --build_only_specified_archs True \
  --dynamic --without objc
```

**ONNX Runtime XCFramework:**

```sh
CMAKE_POLICY_VERSION_MINIMUM=3.5 \
python3 ./onnxruntime/tools/ci_build/github/apple/build_and_assemble_apple_pods.py \
  --staging-dir ./onnxruntime/build \
  --build-settings-file ./onnxruntime_ios_build_settings.json
```

**Why the `-march` prefix?** OpenCV's `CPU_BASELINE=DETECT` runs on the build
host (Apple Silicon, which has FP16), so it enables the `NEON_FP16` code paths —
but OpenCV's iOS Xcode toolchain never emits the matching `-march=…+fp16`
compiler flag. AppleClang 21 (Xcode 26) then hard-errors on the target-feature
mismatch in `modules/dnn` (`vfmaq_f16 requires 'fullfp16'`). Older clang (on
`macos-latest` CI) only warned, so CI is unaffected — for now. The prefix
supplies the missing flag; `-Xarch_arm64` scopes it to the arm64 slices. (If you
don't use `cv::dnn` — this repo ships ONNX Runtime for inference — you can
instead add `--without dnn` and drop the prefix.)

**Simulator is arm64-only.** x86_64 simulator support was dropped: the Xcode 26
SDK's `math.h` uses `_Float16`, which is unsupported on the x86_64 target, so
ONNX Runtime's XNNPACK microkernels fail to compile for that slice. Apple is
winding down Intel entirely, so this slice is a dead end. Both frameworks build
`ios-arm64` + `ios-arm64-simulator`.

### Android (future)

```sh
nix develop .#android
```

Provides a pinned Android SDK/NDK and JDK 17 with `ANDROID_SDK_ROOT` /
`ANDROID_NDK_ROOT` exported. Unlike iOS, the Android toolchain lives entirely in
Nix, so this path can be made fully hermetic. The SDK/NDK/build-tools versions
in [`flake.nix`](flake.nix) are a starting point — pin them to whatever OpenCV
and ONNX Runtime require when the Android build is implemented.
