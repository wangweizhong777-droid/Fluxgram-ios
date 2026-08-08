load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "LegacyUI",
    module_name = "LegacyUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # This module exposes Telegram's legacy application-window bridge for
        # older iOS versions.
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/SSignalKit/SSignalKit",
    	"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/ContextUI:ContextUI",
        "//submodules/Display:Display",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramAudio:TelegramAudio",
        "//submodules/DeviceAccess:DeviceAccess",
        "//submodules/LegacyComponents:LegacyComponents",
        "//submodules/StickerResources:StickerResources",
        "//submodules/Camera",
        "//submodules/Utils/DeviceModel",
        "//submodules/TooltipUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
