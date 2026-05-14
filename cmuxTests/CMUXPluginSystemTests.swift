import XCTest
import CMUXPluginAPI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXPluginHostTests: XCTestCase {
    func testActivatesInOrderAndDeactivatesInReverseOrder() throws {
        let context = TestPluginContext()
        let logger = TestPluginLogger()
        let host = CMUXPluginHost(context: context, logger: logger)
        let recorder = EventRecorder()

        let first = RecordingPlugin(id: "first", recorder: recorder)
        let second = RecordingPlugin(id: "second", recorder: recorder)

        try host.activate([first, second])
        XCTAssertEqual(host.activatedPluginIds, ["first", "second"])

        host.deactivate()
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "activate:second",
            "deactivate:second",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedPluginIds, [])
    }

    func testActivationFailureDeactivatesPreviouslyActivatedPlugins() {
        let context = TestPluginContext()
        let logger = TestPluginLogger()
        let host = CMUXPluginHost(context: context, logger: logger)
        let recorder = EventRecorder()

        let first = RecordingPlugin(id: "first", recorder: recorder)
        let failing = RecordingPlugin(id: "failing", recorder: recorder, activationError: TestError.activationFailed)
        let skipped = RecordingPlugin(id: "skipped", recorder: recorder)

        XCTAssertThrowsError(try host.activate([first, failing, skipped]))
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "activate:failing",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedPluginIds, [])
    }

    func testUnsupportedPermissionFailsAndDeactivatesPreviouslyActivatedPlugins() {
        let context = TestPluginContext()
        let logger = TestPluginLogger()
        let host = CMUXPluginHost(context: context, logger: logger)
        let recorder = EventRecorder()

        let first = RecordingPlugin(id: "first", recorder: recorder)
        let unsupported = RecordingPlugin(
            id: "unsupported",
            recorder: recorder,
            permissions: ["system:write"]
        )

        XCTAssertThrowsError(try host.activate([first, unsupported])) { error in
            XCTAssertEqual(
                error as? CMUXPluginHost.HostError,
                .unsupportedPermissions(pluginId: "unsupported", permissions: ["system:write"])
            )
        }
        XCTAssertEqual(recorder.events, [
            "activate:first",
            "deactivate:first",
        ])
        XCTAssertEqual(host.activatedPluginIds, [])
    }

    func testActivationHonorsManifestTrigger() throws {
        let context = TestPluginContext()
        let logger = TestPluginLogger()
        let host = CMUXPluginHost(context: context, logger: logger)
        let recorder = EventRecorder()

        let defaultActivation = RecordingPlugin(id: "default", recorder: recorder)
        let appStart = RecordingPlugin(id: "app", recorder: recorder, activation: ["onAppStart"])
        let workspaceOnly = RecordingPlugin(id: "workspace", recorder: recorder, activation: ["onWorkspaceOpen"])
        let unknownOnly = RecordingPlugin(id: "unknown", recorder: recorder, activation: ["onSomethingElse"])

        try host.activate([defaultActivation, appStart, workspaceOnly, unknownOnly])

        XCTAssertEqual(host.activatedPluginIds, ["default", "app"])
        XCTAssertEqual(recorder.events, [
            "activate:default",
            "activate:app",
        ])

        try host.activate([defaultActivation, appStart, workspaceOnly, unknownOnly], trigger: .onWorkspaceOpen)

        XCTAssertEqual(host.activatedPluginIds, ["default", "app", "workspace"])
        XCTAssertEqual(recorder.events, [
            "activate:default",
            "activate:app",
            "activate:workspace",
        ])
    }
}

final class CMUXRegistryTests: XCTestCase {
    func testEventRegistryFiltersAndDisposableUnsubscribes() {
        let bus = CmuxEventBus(retainedEventLimit: 8, eventLogURL: nil)
        let registry = CMUXAppEventRegistry(bus: bus)
        let received = expectation(description: "received matching event")
        let notReceivedAfterDispose = expectation(description: "does not receive after dispose")
        notReceivedAfterDispose.isInverted = true
        var events: [CMUXPluginEvent] = []

        let disposable = registry.subscribe(names: ["workspace.created"], categories: ["workspace"]) { event in
            events.append(event)
            if event.workspaceId == "workspace-1" {
                received.fulfill()
            } else if event.workspaceId == "workspace-2" {
                notReceivedAfterDispose.fulfill()
            }
        }

        bus.publish(name: "workspace.renamed", category: "workspace", source: "test", workspaceId: "workspace-x")
        bus.publish(name: "workspace.created", category: "workspace", source: "test", workspaceId: "workspace-1")

        wait(for: [received], timeout: 1)
        XCTAssertEqual(events.map(\.workspaceId), ["workspace-1"])

        disposable.dispose()
        bus.publish(name: "workspace.created", category: "workspace", source: "test", workspaceId: "workspace-2")
        wait(for: [notReceivedAfterDispose], timeout: 0.2)
    }

    func testEventRegistryHandlesConcurrentPublishAndDispose() {
        let bus = CmuxEventBus(retainedEventLimit: 16, eventLogURL: nil, maxPendingEventsPerSubscription: 256)
        let registry = CMUXAppEventRegistry(
            bus: bus,
            queue: DispatchQueue(label: "com.cmux.tests.plugin-event-load", attributes: .concurrent)
        )
        let receivedAll = expectation(description: "received concurrent events")
        let notReceivedAfterDispose = expectation(description: "does not receive after dispose")
        notReceivedAfterDispose.isInverted = true
        let receivedLock = NSLock()
        var receivedIndexes = Set<Int>()

        let disposable = registry.subscribe(names: ["workspace.created"], categories: ["workspace"]) { event in
            if event.payload["after_dispose"] as? Bool == true {
                notReceivedAfterDispose.fulfill()
                return
            }
            guard let index = event.payload["index"] as? Int else { return }
            receivedLock.lock()
            receivedIndexes.insert(index)
            let count = receivedIndexes.count
            receivedLock.unlock()
            if count == 100 {
                receivedAll.fulfill()
            }
        }

        let group = DispatchGroup()
        let publishQueue = DispatchQueue(label: "com.cmux.tests.plugin-event-publish", attributes: .concurrent)
        for index in 0..<100 {
            group.enter()
            publishQueue.async {
                bus.publish(
                    name: "workspace.created",
                    category: "workspace",
                    source: "test",
                    workspaceId: "workspace-\(index)",
                    payload: ["index": index]
                )
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        wait(for: [receivedAll], timeout: 5)
        receivedLock.lock()
        let receivedCount = receivedIndexes.count
        receivedLock.unlock()
        XCTAssertEqual(receivedCount, 100)

        disposable.dispose()
        for index in 0..<10 {
            bus.publish(
                name: "workspace.created",
                category: "workspace",
                source: "test",
                workspaceId: "workspace-after-\(index)",
                payload: ["after_dispose": true]
            )
        }
        wait(for: [notReceivedAfterDispose], timeout: 0.3)
    }

    func testPromptRegistryOrdersByPriorityThenIdentifier() {
        let registry = CMUXAppPromptRegistry()

        registry.registerContributor(TestPromptContributor(id: "low", priority: 10))
        registry.registerContributor(TestPromptContributor(id: "high-b", priority: 80))
        registry.registerContributor(TestPromptContributor(id: "high-a", priority: 80))

        let contributions = registry.collect(input: CMUXPromptContextInput(workspaceId: "workspace"))
        XCTAssertEqual(contributions.map(\.id), ["high-a", "high-b", "low"])
    }

    func testDigestSocketResponseParserParsesDaemonResponses() throws {
        XCTAssertEqual(try DigestSocketResponseParser.parse("OK"), "")
        XCTAssertEqual(try DigestSocketResponseParser.parse("OK {\"status\":\"ok\"}"), "{\"status\":\"ok\"}")

        XCTAssertThrowsError(try DigestSocketResponseParser.parse("ERROR: failed")) { error in
            XCTAssertEqual((error as? CmuxSocketError)?.message, "failed")
        }
        XCTAssertThrowsError(try DigestSocketResponseParser.parse("WHAT"))
    }

    func testCommandRegistryRegistersSocketCommandsAndDisposableUnsubscribes() throws {
        let registry = CMUXAppCommandRegistry()
        var invoked = false

        let commandDisposable = registry.registerCommand(
            CMUXCommandContribution(
                id: "plugin.test.command",
                title: "Test Command",
                subtitle: "Plugin",
                keywords: ["test", "plugin"],
                dismissOnRun: false
            ) {
                invoked = true
            }
        )

        let commands = registry.commands()
        XCTAssertEqual(commands.map(\.id), ["plugin.test.command"])
        XCTAssertNotNil(registry.command(id: "plugin.test.command"))
        XCTAssertEqual(commands.first?.title, "Test Command")
        XCTAssertEqual(commands.first?.subtitle, "Plugin")
        XCTAssertEqual(commands.first?.keywords, ["test", "plugin"])
        XCTAssertEqual(commands.first?.dismissOnRun, false)
        commands.first?.handler()
        XCTAssertTrue(invoked)

        let disposable = registry.registerSocketCommand(
            CMUXSocketCommandContribution(
                id: "plugin.test.echo",
                title: "Echo",
                executionContext: .socketWorker
            ) { input in
                .ok([
                    "command_id": input.commandId,
                    "value": input.params["value"] as? String ?? "",
                    "protocol": input.protocolVersion.rawValue,
                ])
            }
        )

        XCTAssertEqual(registry.socketCommands().map(\.id), ["plugin.test.echo"])

        let command = try XCTUnwrap(registry.socketCommand(id: "plugin.test.echo"))
        XCTAssertEqual(command.executionContext, .socketWorker)
        let result = try command.handler(
            CMUXSocketCommandInput(
                commandId: "plugin.test.echo",
                protocolVersion: .v2,
                rawLine: "{}",
                params: ["value": "hello"],
                jsonRPCId: 1
            )
        )
        XCTAssertEqual(result.payload["command_id"] as? String, "plugin.test.echo")
        XCTAssertEqual(result.payload["value"] as? String, "hello")
        XCTAssertEqual(result.payload["protocol"] as? String, "v2")

        disposable.dispose()
        XCTAssertNil(registry.socketCommand(id: "plugin.test.echo"))
        XCTAssertEqual(registry.socketCommands().map(\.id), [])

        commandDisposable.dispose()
        XCTAssertNil(registry.command(id: "plugin.test.command"))
        XCTAssertEqual(registry.commands().map(\.id), [])
    }

    func testPluginSocketBridgeEncodesV1PayloadAndErrors() throws {
        let registry = CMUXAppCommandRegistry()

        XCTAssertNil(CMUXPluginSocketBridge.v1Response(
            commandId: "plugin.missing",
            arguments: "",
            rawLine: "plugin.missing",
            commands: registry
        ))

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.echo.v1") { input in
                XCTAssertEqual(input.commandId, "plugin.echo.v1")
                XCTAssertEqual(input.protocolVersion, .v1)
                XCTAssertEqual(input.rawLine, "plugin.echo.v1 hello")
                XCTAssertEqual(input.arguments, "hello")
                XCTAssertEqual(input.params["arguments"] as? String, "hello")
                return .ok(["value": "hello", "count": 2])
            }
        )
        let response = try XCTUnwrap(CMUXPluginSocketBridge.v1Response(
            commandId: "plugin.echo.v1",
            arguments: "hello",
            rawLine: "plugin.echo.v1 hello",
            commands: registry
        ))
        XCTAssertTrue(response.hasPrefix("OK "))
        let payload = try jsonObject(String(response.dropFirst(3)))
        XCTAssertEqual(payload["value"] as? String, "hello")
        XCTAssertEqual(payload["count"] as? Int, 2)

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.fail.v1") { _ in
                throw CMUXSocketCommandError(code: "plugin_denied", message: "Denied by plugin")
            }
        )
        XCTAssertEqual(
            CMUXPluginSocketBridge.v1Response(
                commandId: "plugin.fail.v1",
                arguments: "",
                rawLine: "plugin.fail.v1",
                commands: registry
            ),
            "ERROR: Denied by plugin"
        )

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.invalid.v1") { _ in
                .ok(["invalid": NSObject()])
            }
        )
        XCTAssertEqual(
            CMUXPluginSocketBridge.v1Response(
                commandId: "plugin.invalid.v1",
                arguments: "",
                rawLine: "plugin.invalid.v1",
                commands: registry
            ),
            "ERROR: Plugin command returned a non-JSON payload"
        )
    }

    func testPluginSocketBridgeEncodesV2PayloadAndErrors() throws {
        let registry = CMUXAppCommandRegistry()

        XCTAssertNil(CMUXPluginSocketBridge.v2Response(
            method: "plugin.missing",
            id: 1,
            params: [:],
            rawLine: "{\"method\":\"plugin.missing\"}",
            commands: registry
        ))

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.echo.v2") { input in
                XCTAssertEqual(input.commandId, "plugin.echo.v2")
                XCTAssertEqual(input.protocolVersion, .v2)
                XCTAssertEqual(input.rawLine, "{\"method\":\"plugin.echo.v2\"}")
                XCTAssertEqual(input.jsonRPCId as? Int, 7)
                XCTAssertEqual(input.params["value"] as? String, "world")
                return .ok(["value": "world"])
            }
        )
        var response = try XCTUnwrap(CMUXPluginSocketBridge.v2Response(
            method: "plugin.echo.v2",
            id: 7,
            params: ["value": "world"],
            rawLine: "{\"method\":\"plugin.echo.v2\"}",
            commands: registry
        ))
        var object = try jsonObject(response)
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["id"] as? Int, 7)
        XCTAssertEqual((object["result"] as? [String: Any])?["value"] as? String, "world")

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.fail.v2") { _ in
                throw CMUXSocketCommandError(
                    code: "plugin_denied",
                    message: "Denied by plugin",
                    data: ["reason": "policy"]
                )
            }
        )
        response = try XCTUnwrap(CMUXPluginSocketBridge.v2Response(
            method: "plugin.fail.v2",
            id: "request-1",
            params: [:],
            rawLine: "{\"method\":\"plugin.fail.v2\"}",
            commands: registry
        ))
        object = try jsonObject(response)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["id"] as? String, "request-1")
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "plugin_denied")
        XCTAssertEqual(error["message"] as? String, "Denied by plugin")
        XCTAssertEqual((error["data"] as? [String: Any])?["reason"] as? String, "policy")

        registry.registerSocketCommand(
            CMUXSocketCommandContribution(id: "plugin.invalid.v2") { _ in
                .ok(["invalid": NSObject()])
            }
        )
        response = try XCTUnwrap(CMUXPluginSocketBridge.v2Response(
            method: "plugin.invalid.v2",
            id: nil,
            params: [:],
            rawLine: "{\"method\":\"plugin.invalid.v2\"}",
            commands: registry
        ))
        object = try jsonObject(response)
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue(object["id"] is NSNull)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "invalid_plugin_response")
        XCTAssertEqual(
            (object["error"] as? [String: Any])?["message"] as? String,
            "Plugin command returned a non-JSON payload"
        )
    }

    func testSidebarExtensionRegistryOrdersByPriorityAndDisposableUnsubscribes() {
        let registry = CMUXAppSidebarExtensionRegistry()

        let low = registry.registerSidebarExtension(
            CMUXSidebarExtensionContribution(
                id: "sidebar.low",
                title: "Low",
                placement: .workspaceSidebarTrailingOverlay,
                openStateKey: "sidebar.low.open",
                defaultOpen: false,
                priority: 10
            )
        )
        registry.registerSidebarExtension(
            CMUXSidebarExtensionContribution(
                id: "sidebar.high",
                title: "High",
                placement: .workspaceSidebarTrailingOverlay,
                openStateKey: "sidebar.high.open",
                defaultOpen: true,
                priority: 90
            )
        )

        XCTAssertEqual(registry.sidebarExtensions().map(\.id), ["sidebar.high", "sidebar.low"])
        XCTAssertEqual(registry.sidebarExtension(id: "sidebar.high")?.title, "High")

        low.dispose()
        XCTAssertEqual(registry.sidebarExtensions().map(\.id), ["sidebar.high"])
        XCTAssertNil(registry.sidebarExtension(id: "sidebar.low"))
    }

    func testSettingsRegistryRegistersAndDisposableUnsubscribes() {
        let registry = CMUXAppSettingsRegistry()
        let disposable = registry.registerSettingsContribution(
            CMUXSettingsContribution(
                id: "plugin.settings.test",
                target: SettingsNavigationTarget.enhancements.rawValue,
                title: "Plugin Settings",
                subtitle: "Enhancements",
                symbolName: "puzzlepiece.extension",
                searchText: "plugin settings test",
                anchorID: SettingsSearchIndex.settingID(for: .enhancements, idSuffix: "plugin-test")
            )
        )

        let contribution = registry.settingsContribution(id: "plugin.settings.test")
        XCTAssertEqual(contribution?.title, "Plugin Settings")
        XCTAssertEqual(contribution?.target, SettingsNavigationTarget.enhancements.rawValue)
        XCTAssertEqual(registry.settingsContributions().map(\.id), ["plugin.settings.test"])

        disposable.dispose()
        XCTAssertNil(registry.settingsContribution(id: "plugin.settings.test"))
        XCTAssertEqual(registry.settingsContributions().map(\.id), [])
    }

    func testSummaryPrioritySidebarExtensionOpenStateRequiresRegisteredContribution() {
        let registry = CMUXAppSidebarExtensionRegistry()
        let key = "cmux.tests.summaryPriority.open.\(UUID().uuidString)"
        let contribution = CMUXSidebarExtensionContribution(
            id: CMUXBuiltinSidebarExtensionID.summaryPriority,
            title: "Summary Priority",
            placement: .workspaceSidebarTrailingOverlay,
            openStateKey: key,
            defaultOpen: false,
            priority: 100
        )
        defer { UserDefaults.standard.removeObject(forKey: key) }

        XCTAssertNil(CMUXSummaryPrioritySidebarExtension.toggleSidebarExtension(
            id: contribution.id,
            sidebarExtensions: registry
        ))
        XCTAssertFalse(CMUXSummaryPrioritySidebarExtension.setSidebarExtensionOpen(
            id: contribution.id,
            open: true,
            sidebarExtensions: registry
        ))
        XCTAssertNil(UserDefaults.standard.object(forKey: key))

        let disposable = registry.registerSidebarExtension(contribution)
        defer { disposable.dispose() }

        XCTAssertTrue(CMUXSummaryPrioritySidebarExtension.setSidebarExtensionOpen(
            id: contribution.id,
            open: true,
            sidebarExtensions: registry
        ))
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, true)

        XCTAssertNotNil(CMUXSummaryPrioritySidebarExtension.toggleSidebarExtension(
            id: contribution.id,
            sidebarExtensions: registry
        ))
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
    }

    func testWorkspaceSidebarTrailingOverlayResolverUsesPluginContributionMetadata() {
        let unsupported = CMUXSidebarExtensionContribution(
            id: "sidebar.unsupported",
            title: "Unsupported",
            placement: .workspaceSidebarTrailingOverlay,
            openStateKey: "sidebar.unsupported.open",
            defaultOpen: false,
            priority: 200,
            metadata: ["renderer": "unknown"]
        )
        let summaryPriority = CMUXSidebarExtensionContribution(
            id: "sidebar.summary",
            title: "Summary",
            placement: .workspaceSidebarTrailingOverlay,
            openStateKey: "sidebar.summary.open",
            defaultOpen: true,
            priority: 100,
            metadata: ["renderer": "summary-priority"]
        )
        let provider = RecordingPluginAppProvider(sidebarContributions: [unsupported, summaryPriority])

        let resolved = WorkspaceSidebarTrailingOverlayExtensionResolver.summaryPriorityContribution(from: provider)

        XCTAssertEqual(resolved?.id, "sidebar.summary")
        XCTAssertEqual(provider.requestedPlacements, [.workspaceSidebarTrailingOverlay])
    }

    func testPluginStorageSanitizesPluginIdAndCreatesDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = CMUXAppPluginStorage(applicationSupportDirectory: root)
        let url = try storage.url(forPluginId: "@cmux/plugin:weird.id")

        XCTAssertEqual(url.lastPathComponent, "_cmux_plugin_weird_id")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "plugins")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try storage.url(forPluginId: "@cmux/plugin:weird.id"), url)
    }

    func testPluginStorageUsesDirectoryOverrideForKnownPlugin() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plugin-storage-override-\(UUID().uuidString)", isDirectory: true)
        let overrideURL = root.appendingPathComponent("digest", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = CMUXAppPluginStorage(pluginDirectoryOverrides: [
            CMUXBuiltinPluginID.digest: overrideURL
        ])
        let url = try storage.url(forPluginId: CMUXBuiltinPluginID.digest)

        XCTAssertEqual(url, overrideURL)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testGHPRConfigurationLoadsDefaultsAndOverrides() throws {
        let suiteName = "cmux-plugin-ghpr-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var configuration = CMUXGHPRConfiguration.load(defaults: defaults)
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.socketPath, CMUXGHPRIntegrationSettings.defaultSocketPath)
        XCTAssertEqual(configuration.displayItemsText, CMUXGHPRIntegrationSettings.defaultDisplayItemsText)
        XCTAssertNil(configuration.jiraBaseURL)

        defaults.set(true, forKey: CMUXGHPRIntegrationSettings.enabledKey)
        defaults.set(" /tmp/custom-ghpr.sock ", forKey: CMUXGHPRIntegrationSettings.socketPathKey)
        defaults.set("ci, review, jira", forKey: CMUXGHPRIntegrationSettings.displayItemsKey)
        defaults.set(" https://jira.example.com ", forKey: CMUXGHPRIntegrationSettings.jiraBaseURLKey)

        configuration = CMUXGHPRConfiguration.load(defaults: defaults)
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.socketPath, "/tmp/custom-ghpr.sock")
        XCTAssertEqual(configuration.displayItemsText, "ci, review, jira")
        XCTAssertEqual(configuration.jiraBaseURL, "https://jira.example.com")
    }

    func testGHPRPullRequestContextEncodesDigestPayload() throws {
        let context = ghprPullRequestContext()

        let encodedPayload = try XCTUnwrap(context.encodedPayload)
        let data = try XCTUnwrap(encodedPayload.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(payload["repository"] as? String, "manaflow-ai/cmux")
        XCTAssertEqual(payload["number"] as? Int, 42)
        XCTAssertEqual(payload["ciStatus"] as? String, "failing")
        XCTAssertEqual(payload["jiraTicket"] as? String, "CMUX-42")
        XCTAssertEqual(payload["jiraURL"] as? String, "https://jira.example.com/browse/CMUX-42")
        XCTAssertEqual(
            context.summaryText,
            "Linked PR manaflow-ai/cmux#42 is open: Add plugin context. CI: failing. 2 unresolved review threads. Jira: CMUX-42."
        )
    }

    func testGHPRContextCollectorReturnsPullRequestContextItem() throws {
        let provider = FakeGHPRContextProvider(context: ghprPullRequestContext())
        let collector = CMUXGHPRContextCollector(service: provider)

        let items = try collector.collect(input: CMUXContextCollectInput(workspaceId: "workspace-1"))

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "ghpr.context.workspace-1")
        XCTAssertEqual(item.source, "@cmux/plugin-ghpr")
        XCTAssertEqual(item.kind, "pull_request")
        XCTAssertEqual(item.metadata["repository"], "manaflow-ai/cmux")
        XCTAssertEqual(item.metadata["number"], "42")
        XCTAssertEqual(item.metadata["state"], "OPEN")
        XCTAssertEqual(provider.requestedWorkspaceIds, ["workspace-1" as String?])
        let encoded = try XCTUnwrap(item.metadata["pullRequestJSON"])
        XCTAssertTrue(encoded.contains("\"repository\":\"manaflow-ai/cmux\""))
    }

    func testDigestPluginSchedulesOnlyRelevantEventFamilies() {
        XCTAssertTrue(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "agent.hook.stop", category: "agent")))
        XCTAssertTrue(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "feed.item.created", category: "feed")))
        XCTAssertTrue(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "workspace.created", category: "workspace")))

        XCTAssertFalse(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "surface.created", category: "surface")))
        XCTAssertFalse(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "notification.requested", category: "notification")))
        XCTAssertFalse(CMUXDigestPlugin.shouldScheduleDigest(for: pluginEvent(name: "agentless.event", category: "agent")))
    }

    func testDigestRestartPaletteCommandRoutesThroughDigestRuntime() throws {
        try withSavedDigestEnabledSetting {
            UserDefaults.standard.set(false, forKey: "digest.enabled")
            let runtime = FakeWorkspaceDigestRuntime(socketPathValue: "/tmp/cmux-digest-command.sock")
            let service = WorkspaceDigestService(runtime: runtime)
            let context = TestPluginContext()
            let plugin = CMUXDigestPlugin(digestService: service)
            defer {
                plugin.deactivate()
                service.shutdown()
            }

            plugin.activate(context: context)
            let command = try XCTUnwrap(context.commands.command(id: CMUXBuiltinPluginCommandID.restartDigest))
            command.handler()

            XCTAssertTrue(runtime.calls.contains("restartIfRunning"))
        }
    }

    func testTmuxPrefixPluginSocketFacadeControlsInjectedService() throws {
        try withSavedLeaderSettings {
            let context = TestPluginContext()
            let service = CMUXTmuxPrefixService()
            let plugin = try XCTUnwrap(Self.tmuxPrefixPlugin(service: service))
            let host = CMUXPluginHost(context: context, logger: TestPluginLogger())

            try host.activate([plugin])
            defer { host.deactivate() }

            XCTAssertEqual(context.commands.socketCommands().map(\.id), [
                "plugin.tmux_prefix.reset",
                "plugin.tmux_prefix.set_enabled",
                "plugin.tmux_prefix.set_timeout",
                "plugin.tmux_prefix.set_workspace_tags_enabled",
                "plugin.tmux_prefix.status",
            ])

            let setEnabled = try XCTUnwrap(context.commands.socketCommand(id: "plugin.tmux_prefix.set_enabled"))
            let enabledResult = try setEnabled.handler(socketInput(
                commandId: setEnabled.id,
                params: ["enabled": true]
            ))
            XCTAssertEqual(enabledResult.payload["enabled"] as? Bool, true)
            XCTAssertTrue(service.isEnabled())

            let setTimeout = try XCTUnwrap(context.commands.socketCommand(id: "plugin.tmux_prefix.set_timeout"))
            let timeoutResult = try setTimeout.handler(socketInput(
                commandId: setTimeout.id,
                params: ["timeout": 99]
            ))
            XCTAssertEqual(timeoutResult.payload["timeout"] as? Double, LeaderKeySettings.timeoutRange.upperBound)
            XCTAssertEqual(service.timeout(), LeaderKeySettings.timeoutRange.upperBound)

            let setWorkspaceTags = try XCTUnwrap(context.commands.socketCommand(id: "plugin.tmux_prefix.set_workspace_tags_enabled"))
            let workspaceTagsResult = try setWorkspaceTags.handler(socketInput(
                commandId: setWorkspaceTags.id,
                params: ["enabled": true]
            ))
            XCTAssertEqual(workspaceTagsResult.payload["workspace_tags_enabled"] as? Bool, true)
            XCTAssertTrue(service.workspaceTagsEnabled())

            let status = try XCTUnwrap(context.commands.socketCommand(id: "plugin.tmux_prefix.status"))
            let statusResult = try status.handler(socketInput(commandId: status.id))
            let statusPayload = try XCTUnwrap(statusResult.payload["tmux_prefix"] as? [String: Any])
            XCTAssertEqual(statusResult.payload["protocol_version"] as? String, "v2")
            XCTAssertEqual(statusPayload["enabled"] as? Bool, true)
            XCTAssertEqual(statusPayload["timeout"] as? Double, LeaderKeySettings.timeoutRange.upperBound)
            XCTAssertEqual(statusPayload["workspace_tags_enabled"] as? Bool, true)

            let reset = try XCTUnwrap(context.commands.socketCommand(id: "plugin.tmux_prefix.reset"))
            _ = try reset.handler(socketInput(commandId: reset.id))
            XCTAssertEqual(service.isEnabled(), LeaderKeySettings.enabledDefault)
            XCTAssertEqual(service.timeout(), LeaderKeySettings.timeoutDefault)
            XCTAssertEqual(service.workspaceTagsEnabled(), LeaderKeySettings.workspaceTagsEnabledDefault)

            host.deactivate()
            XCTAssertEqual(context.commands.socketCommands().map(\.id), [])
        }
    }

    func testTmuxPrefixSettingsBehaviorRoutesThroughServiceAndMirrorsStoredValues() throws {
        try withSavedLeaderSettings {
            let service = CMUXTmuxPrefixService()

            let enabledStoredValue = TmuxPrefixSettingsBehavior.setLeaderKeyEnabled(
                true,
                service: service
            )
            XCTAssertTrue(enabledStoredValue)
            XCTAssertTrue(service.isEnabled())

            let timeoutStoredValue = TmuxPrefixSettingsBehavior.setLeaderKeyTimeout(
                99,
                service: service
            )
            XCTAssertEqual(timeoutStoredValue, LeaderKeySettings.timeoutRange.upperBound)
            XCTAssertEqual(service.timeout(), LeaderKeySettings.timeoutRange.upperBound)

            let workspaceTagsStoredValue = TmuxPrefixSettingsBehavior.setWorkspaceTagsEnabled(
                true,
                service: service
            )
            XCTAssertTrue(workspaceTagsStoredValue)
            XCTAssertTrue(service.workspaceTagsEnabled())
            XCTAssertTrue(CMUXWorkspaceTagSettings.isEnabled())
        }
    }

    func testDigestSettingsBehaviorRoutesThroughPluginSettingsFacade() {
        let settings = RecordingPluginSettingsManager()

        DigestSettingsBehavior.reloadDigest(settings: settings, enabled: true)
        DigestSettingsBehavior.reloadGHPRIntegration(settings: settings)

        XCTAssertEqual(settings.calls, [
            "reloadDigest:true",
            "reloadGHPRIntegration",
        ])
    }

    func testPluginSettingsSectionDescriptorUsesRegisteredContributionWithFallbackAnchor() {
        let settings = RecordingPluginSettingsManager(contributions: [
            "plugin.settings": CMUXSettingsContribution(
                id: "plugin.settings",
                target: SettingsNavigationTarget.enhancements.rawValue,
                title: "Plugin Title",
                anchorID: nil
            )
        ])

        let descriptor = PluginSettingsSectionDescriptor.resolve(
            id: "plugin.settings",
            settings: settings,
            defaultTitle: "Default Title",
            defaultAnchorID: "default.anchor"
        )
        let missing = PluginSettingsSectionDescriptor.resolve(
            id: "missing.settings",
            settings: settings,
            defaultTitle: "Default Title",
            defaultAnchorID: "default.anchor"
        )

        XCTAssertEqual(descriptor, .fallback(title: "Plugin Title", anchorID: "default.anchor"))
        XCTAssertEqual(missing, .fallback(title: "Default Title", anchorID: "default.anchor"))
    }

    func testBuiltInPluginsRegisterContributionsAgainstRealAppContext() throws {
        try withSavedDigestEnabledSetting {
            UserDefaults.standard.set(false, forKey: "digest.enabled")

            let logger = TestPluginLogger()
            let events = CMUXAppEventRegistry(
                bus: CmuxEventBus(retainedEventLimit: 8, eventLogURL: nil),
                queue: DispatchQueue(label: "com.cmux.tests.plugin-events")
            )
            let contextRegistry = CMUXAppContextRegistry(logger: logger)
            let commands = CMUXAppCommandRegistry()
            let sidebarExtensions = CMUXAppSidebarExtensionRegistry()
            let settings = CMUXAppSettingsRegistry()
            let ghprService = CMUXGHPRService(logger: logger)
            let digestService = WorkspaceDigestService(
                runtime: DigestPluginRuntime(ghprConfigurationProvider: {
                    ghprService.configuration()
                })
            )
            let pluginContext = CMUXAppPluginContext(
                logger: logger,
                events: events,
                storage: CMUXAppPluginStorage(),
                workspace: CMUXAppWorkspaceAPI(),
                context: contextRegistry,
                digest: digestService,
                prompt: CMUXAppPromptRegistry(),
                commands: commands,
                sidebarExtensions: sidebarExtensions,
                settings: settings
            )
            let host = CMUXPluginHost(context: pluginContext, logger: logger)
            defer {
                host.deactivate()
                digestService.shutdown()
            }

            try host.activate(CMUXBuiltinPlugins.make(
                tmuxPrefixService: CMUXTmuxPrefixService(),
                ghprService: ghprService,
                digestService: digestService
            ))

            XCTAssertEqual(host.activatedPluginIds, [
                CMUXBuiltinPluginID.noop,
                CMUXBuiltinPluginID.contextBridge,
                CMUXBuiltinPluginID.tmuxPrefix,
                CMUXBuiltinPluginID.ghpr,
                CMUXBuiltinPluginID.digest,
            ])
            XCTAssertNotNil(commands.socketCommand(id: "plugin.context.collect"))
            XCTAssertNotNil(commands.socketCommand(id: "plugin.tmux_prefix.status"))
            XCTAssertNotNil(commands.socketCommand(id: "plugin.ghpr.reload"))
            XCTAssertNotNil(commands.socketCommand(id: "plugin.digest.schedule"))
            XCTAssertNotNil(commands.command(id: CMUXBuiltinPluginCommandID.toggleSummaryPriority))
            XCTAssertNotNil(commands.command(id: CMUXBuiltinPluginCommandID.restartDigest))
            XCTAssertNotNil(settings.settingsContribution(id: CMUXBuiltinSettingsContributionID.digest))
            XCTAssertNotNil(settings.settingsContribution(id: CMUXBuiltinSettingsContributionID.ghpr))
            XCTAssertNotNil(settings.settingsContribution(id: CMUXBuiltinSettingsContributionID.tmuxPrefix))
            XCTAssertEqual(
                sidebarExtensions.sidebarExtension(id: CMUXBuiltinSidebarExtensionID.summaryPriority)?.id,
                CMUXBuiltinSidebarExtensionID.summaryPriority
            )

            host.deactivate()

            XCTAssertEqual(host.activatedPluginIds, [])
            XCTAssertEqual(commands.socketCommands().map(\.id), [])
            XCTAssertEqual(commands.commands().map(\.id), [])
            XCTAssertEqual(sidebarExtensions.sidebarExtensions().map(\.id), [])
            XCTAssertEqual(settings.settingsContributions().map(\.id), [])
        }
    }

    private static func tmuxPrefixPlugin(service: CMUXTmuxPrefixService) -> CMUXPlugin? {
        let ghprService = CMUXGHPRService(logger: TestPluginLogger())
        let digestService = WorkspaceDigestService(
            runtime: DigestPluginRuntime(ghprConfigurationProvider: {
                ghprService.configuration()
            })
        )
        return CMUXBuiltinPlugins.make(
            tmuxPrefixService: service,
            ghprService: ghprService,
            digestService: digestService
        ).first { $0.manifest.id == "@cmux/plugin-tmux-prefix" }
    }

    private func socketInput(
        commandId: String,
        params: [String: Any] = [:]
    ) -> CMUXSocketCommandInput {
        CMUXSocketCommandInput(
            commandId: commandId,
            protocolVersion: .v2,
            rawLine: "{}",
            params: params,
            jsonRPCId: 1
        )
    }

    private func jsonObject(_ line: String) throws -> [String: Any] {
        let data = try XCTUnwrap(line.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func pluginEvent(name: String, category: String) -> CMUXPluginEvent {
        CMUXPluginEvent(name: name, category: category, source: "test", workspaceId: "workspace-1")
    }

    private func withSavedLeaderSettings(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [
            LeaderKeySettings.enabledKey,
            LeaderKeySettings.timeoutKey,
            LeaderKeySettings.workspaceTagsEnabledKey,
        ] + LeaderKeySettings.LeaderAction.allCases.map(\.defaultsKey)
        let savedValues = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in savedValues {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        LeaderKeySettings.resetAll()
        try body()
    }

    private func ghprPullRequestContext() -> CMUXGHPRPullRequestContext {
        CMUXGHPRPullRequestContext(
            repository: "manaflow-ai/cmux",
            number: 42,
            title: "Add plugin context",
            author: "octocat",
            url: "https://github.com/manaflow-ai/cmux/pull/42",
            state: "OPEN",
            isDraft: false,
            isPinned: true,
            hasBaseConflicts: false,
            unresolvedCount: 2,
            ciStatus: "failing",
            checkSuccessCount: 3,
            checkFailureCount: 1,
            checkPendingCount: 2,
            ciIsRunning: true,
            approvalCount: 1,
            changesRequestedCount: 1,
            myReviewStatus: "changes_requested",
            jiraTicket: "CMUX-42",
            jiraURL: "https://jira.example.com/browse/CMUX-42",
            updatedAt: "2026-05-12T00:00:00Z",
            mergedAt: nil,
            section: "needs_attention",
            source: "@cmux/plugin-ghpr"
        )
    }

    private func withSavedDigestEnabledSetting(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let key = "digest.enabled"
        let savedValue = defaults.object(forKey: key)
        defer {
            if let savedValue {
                defaults.set(savedValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try body()
    }
}

@MainActor
final class WorkspaceTabStoreDigestServiceTests: XCTestCase {
    func testUsesInjectedDigestServiceForDisplayMode() {
        let digestService = FakeWorkspaceDigestService()
        let store = WorkspaceTabStore(digestService: digestService)

        store.setDisplayMode(.summaryPriority)

        XCTAssertEqual(digestService.displayModes, [.summaryPriority])
    }
}

final class WorkspaceDigestServiceLifecycleTests: XCTestCase {
    func testLifecycleDelegatesToInjectedRuntime() {
        let runtime = FakeWorkspaceDigestRuntime(socketPathValue: "/tmp/cmux-digest-test.sock")
        let service = WorkspaceDigestService(runtime: runtime)

        XCTAssertEqual(service.socketPath(), "/tmp/cmux-digest-test.sock")

        service.update(enabled: true)
        service.reload(enabled: false)
        service.setHomeDirectory(URL(fileURLWithPath: "/tmp/cmux-digest-home-test", isDirectory: true))
        service.reload(enabled: true)
        service.restartIfRunning()
        service.shutdown()

        XCTAssertEqual(runtime.calls, [
            "update:true",
            "reload:false",
            "setHomeDirectory:/tmp/cmux-digest-home-test",
            "reload:true",
            "restartIfRunning",
            "shutdown",
        ])
    }

    func testDigestRuntimeEnvironmentForLaunchIncludesSidebarWriteGate() throws {
        let suiteName = "cmux-digest-env-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "digest.enabled")
        let configuration = CMUXGHPRConfiguration(
            enabled: true,
            socketPath: "/tmp/ghpr.sock",
            displayItemsText: "ci,review",
            jiraBaseURL: nil
        )

        var environment = DigestPluginRuntime.environmentForLaunch(
            resources: FileManager.default.temporaryDirectory,
            digestSocket: "/tmp/digest.sock",
            socketPath: "/tmp/cmux.sock",
            digestHome: URL(fileURLWithPath: "/tmp/cmux-digest-home", isDirectory: true),
            baseEnvironment: ["EXISTING": "1"],
            bundleIdentifier: "com.cmuxterm.app.debug.test.tag",
            defaults: defaults,
            ghprConfiguration: configuration
        )

        XCTAssertEqual(environment["EXISTING"], "1")
        XCTAssertEqual(environment["CMUX_DIGEST_SOCKET_PATH"], "/tmp/digest.sock")
        XCTAssertEqual(environment["CMUX_DIGEST_HOME"], "/tmp/cmux-digest-home")
        XCTAssertEqual(environment["CMUX_SOCKET_PATH"], "/tmp/cmux.sock")
        XCTAssertEqual(environment["CMUX_SOCKET"], "/tmp/cmux.sock")
        XCTAssertEqual(environment["CMUX_TAG"], "test-tag")
        XCTAssertEqual(environment["CMUX_DIGEST_ENABLED"], "0")
        XCTAssertEqual(environment["CMUX_DIGEST_GHPR_ENABLED"], "1")
        XCTAssertEqual(environment["CMUX_DIGEST_GHPR_DISPLAY_ITEMS"], "ci,review")
        XCTAssertEqual(environment["CMUX_DIGEST_WRITE_SIDEBAR"], "1")

        defaults.set(false, forKey: "digest.writeSidebarMetadata")
        environment = DigestPluginRuntime.environmentForLaunch(
            resources: FileManager.default.temporaryDirectory,
            digestSocket: "/tmp/digest.sock",
            socketPath: "/tmp/cmux.sock",
            baseEnvironment: [:],
            bundleIdentifier: nil,
            defaults: defaults,
            ghprConfiguration: configuration
        )

        XCTAssertEqual(environment["CMUX_DIGEST_WRITE_SIDEBAR"], "0")
    }
}

private enum TestError: Error {
    case activationFailed
}

private final class EventRecorder {
    var events: [String] = []
}

private final class FakeGHPRContextProvider: CMUXGHPRContextProviding {
    private let context: CMUXGHPRPullRequestContext?
    private(set) var requestedWorkspaceIds: [String?] = []

    init(context: CMUXGHPRPullRequestContext?) {
        self.context = context
    }

    func pullRequestContext(workspaceId: String?) throws -> CMUXGHPRPullRequestContext? {
        requestedWorkspaceIds.append(workspaceId)
        return context
    }
}

private final class RecordingPlugin: CMUXPlugin {
    let manifest: CMUXPluginManifest
    private let activationError: Error?
    private let recorder: EventRecorder

    init(
        id: String,
        recorder: EventRecorder,
        activation: [String] = [],
        permissions: [String] = [],
        activationError: Error? = nil
    ) {
        self.manifest = CMUXPluginManifest(id: id, activation: activation, permissions: permissions)
        self.activationError = activationError
        self.recorder = recorder
    }

    func activate(context _: CMUXPluginContext) throws {
        recorder.events.append("activate:\(manifest.id)")
        if let activationError {
            throw activationError
        }
    }

    func deactivate() {
        recorder.events.append("deactivate:\(manifest.id)")
    }
}

private final class TestPromptContributor: CMUXPromptContributor {
    let id: String
    private let priority: Int

    init(id: String, priority: Int) {
        self.id = id
        self.priority = priority
    }

    func contribute(input _: CMUXPromptContextInput) throws -> [CMUXPromptContribution] {
        [
            CMUXPromptContribution(
                id: id,
                source: "test",
                priority: priority,
                content: id
            )
        ]
    }
}

private final class FakeWorkspaceDigestService: WorkspaceDigestServicing {
    var displayModes: [WorkspaceSidebarDisplayMode] = []

    func refreshSummaryPriority(
        force _: Bool,
        sort _: WorkspaceSidebarSummaryPrioritySort,
        assistantContext _: WorkspaceSidebarAssistantContext?,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityState, Error>) -> Void
    ) {
        completion(.failure(TestError.activationFailed))
    }

    func setDisplayMode(_ mode: WorkspaceSidebarDisplayMode, completion: @escaping (Result<Void, Error>) -> Void) {
        displayModes.append(mode)
        completion(.success(()))
    }

    func refreshWorkspace(
        workspaceId _: String,
        force _: Bool,
        refinement _: String?,
        sort _: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    ) {
        completion(.failure(TestError.activationFailed))
    }

    func scoreWorkspace(
        workspaceId _: String,
        sort _: WorkspaceSidebarSummaryPrioritySort,
        completion: @escaping (Result<WorkspaceSidebarSummaryPriorityItem, Error>) -> Void
    ) {
        completion(.failure(TestError.activationFailed))
    }

    func setOverride(
        workspaceId _: String,
        patch _: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.success(()))
    }

    func progress(completion: @escaping (Result<WorkspaceSidebarDigestProgressState, Error>) -> Void) {
        completion(.failure(TestError.activationFailed))
    }
}

private final class FakeWorkspaceDigestRuntime: WorkspaceDigestRuntime {
    let socketPathValue: String
    private(set) var calls: [String] = []

    init(socketPathValue: String) {
        self.socketPathValue = socketPathValue
    }

    func setHomeDirectory(_ url: URL?) {
        calls.append("setHomeDirectory:\(url?.path ?? "nil")")
    }

    func update(enabled: Bool) {
        calls.append("update:\(enabled)")
    }

    func reload(enabled: Bool) {
        calls.append("reload:\(enabled)")
    }

    func restartIfRunning() {
        calls.append("restartIfRunning")
    }

    func shutdown() {
        calls.append("shutdown")
    }

    func socketPath() -> String {
        socketPathValue
    }
}

private final class RecordingPluginSettingsManager: CMUXPluginSettingsManaging {
    private(set) var calls: [String] = []
    private let contributions: [String: CMUXSettingsContribution]

    init(contributions: [String: CMUXSettingsContribution] = [:]) {
        self.contributions = contributions
    }

    func reloadDigest(enabled: Bool) {
        calls.append("reloadDigest:\(enabled)")
    }

    func reloadGHPRIntegration() {
        calls.append("reloadGHPRIntegration")
    }

    func settingsContribution(id: String) -> CMUXSettingsContribution? {
        contributions[id]
    }
}

private final class RecordingPluginAppProvider: CMUXPluginAppProviding {
    let workspaceDigestService: WorkspaceDigestServicing = FakeWorkspaceDigestService()
    private let sidebarContributions: [CMUXSidebarExtensionContribution]
    private(set) var requestedPlacements: [CMUXSidebarExtensionPlacement] = []
    private(set) var toggledIds: [String] = []

    init(sidebarContributions: [CMUXSidebarExtensionContribution]) {
        self.sidebarContributions = sidebarContributions
    }

    func commandContributions() -> [CMUXCommandContribution] {
        []
    }

    func runCommand(id _: String) -> Bool {
        false
    }

    func sidebarExtensions(placement: CMUXSidebarExtensionPlacement) -> [CMUXSidebarExtensionContribution] {
        requestedPlacements.append(placement)
        return sidebarContributions.filter { $0.placement == placement }
    }

    func toggleSidebarExtension(id: String) -> Bool {
        toggledIds.append(id)
        return sidebarContributions.contains { $0.id == id }
    }

    func setSidebarExtensionOpen(id: String, open _: Bool) -> Bool {
        sidebarContributions.contains { $0.id == id }
    }
}

private final class TestPluginContext: CMUXPluginContext {
    let logger: CMUXPluginLogger = TestPluginLogger()
    let events: CMUXEventRegistry = TestEventRegistry()
    let storage: CMUXPluginStorage = TestPluginStorage()
    let workspace: CMUXWorkspaceAPI = TestWorkspaceAPI()
    let context: CMUXContextRegistry = TestContextRegistry()
    let digest: CMUXDigestRegistry = TestDigestRegistry()
    let prompt: CMUXPromptRegistry = CMUXAppPromptRegistry()
    let commands: CMUXCommandRegistry = CMUXAppCommandRegistry()
    let sidebarExtensions: CMUXSidebarExtensionRegistry = CMUXAppSidebarExtensionRegistry()
    let settings: CMUXSettingsRegistry = CMUXAppSettingsRegistry()
}

private final class TestPluginLogger: CMUXPluginLogger {
    func debug(_: String) {}
    func info(_: String) {}
    func warning(_: String) {}
    func error(_: String) {}
}

private final class TestEventRegistry: CMUXEventRegistry {
    func subscribe(
        names _: Set<String>,
        categories _: Set<String>,
        handler _: @escaping (CMUXPluginEvent) -> Void
    ) -> CMUXPluginDisposable {
        CMUXBlockDisposable {}
    }
}

private final class TestPluginStorage: CMUXPluginStorage {
    func url(forPluginId _: String) throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
}

private final class TestWorkspaceAPI: CMUXWorkspaceAPI {
    func currentWorkspaceId() -> String? { "workspace" }
}

private final class TestContextRegistry: CMUXContextRegistry {
    func registerCollector(_: CMUXContextCollector) -> CMUXPluginDisposable {
        CMUXBlockDisposable {}
    }

    func collect(input _: CMUXContextCollectInput) -> [CMUXContextItem] {
        []
    }
}

private final class TestDigestRegistry: CMUXDigestRegistry {
    func schedule(_: CMUXDigestScheduleRequest) {}

    func get(scope _: CMUXDigestScope) throws -> CMUXDigestResult? {
        nil
    }

    func refresh(scope _: CMUXDigestScope, force _: Bool) throws -> CMUXDigestResult? {
        nil
    }

    func progress() throws -> CMUXDigestProgressSnapshot {
        CMUXDigestProgressSnapshot()
    }

    func setOverride(scope _: CMUXDigestScope, values _: [String: Any]) throws {}
}
