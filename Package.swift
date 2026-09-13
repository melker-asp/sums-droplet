// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sums",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Sums", type: .dynamic, targets: ["Sums"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.6.0"),
        // The natural-language math engine. A closed-source dynamic framework,
        // so Scripts/build-droplet.sh embeds it in the bundle's Frameworks.
        .package(url: "https://github.com/soulverteam/SoulverCore", exact: "3.5.1")
    ],
    targets: [
        .target(
            name: "Sums",
            dependencies: [
                .product(name: "DroppyKit", package: "droppykit"),
                .product(name: "SoulverCore", package: "SoulverCore")
            ]
        ),
        .executableTarget(
            name: "SumsHarness",
            dependencies: [
                "Sums",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ],
            // `droppykit run` copies this executable into .build/SumsHarness.app,
            // away from the SoulverCore.framework SwiftPM put beside it. These
            // reach back to the debug products from Contents/MacOS. Harness only:
            // the droplet bundle carries its own copy.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../arm64-apple-macosx/debug",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../x86_64-apple-macosx/debug"
                ])
            ]
        ),
        .testTarget(
            name: "SumsTests",
            dependencies: ["Sums"]
        )
    ]
)
