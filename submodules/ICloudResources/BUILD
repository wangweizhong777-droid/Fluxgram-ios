load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ICloudResources",
    module_name = "ICloudResources",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        # This module reads local iCloud audio metadata synchronously for its
        # existing Signal API. Keep that compatibility path buildable while
        # newer AVFoundation SDKs deprecate the synchronous accessors.
        "-suppress-warnings",
    ],
    deps = [
        "//submodules/TelegramCore",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/Display",
        "//submodules/Pdf",
    ],
    visibility = [
        "//visibility:public",
    ],
)
