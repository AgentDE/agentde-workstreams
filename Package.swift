// swift-tools-version:5.10
import PackageDescription

// Workstreams in AgentDE: the panel beside each agent's chat, the MCP server's environment for each tab, and the
// Usage widget. Bundle the `workstream-mcp` executable with the app (extensions.json lists it as a helper).
let package = Package(
    name: "agentde-workstreams",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentDEWorkstreams", targets: ["AgentDEWorkstreams"])],
    dependencies: [.package(path: "../agentde"), .package(path: "../agentde-widgets"), .package(path: "../workstream-mcp")],
    targets: [
        .target(name: "AgentDEWorkstreams",
                dependencies: [.product(name: "AgentDEKit", package: "agentde"), .product(name: "AgentDEWidgets", package: "agentde-widgets"),
                               .product(name: "WorkstreamKit", package: "workstream-mcp")],
                path: "Sources/AgentDEWorkstreams"),
        .testTarget(name: "AgentDEWorkstreamsTests",
                    dependencies: ["AgentDEWorkstreams", .product(name: "WorkstreamKit", package: "workstream-mcp")],
                    path: "Tests/AgentDEWorkstreamsTests"),
    ]
)
