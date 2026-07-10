// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kith",       targets: ["kith"]),
        .executable(name: "kith-agent", targets: ["KithAgent"]),
        .executable(name: "KithApp",    targets: ["KithApp"]),
        .library(name: "ContactsCore",       targets: ["ContactsCore"]),
        .library(name: "MessagesCore",       targets: ["MessagesCore"]),
        .library(name: "ResolveCore",        targets: ["ResolveCore"]),
        .library(name: "KithAgentProtocol",  targets: ["KithAgentProtocol"]),
        .library(name: "KithAgentClient",    targets: ["KithAgentClient"]),
        .library(name: "KithMessagesService", targets: ["KithMessagesService"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git",  from: "0.16.0"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.4"),
        .package(url: "https://github.com/trilemma-dev/SecureXPC.git",     from: "0.8.0"),
    ],
    targets: [
        .target(name: "ContactsCore"),
        .target(
            name: "MessagesCore",
            dependencies: [
                .product(name: "SQLite",         package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            exclude: ["README.md"]
        ),
        .target(
            name: "ResolveCore",
            dependencies: ["ContactsCore", "MessagesCore"]
        ),
        // Wire-protocol types + XPCRoute definitions shared between the
        // agent (server) and the CLI (client). Depends on MessagesCore so
        // wire-shape construction helpers (`cleanMessageText`,
        // `makeKithMessage`) can take MessagesCore values directly — both
        // sides already import MessagesCore for their own reasons, so no new
        // transitive deps are introduced.
        .target(
            name: "KithAgentProtocol",
            dependencies: [
                "ContactsCore",
                "MessagesCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        // Pure in-process implementation of the messages.* + contacts.*
        // pipelines (resolver, canonical-1:1 filter, message stream,
        // attachments, text cleanup). Both the agent (production XPC) and
        // the CLI (test/dev local mode via KITH_DB_PATH) depend on it so
        // there's exactly one source of truth for "how kith resolves and
        // streams messages."
        .target(
            name: "KithMessagesService",
            dependencies: [
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
                "KithAgentProtocol",
            ]
        ),
        // Long-lived daemon (LaunchAgent in v0.2.0 production layout).
        // ResolveCore brings the `KithPhoneNumberNormalizer: PhoneNumberNormalizing`
        // conformance the agent needs to wire `CNBackedContactsStore`.
        .executableTarget(
            name: "KithAgent",
            dependencies: [
                "KithAgentProtocol",
                "KithMessagesService",
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        // Thin client the CLI uses to talk to the agent over Mach service.
        .target(
            name: "KithAgentClient",
            dependencies: [
                "KithAgentProtocol",
                "ContactsCore",
                .product(name: "SecureXPC", package: "SecureXPC"),
            ]
        ),
        .executableTarget(
            name: "kith",
            dependencies: [
                "ContactsCore",
                "MessagesCore",
                "ResolveCore",
                "KithAgentClient",
                "KithAgentProtocol",
                "KithMessagesService",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/kith/Resources/Info.plist",
                ])
            ]
        ),
        // Headless bootstrap target. Built as a Mach-O executable that gets
        // wrapped into Kith.app/Contents/MacOS/KithApp by scripts/package.sh.
        // The Info.plist + LaunchAgent plist are bundled into the .app's
        // Contents/ tree at package time (NOT linked into the binary), so
        // SMAppService's plistName lookup resolves them at runtime.
        .executableTarget(
            name: "KithApp",
            exclude: [
                "Resources/Info.plist",
                "Resources/com.supaku.kith.agent.plist",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.svg",
                "Resources/Entitlements.plist",
            ]
        ),
        .testTarget(name: "ContactsCoreTests", dependencies: ["ContactsCore"]),
        .testTarget(name: "MessagesCoreTests", dependencies: ["MessagesCore"]),
        .testTarget(name: "ResolveCoreTests",  dependencies: ["ResolveCore"]),
        .testTarget(name: "kithTests",         dependencies: ["kith", "ResolveCore"]),
    ]
)
