import XCTest
import CMUXEnhancementAPI

final class CMUXEnhancementAPITests: XCTestCase {
    func testManifestDefaults() {
        let manifest = CMUXEnhancementManifest(id: "@cmux/enhancement-test")

        XCTAssertEqual(manifest.id, "@cmux/enhancement-test")
        XCTAssertEqual(manifest.apiVersion, "0.1")
        XCTAssertTrue(manifest.activation.isEmpty)
        XCTAssertTrue(manifest.permissions.isEmpty)
    }
}
