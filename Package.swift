// swift-tools-version: 6.2
import PackageDescription

// Run Scripts/fetch-cef.sh once before building: it puts the CEF distribution in Vendor/cef.
let ui: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let cefHeaders: [CXXSetting] = [.headerSearchPath("../../Vendor/cef")]

let package = Package(
    name: "PlinthChromium",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "PlinthChromium", targets: ["PlinthChromium"]),
        .executable(name: "PlinthChromiumHelper", targets: ["PlinthChromiumHelper"]),
    ],
    dependencies: [
        // The shared Plinth logic (PlinthCore) and the macOS bar and panels (PlinthMacUI).
        .package(url: "https://github.com/brandonzalcman/Plinth.git", branch: "claude/plinthcore-product"),
    ],
    targets: [
        // CEF's C++ wrapper library (libcef_dll_wrapper), built from the downloaded distribution.
        // It loads the framework at run time, so nothing links against it directly.
        .target(
            name: "CEFWrapper",
            path: "Vendor/cef",
            exclude: ["libcef_dll/CMakeLists.txt", "Release", "include", "cmake", "bazel", "BUILD.bazel", "MODULE.bazel",
                      "WORKSPACE", "CMakeLists.txt", "CREDITS.html", "LICENSE.txt", "README.txt", ".version"],
            sources: ["libcef_dll"],
            publicHeadersPath: "plinth-public",
            cxxSettings: [
                .headerSearchPath("."),
                .define("WRAPPING_CEF_SHARED"),
                .unsafeFlags(["-fno-objc-arc", "-Wno-deprecated-declarations", "-Wno-undefined-var-template"]),
            ]
        ),
        // The Objective-C++ bridge: Chrome-style windows and browser views, behind a plain ObjC API.
        .target(
            name: "PlinthCEF",
            dependencies: ["CEFWrapper"],
            cxxSettings: cefHeaders + [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "PlinthChromiumHelper", dependencies: ["CEFWrapper"], cxxSettings: cefHeaders),

        // Pure logic for the vertical sidebar (sections, rows, rail). No AppKit.
        .target(name: "PlinthSidebar", dependencies: [.product(name: "PlinthCore", package: "Plinth")]),
        // Chrome extensions found in a profile folder, and their toolbar popups.
        .target(name: "PlinthExtensions"),
        // The app shell: the shared store and bar, driving CEF.
        .target(
            name: "PlinthChromiumApp",
            dependencies: [
                "PlinthCEF", "PlinthSidebar", "PlinthExtensions",
                .product(name: "PlinthCore", package: "Plinth"),
                .product(name: "PlinthMacUI", package: "Plinth"),
            ],
            swiftSettings: ui
        ),
        .executableTarget(name: "PlinthChromium", dependencies: ["PlinthChromiumApp"], swiftSettings: ui),

        .testTarget(name: "PlinthSidebarTests", dependencies: ["PlinthSidebar", .product(name: "PlinthCore", package: "Plinth"), .product(name: "PlinthMacUI", package: "Plinth")]),
        .testTarget(name: "PlinthExtensionsTests", dependencies: ["PlinthExtensions"]),
        .testTarget(name: "PlinthChromiumAppTests", dependencies: ["PlinthChromiumApp", .product(name: "PlinthCore", package: "Plinth")]),
    ],
    cxxLanguageStandard: .cxx20
)
