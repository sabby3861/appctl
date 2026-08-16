import Foundation

/// Shared `--app-id` + `--version` → appStoreVersion ID resolution used by the
/// screenshots and metadata commands.
public enum AppStoreVersionResolver {
    public static func resolveVersionID(
        client: any AppStoreConnectClient, appID: String, versionString: String
    ) async throws -> String {
        let r: APIListResponse<AppStoreVersion> = try await client.getList(
            "apps/\(appID)/appStoreVersions",
            queryItems: [URLQueryItem(name: "filter[versionString]", value: versionString)],
            limit: 1, pageSize: 1)
        guard let version = r.data.first else {
            throw AppctlError.resourceNotFound(
                type: "Version", identifier: "\(versionString) (app \(appID))")
        }
        return version.id
    }
}
