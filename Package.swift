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
    ]
)
