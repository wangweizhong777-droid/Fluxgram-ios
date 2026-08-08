load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "Geocoding",
    module_name = "Geocoding",
    srcs = glob([
		"Sources/**/*.swift",
    ]),
    copts = [
        # CLGeocoder remains the runtime fallback for iOS 17, but is marked
        # deprecated by the iOS 26 SDK. Keep that compatibility path buildable.
        "-suppress-warnings",
    ],
    deps = [
	    "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
