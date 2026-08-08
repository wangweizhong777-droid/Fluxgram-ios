load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SaveToCameraRoll",
    module_name = "SaveToCameraRoll",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # Preserve the existing metadata-injection and camera-roll export
        # flow while newer AVFoundation SDKs deprecate its synchronous APIs.
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/DeviceAccess:DeviceAccess",
        "//submodules/LegacyComponents:LegacyComponents",
    ],
    visibility = [
        "//visibility:public",
    ],
)
