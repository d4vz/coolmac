// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "coolmac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "coolmac", targets: ["CoolMac"]),
        .executable(name: "coolmac-probe", targets: ["CoolMacProbe"]),
        .executable(name: "coolmac-helper", targets: ["CoolMacHelper"]),
    ],
    targets: [
        .target(name: "SMC", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "CoolMacShared"),
        .executableTarget(
            name: "CoolMacProbe",
            dependencies: ["SMC"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "CoolMacHelper",
            dependencies: ["SMC", "CoolMacShared"]
        ),
        .executableTarget(
            name: "CoolMac",
            dependencies: ["SMC", "CoolMacShared"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
    ]
)
