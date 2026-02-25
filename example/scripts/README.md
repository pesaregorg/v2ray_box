# Scripts Guide

This directory contains core build scripts for this package:

- `build_android_libxray.sh` -> builds `libxray.aar` from [XTLS/libXray](https://github.com/XTLS/libXray)
- `build_android_libsingbox.sh` -> builds `libsingbox.so` from [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- `build_ios_libxray.sh` -> builds `LibXray.xcframework` from [XTLS/libXray](https://github.com/XTLS/libXray)
- `build_ios_libsingbox.sh` -> builds `Libbox.xcframework` from [SagerNet/sing-box](https://github.com/SagerNet/sing-box)

## 1) build_android_libxray.sh (Android Only)

Build output:

- `android/app/libs/libxray.aar`

Usage:

```bash
sh scripts/build_android_libxray.sh
```

Common examples:

```bash
# Current Flutter project
sh scripts/build_android_libxray.sh

# Another Flutter project
sh scripts/build_android_libxray.sh \
  --project-root /path/to/your_app

# Use local libXray source
sh scripts/build_android_libxray.sh \
  --libxray-dir /path/to/libXray
```

Required tools:

- `git`
- `go`
- `python3`
- `curl`
- `jq`
- `unzip`
- `zip`

## 2) build_android_libsingbox.sh (Android Only)

Build output:

- `android/app/src/main/jniLibs/<abi>/libsingbox.so`

Notes:

- Default ABIs: `arm64-v8a,x86_64`
- 16 KB page-size check is enforced with `llvm-readobj` from Android NDK

Usage:

```bash
sh scripts/build_android_libsingbox.sh
```

Common examples:

```bash
# Current Flutter project
sh scripts/build_android_libsingbox.sh

# Another Flutter project
sh scripts/build_android_libsingbox.sh \
  --project-root /path/to/your_app

# Use local sing-box source
sh scripts/build_android_libsingbox.sh \
  --singbox-dir /path/to/sing-box

# Build only arm64
sh scripts/build_android_libsingbox.sh \
  --android-abis arm64-v8a
```

Required tools:

- `git`
- `go`
- `curl`
- `jq`
- Android NDK (with `clang` and `llvm-readobj`)

## 3) build_ios_libxray.sh (iOS)

Build output:

- `ios/Frameworks/LibXray.xcframework`

Usage:

```bash
sh scripts/build_ios_libxray.sh
```

Common examples:

```bash
# Current Flutter project
sh scripts/build_ios_libxray.sh

# Another Flutter project
sh scripts/build_ios_libxray.sh \
  --project-root /path/to/your_app

# Use local libXray source
sh scripts/build_ios_libxray.sh \
  --libxray-dir /path/to/libXray

# Use cgo-based apple builder
sh scripts/build_ios_libxray.sh \
  --apple-tool go
```

Required tools:

- `git`
- `go`
- `python3`
- `curl`
- `jq`
- `xcodebuild`

## 4) build_ios_libsingbox.sh (iOS)

Build output:

- `ios/Frameworks/Libbox.xcframework`

Usage:

```bash
sh scripts/build_ios_libsingbox.sh
```

Common examples:

```bash
# Current Flutter project
sh scripts/build_ios_libsingbox.sh

# Another Flutter project
sh scripts/build_ios_libsingbox.sh \
  --project-root /path/to/your_app

# Use local sing-box source
sh scripts/build_ios_libsingbox.sh \
  --singbox-dir /path/to/sing-box

# Build platform selection for gomobile
sh scripts/build_ios_libsingbox.sh \
  --platform ios,iossimulator,macos
```

Required tools:

- `git`
- `go`
- `curl`
- `jq`
- `xcodebuild`

## iOS Activation Checklist (after scripts)

Use script outputs as the source of truth for iOS cores. Manual core file copy is not required.

1. Update CocoaPods (recommended `1.16.2`) and run:

```bash
cd ios
pod install
```

2. Open `Runner.xcworkspace`.
3. In `PacketTunnel` target, verify linked frameworks:
   - `Libbox.xcframework`
   - `LibXray.xcframework`
   - `NetworkExtension.framework`
   - `UIKit.framework`
4. Test VPN on a physical iPhone (iOS Simulator does not support real VPN).
