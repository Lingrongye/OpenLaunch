// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OpenLaunch", platforms: [.macOS(.v14)], products: [.executable(name: "OpenLaunch", targets: ["OpenLaunch"])], targets: [
 .target(name: "OpenLaunchCore"),
 .target(name: "CTouch", linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]),
 .executableTarget(name: "OpenLaunch", dependencies: ["OpenLaunchCore", "CTouch"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]),
 .testTarget(name: "OpenLaunchCoreTests", dependencies: ["OpenLaunchCore"])
], swiftLanguageModes: [.v5])
