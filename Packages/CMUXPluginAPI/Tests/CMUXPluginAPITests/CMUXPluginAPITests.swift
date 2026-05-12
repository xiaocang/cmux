import XCTest
import CMUXPluginAPI

final class CMUXPluginAPITests: XCTestCase {
    func testManifestStoresIdentityAndPermissions() {
        let manifest = CMUXPluginManifest(
            id: "@cmux/test",
            name: "Test",
            version: "0.1.0",
            activation: ["onStartup"],
            permissions: ["events:read"]
        )

        XCTAssertEqual(manifest.id, "@cmux/test")
        XCTAssertEqual(manifest.permissions, ["events:read"])
    }
}
