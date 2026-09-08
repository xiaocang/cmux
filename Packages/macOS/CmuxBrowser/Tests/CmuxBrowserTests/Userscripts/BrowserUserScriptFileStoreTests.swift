import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserUserScriptFileStore")
struct BrowserUserScriptFileStoreTests {
    @Test func installsListsDisablesAndRemovesScripts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserUserScriptFileStore(directoryURL: directory)
        let installed = try store.install(source: """
        // ==UserScript==
        // @name Store Test
        // @match https://example.com/*
        // ==/UserScript==
        window.__storeTest = true;
        """)

        let listed = try store.installedScripts()
        #expect(listed.count == 1)
        #expect(listed.first?.id == installed.id)
        #expect(listed.first?.enabled == true)
        #expect(listed.first?.metadata.name == "Store Test")

        let disabled = try store.setEnabled(id: installed.id, enabled: false)
        #expect(disabled?.enabled == false)
        #expect(try store.installedScripts().first?.enabled == false)

        #expect(try store.remove(id: installed.id))
        #expect(try store.installedScripts().isEmpty)
    }

    @Test func installWithExistingIDReplacesSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BrowserUserScriptFileStore(directoryURL: directory)
        _ = try store.install(source: """
        // ==UserScript==
        // @name First
        // @match https://example.com/*
        // ==/UserScript==
        """, id: "fixed")
        _ = try store.install(source: """
        // ==UserScript==
        // @name Second
        // @match https://example.org/*
        // ==/UserScript==
        """, id: "fixed")

        let listed = try store.installedScripts()
        #expect(listed.count == 1)
        #expect(listed.first?.id == "fixed")
        #expect(listed.first?.metadata.name == "Second")
    }

    @Test func explicitIdentifiersStayInsideStoreDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-tests-\(UUID().uuidString)")
        let directory = root.appending(path: "userscripts")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = BrowserUserScriptFileStore(directoryURL: directory)
        let installed = try store.install(
            source: """
            // ==UserScript==
            // @name Safe Path
            // @match https://example.com/*
            // ==/UserScript==
            """,
            id: "../../outside"
        )

        #expect(installed.id == "../../outside")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension == "js" }.count == 1)
        #expect(files.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL.path
                == directory.standardizedFileURL.path
        })
    }

    @Test func manifestPathsCannotReadOrDeleteOutsideStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cmux-userscript-tests-\(UUID().uuidString)")
        let directory = root.appending(path: "userscripts")
        let outsideFile = root.appending(path: "outside.user.js")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        // ==UserScript==
        // @name Outside
        // ==/UserScript==
        """.write(to: outsideFile, atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "scripts": [
            {
              "id": "outside",
              "file": "../outside.user.js",
              "enabled": true
            }
          ]
        }
        """.write(
            to: directory.appending(path: "manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let store = BrowserUserScriptFileStore(directoryURL: directory)
        #expect(try store.installedScripts().isEmpty)
        #expect(try store.remove(id: "outside"))
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }
}
