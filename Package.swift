// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "XiaomiRemoteRemapper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "XiaomiRemoteRemapper", targets: ["XiaomiRemoteRemapper"])
    ],
    targets: [
        .executableTarget(
            name: "XiaomiRemoteRemapper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
