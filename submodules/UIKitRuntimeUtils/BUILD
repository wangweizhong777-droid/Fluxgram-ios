
objc_library(
    name = "UIKitRuntimeUtils",
    enable_modules = True,
    module_name = "UIKitRuntimeUtils",
    srcs = glob([
        "Source/UIKitRuntimeUtils/*.m",
    ]),
    copts = [
        "-Werror",
        # This compatibility layer intentionally keeps legacy UIKit APIs for
        # older iOS versions. New SDKs mark those APIs deprecated, but they
        # remain required by the runtime shims.
        "-Wno-deprecated-declarations",
    ],
    hdrs = glob([
        "Source/UIKitRuntimeUtils/*.h",
    ]),
    includes = [
      "Source",
    ],
    deps = [
      "//submodules/AsyncDisplayKit",
      "//submodules/ObjCRuntimeUtils",
    ],
    sdk_frameworks = [
      "Foundation",
      "UIKit",
      "WebKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
