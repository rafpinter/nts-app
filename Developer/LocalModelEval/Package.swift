// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalModelEval",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalModelEval", targets: ["LocalModelEval"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.29.1")),
    ],
    targets: [
        .executableTarget(name: "LocalModelEval", dependencies: [
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
        ]),
    ]
)
