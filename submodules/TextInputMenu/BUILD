load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "TextInputMenu",
    module_name = "TextInputMenu",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        # This module intentionally keeps Telegram's legacy editing menu
        # integration for older iOS versions.
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/TelegramPresentationData:TelegramPresentationData",
    ],
    visibility = [
        "//visibility:public",
    ],
)
