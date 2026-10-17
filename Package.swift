// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "coolmac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "coolmac", targets: ["CoolMac"]),
        .executable(name: "coolmac-probe", targets: ["CoolMacProbe"]),
    ],
    targets: [
        .target(name: "SMC", linkerSettings: [.linkedFramework("IOKit")]),
        .executableTarget(
            name: "CoolMacProbe",
            dependencies: ["SMC"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "CoolMac",
            dependencies: ["SMC"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
    ]
)
