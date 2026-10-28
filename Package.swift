// swift-tools-version:5.10
// FrameShare — by Anton Pushkin
import PackageDescription

let package = Package(
    name: "FrameShare",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrameShare",
            path: "Sources/FrameShare",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
