import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptGrantPolicy")
struct BrowserUserScriptGrantPolicyTests {
    @Test func knownNativeRequestsRequireTheirDeclaredGrant() {
        let cases: [(String, String)] = [
            ("value.list", "GM.listValues"),
            ("value.get", "GM_getValue"),
            ("value.set", "GM.setValue"),
            ("value.setMany", "GM_setValues"),
            ("value.delete", "GM.deleteValue"),
            ("value.deleteMany", "GM_deleteValues"),
            ("cookie.list", "GM.cookie"),
            ("cookie.set", "GM_cookie"),
            ("cookie.delete", "GM.cookie"),
            ("xmlhttpRequest", "GM.xmlHttpRequest"),
        ]

        for (type, grant) in cases {
            #expect(
                BrowserUserScriptGrantPolicy(grants: [grant]).allowsNativeRequest(type: type) == true,
                "\(type) should accept \(grant)"
            )
            #expect(
                BrowserUserScriptGrantPolicy(grants: []).allowsNativeRequest(type: type) == false,
                "\(type) should reject an undeclared grant"
            )
        }
    }

    @Test func valueHydrationRequiresAtLeastOneValueGrant() {
        #expect(
            BrowserUserScriptGrantPolicy(grants: ["GM.getValues"])
                .allowsNativeRequest(type: "value.getAll") == true
        )
        #expect(
            BrowserUserScriptGrantPolicy(grants: ["GM.cookie"])
                .allowsNativeRequest(type: "value.getAll") == false
        )
    }

    @Test func grantNoneDeniesPrivilegedRequests() {
        let policy = BrowserUserScriptGrantPolicy(grants: ["none", "GM_setValue", "GM_cookie"])
        #expect(policy.allowsNativeRequest(type: "value.set") == false)
        #expect(policy.allowsNativeRequest(type: "cookie.set") == false)
    }

    @Test func unrelatedRequestTypesRemainUnclassified() {
        let policy = BrowserUserScriptGrantPolicy(grants: [])
        #expect(policy.allowsNativeRequest(type: "window.focus") == nil)
        #expect(policy.allowsNativeRequest(type: "unknown") == nil)
    }
}
