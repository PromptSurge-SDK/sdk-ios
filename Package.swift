// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "PromptSurge",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "PromptSurge", targets: ["PromptSurge"]),
    ],
    targets: [
        .target(
            name: "PromptSurge",
            path: "Sources/PromptSurge",
            // Without this line the manifest is silently omitted from the built
            // product: SPM only copies files it is told about, and there is no
            // warning for a privacy manifest that never shipped. The customer
            // finds out at App Store submission, as ITMS-91053, in a build that
            // compiled perfectly.
            //
            // `.copy` rather than `.process`: processing would let the toolchain
            // transform or relocate the file, and Apple's tooling expects this
            // exact name at the bundle root.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // The package had no test target at all until card 200. It exists so the dialog can be
        // rendered and photographed on the CI simulator: `PrePromptViewController`, `PromptResponse`
        // and `DialogTheme` are all internal, so only a target inside the package can construct
        // them (`@testable import PromptSurge`).
        .testTarget(
            name: "PromptSurgeTests",
            dependencies: ["PromptSurge"],
            path: "Tests/PromptSurgeTests"
        ),
    ]
)
