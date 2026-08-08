load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "DeviceAccess",
    module_name = "DeviceAccess",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # Keep the existing iOS 13-compatible microphone and location
        # authorization branches while newer SDKs deprecate their APIs.
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/LegacyComponents:LegacyComponents",
    ],
    visibility = [
        "//visibility:public",
    ],
)
