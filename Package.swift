// swift-tools-version: 6.2
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let macOSFrameworks: [LinkerSetting] = [
  .linkedFramework("EventKit", .when(platforms: [.macOS])),
  .linkedFramework("Contacts", .when(platforms: [.macOS])),
  .linkedFramework("AppKit", .when(platforms: [.macOS])),
  .linkedFramework("ImageIO", .when(platforms: [.macOS])),
  .linkedFramework("PDFKit", .when(platforms: [.macOS])),
  .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
  .linkedFramework("Vision", .when(platforms: [.macOS])),
  .linkedFramework("ApplicationServices", .when(platforms: [.macOS])),
  .linkedFramework("Security", .when(platforms: [.macOS])),
]

let macOSExecutableSettings: [LinkerSetting] = [
  .unsafeFlags(
    [
      "-Xlinker", "-sectcreate",
      "-Xlinker", "__TEXT",
      "-Xlinker", "__info_plist",
      "-Xlinker", "Sources/MacHandsfreeCLI/Info.plist",
    ], .when(platforms: [.macOS]))
]

let package = Package(
  name: "mac-handsfree",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "mac-handsfree", targets: ["MacHandsfreeCLI"]),
    .library(name: "MacHandsfreeRuntime", targets: ["MacHandsfreeRuntime"])
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(
      url: "https://github.com/axiom-orient/swiftMcp.git",
      revision: "25b504306a2506f9171076ef0522e56ad7929c3f"
    ),
    .package(url: "https://github.com/mattt/Madrid.git", exact: "0.4.0"),
    .package(
      url: "https://github.com/migueldeicaza/MimeFoundation.git",
      revision: "dcb6746729d20cf00c42ad6453b4637a075f7d0b"
    ),
    .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9"),
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite3",
      providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
      name: "CPlatformSupport",
      publicHeadersPath: "include"
    ),
    .target(
      name: "MacHandsfreeCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "MacHandsfreeSQLite",
      dependencies: ["MacHandsfreeCore", "CSQLite3"],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "MacHandsfreeState",
      dependencies: ["MacHandsfreeCore", "MacHandsfreeSQLite"],
      swiftSettings: strictSwiftSettings
    ),
    .target(
      name: "MacHandsfreePlatform",
      dependencies: [
        "MacHandsfreeCore", "MacHandsfreeSQLite", "CPlatformSupport",
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "MimeFoundation", package: "MimeFoundation"),
        .product(name: "SwiftSoup", package: "SwiftSoup"),
        .product(name: "TypedStream", package: "Madrid"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      resources: [.process("Resources")],
      swiftSettings: strictSwiftSettings,
      linkerSettings: macOSFrameworks
    ),
    .target(
      name: "MacHandsfreeRuntime",
      dependencies: [
        "MacHandsfreeCore",
        "MacHandsfreeState",
        "MacHandsfreePlatform",
        .product(name: "MCP", package: "swiftmcp"),
        .product(name: "MCPStdioServer", package: "swiftmcp"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .executableTarget(
      name: "MacHandsfreeCLI",
      dependencies: ["MacHandsfreeCore", "MacHandsfreeRuntime"],
      exclude: ["Info.plist", "mac-handsfree.entitlements"],
      swiftSettings: strictSwiftSettings,
      linkerSettings: macOSExecutableSettings
    ),
    .testTarget(
      name: "MacHandsfreeCoreTests",
      dependencies: ["MacHandsfreeCore", "MacHandsfreeSQLite", "MacHandsfreeState"],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "MacHandsfreePlatformTests",
      dependencies: [
        "MacHandsfreeCore", "MacHandsfreeSQLite", "MacHandsfreePlatform", "MacHandsfreeRuntime",
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ],
      swiftSettings: strictSwiftSettings
    ),
    .testTarget(
      name: "MacHandsfreeCLITests",
      dependencies: ["MacHandsfreeCore", "MacHandsfreePlatform", "MacHandsfreeRuntime"],
      swiftSettings: strictSwiftSettings
    ),
  ]
)
