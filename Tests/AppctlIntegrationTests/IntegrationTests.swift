import Foundation
import Testing

@testable import AppctlCore

@Suite(
    "Integration",
    .enabled(
        if: ProcessInfo.processInfo.environment["APPCTL_INTEGRATION_TESTS"] == "1",
        "Set APPCTL_INTEGRATION_TESTS=1 to run against the live App Store Connect API."
    )
)
struct IntegrationTests {
    @Test func listApps() async throws {
        let config = try ConfigLoader.load()
        let gen = try AuthStore.createGenerator(from: config)
        let client = APIClient(jwtGenerator: gen)
        let r: APIListResponse<App> = try await client.getList("apps", limit: 1, pageSize: 1)
        #expect(!r.data.isEmpty)
    }
}
