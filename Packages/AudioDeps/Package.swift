// swift-tools-version: 6.2
import PackageDescription

// Wraps the vendored FluidAudio so it can be linked with its optional NeMo
// text-normalization engine turned off (an 87 MB download Minutes never uses).
let package = Package(
    name: "AudioDeps",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AudioDeps", targets: ["AudioDeps"])],
    dependencies: [.package(path: "../../Vendor/FluidAudio", traits: [])],
    targets: [
        .target(name: "AudioDeps", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
