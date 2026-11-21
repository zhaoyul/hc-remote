// swift-tools-version: 5.10
import Foundation
import PackageDescription

let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = appDir.deletingLastPathComponent()
let nativeBuild =
  ProcessInfo.processInfo.environment["HCR_NATIVE_BUILD"].map {
    URL(fileURLWithPath: $0).standardizedFileURL
  } ?? repoRoot.appendingPathComponent("build")

let package = Package(
  name: "hc-remote-app",
  platforms: [.macOS(.v13)],
  targets: [
    .systemLibrary(
      name: "CHcr",
      path: "Sources/CHcr"
    ),
    .target(
      name: "HcrCore",
      dependencies: ["CHcr"],
      linkerSettings: [
        .unsafeFlags(["-L\(nativeBuild.path)", "-lhcr_native"])
      ]
    ),
    .target(
      name: "HcrMedia",
      dependencies: ["HcrCore"]
    ),
    .executableTarget(
      name: "HcrApp",
      dependencies: ["HcrCore", "HcrMedia"]
    ),
    .executableTarget(
      name: "HcrSmoke",
      dependencies: ["HcrCore"]
    ),
  ]
)
