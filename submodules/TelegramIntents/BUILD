load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TelegramIntents",
    module_name = "TelegramIntents",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # Keep the existing Siri intent payload compatible with older iOS
        # versions while newer Intents SDKs deprecate its initializer.
        "-suppress-warnings",
    ],
    deps = [
    	"//submodules/TelegramCore:TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AvatarNode:AvatarNode",
    ],
    visibility = [
        "//visibility:public",
    ],
)
