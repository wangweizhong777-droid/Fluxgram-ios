# Fluxgram iOS

Fluxgram 是一个基于 Telegram iOS 的非官方客户端，重点提供 Telegram 媒体收藏、NAS 下载和短视频时间线能力。

## Fluxgram 功能

- **媒体工作台**：从首页查看 NAS 状态、下载队列、收藏数量和短视频来源。
- **NAS 下载中心**：支持本地待提交队列、进行中任务、历史记录、失败重试和取消任务。
- **收藏箱媒体库**：按标签聚合收藏消息，支持筛选、批量选择和下载到 NAS。
- **短视频时间线**：从手动添加的频道或群组扫描视频，支持刷新、播放和下载。
- **安全配置**：访问令牌保存在 iOS Keychain；外网地址推荐使用 HTTPS。

## 本地开发

项目基于 Telegram iOS 的 Bazel 构建系统。需要 macOS、Xcode、Swift 和递归 Git submodules。

真机调试构建示例：

```bash
build-input/bazel-8.4.2-darwin-arm64 \
  --bazelrc=Telegram/Telegram.xcodeproj/rules_xcodeproj/bazel/xcodeproj.bazelrc \
  --bazelrc=.bazelrc \
  build //Telegram:Telegram \
  --config=rules_xcodeproj \
  --config=macos \
  --ios_multi_cpus=arm64 \
  --watchos_cpus=arm64_32
```

Fluxgram 配置项包括：TGAPP 内网/外网地址、访问令牌、NAS 监听地址和监听令牌。令牌不会写入普通 UserDefaults。

## 项目定位

> Fluxgram = Telegram 的媒体收藏、下载和 NAS 管理中心。

这是一个非官方 Telegram 客户端。使用者需要自行申请 Telegram API 凭据，并遵守 Telegram API、当地法律和隐私要求。

---

# Telegram iOS Source Code Compilation Guide

We welcome all developers to use our API and source code to create applications on our platform.
There are several things we require from **all developers** for the moment.

# Creating your Telegram Application

1. [**Obtain your own api_id**](https://core.telegram.org/api/obtaining_api_id) for your application.
2. Please **do not** use the name Telegram for your app — or make sure your users understand that it is unofficial.
3. Kindly **do not** use our standard logo (white paper plane in a blue circle) as your app's logo.
3. Please study our [**security guidelines**](https://core.telegram.org/mtproto/security_guidelines) and take good care of your users' data and privacy.
4. Please remember to publish **your** code too in order to comply with the licences.

# Quick Compilation Guide

## Get the Code

```
git clone --recursive -j8 https://github.com/TelegramMessenger/Telegram-iOS.git
```

## Setup Xcode

Install Xcode (directly from https://developer.apple.com/download/applications or using the App Store).

## Adjust Configuration

1. Generate a random identifier:
```
openssl rand -hex 8
```
2. Create a new Xcode project. Use `Telegram` as the Product Name. Use `org.{identifier from step 1}` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Use data from the previous steps.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

# Advanced Compilation Guide

## Xcode

1. Copy and edit `build-system/appstore-configuration.json`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

## IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## Telegram_xcodeproj: no such package 

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```
