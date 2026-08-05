// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "MacScopeNative",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "MacScopeNative", targets: ["MacScopeNative"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-testing.git",
      exact: "0.12.0"
    )
  ],
  targets: [
    .executableTarget(
      name: "MacScopeNative",
      linkerSettings: [
        .linkedFramework("CoreWLAN"),
        .linkedFramework("IOKit"),
        .linkedFramework("Security"),
        .linkedFramework("ServiceManagement"),
      ]
    ),
    .testTarget(
      name: "MacScopeNativeTests",
      dependencies: [
        "MacScopeNative",
        .product(name: "Testing", package: "swift-testing"),
      ]
    ),
  ]
)
