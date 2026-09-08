import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptValueStore")
struct BrowserUserScriptValueStoreTests {
    @Test func persistsJSONCompatibleValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserUserScriptValueStore(directoryURL: directory)
        try store.setValue(.string("Ada"), scriptID: "script:one", key: "name")
        try store.setValue(.number(42), scriptID: "script:one", key: "count")
        try store.setValue(
            .object(["ok": .bool(true), "items": .array([.string("a"), .null])]),
            scriptID: "script:one",
            key: "nested"
        )

        let reloaded = BrowserUserScriptValueStore(directoryURL: directory)
        #expect(try reloaded.value(scriptID: "script:one", key: "name") == .string("Ada"))
        #expect(try reloaded.value(scriptID: "script:one", key: "count") == .number(42))
        #expect(try reloaded.keys(scriptID: "script:one") == ["count", "name", "nested"])
        #expect(try reloaded.values(scriptID: "script:missing").isEmpty)
    }

    @Test func setAndDeleteManyValues() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserUserScriptValueStore(directoryURL: directory)
        try store.setValues(["one": .number(1), "two": .number(2)], scriptID: "script")
        try store.setValues(["two": .number(22), "three": .number(3)], scriptID: "script")

        #expect(try store.values(scriptID: "script") == [
            "one": .number(1),
            "two": .number(22),
            "three": .number(3)
        ])
        #expect(try store.deleteValues(scriptID: "script", keys: ["one", "missing"]) == 1)
        #expect(try store.deleteValue(scriptID: "script", key: "two"))
        #expect(!(try store.deleteValue(scriptID: "script", key: "two")))
        #expect(try store.values(scriptID: "script") == ["three": .number(3)])
    }

    @Test func collidingSlugsKeepValuesIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserUserScriptValueStore(directoryURL: directory)
        try store.setValue(.string("slash"), scriptID: "a/b", key: "value")
        try store.setValue(.string("dash"), scriptID: "a-b", key: "value")

        #expect(try store.value(scriptID: "a/b", key: "value") == .string("slash"))
        #expect(try store.value(scriptID: "a-b", key: "value") == .string("dash"))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension == "json" }.count == 2)
    }

    @Test func legacySlugFileMigratesToHashedName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-values-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyURL = directory.appending(path: "script-one.json")
        let data = try JSONEncoder().encode([
            "value": BrowserUserScriptValue.string("legacy")
        ])
        try data.write(to: legacyURL)

        let store = BrowserUserScriptValueStore(directoryURL: directory)
        #expect(try store.value(scriptID: "script/one", key: "value") == .string("legacy"))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension == "json" }.count == 1)
    }

    @Test func convertsWebKitMessageObjects() throws {
        let value = try BrowserUserScriptValue(jsonObject: [
            "flag": true,
            "text": "hello",
            "number": NSNumber(value: 3.5),
            "array": [NSNull(), "x"]
        ] as [String: Any])

        #expect(value == .object([
            "flag": .bool(true),
            "text": .string("hello"),
            "number": .number(3.5),
            "array": .array([.null, .string("x")])
        ]))
    }
}
