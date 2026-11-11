// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalEmbeddingEval",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalEmbeddingEval", targets: ["LocalEmbeddingEval"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
    ],
    targets: [
        .executableTarget(name: "LocalEmbeddingEval", dependencies: [
            .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
        ]),
    ]
)
