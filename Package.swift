// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "lyric",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "lyric",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
