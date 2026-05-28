import AppKit
import Foundation
import XCTest

enum ScreenshotAssert {
    private static let defaultOutputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-sprite-assistant-screenshots", isDirectory: true)
        .path

    struct Result: Equatable {
        var name: String
        var comparedAgainstBaseline: Bool
        var mismatchRatio: Double
        var width: Int
        var height: Int
        var nonUniformPixelRatio: Double
    }

    @discardableResult
    static func match(
        _ app: XCUIApplication,
        name: String,
        testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result {
        match(app.screenshot(), name: name, testCase: testCase, file: file, line: line)
    }

    @discardableResult
    static func matchWindow(
        _ app: XCUIApplication,
        name: String,
        testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 2) else {
            XCTFail("Could not find app window for screenshot \(name)", file: file, line: line)
            return match(app, name: name, testCase: testCase, file: file, line: line)
        }
        return match(window.screenshot(), name: name, testCase: testCase, file: file, line: line)
    }

    @discardableResult
    static func writeFailureArtifacts(
        _ app: XCUIApplication,
        name: String,
        testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        let directoryURL = outputDirectoryURL()
        let safeName = safeFilename("\(name)-failure")
        let screenshotURL = directoryURL.appendingPathComponent("\(safeName).png")
        let hierarchyURL = directoryURL.appendingPathComponent("\(safeName)-hierarchy.txt")
        let metadataURL = directoryURL.appendingPathComponent("\(safeName).json")
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let screenshot = app.screenshot()
            try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
            try app.debugDescription.write(to: hierarchyURL, atomically: true, encoding: .utf8)

            let metadata = FailureArtifactMetadata(
                name: name,
                screenshotFilename: screenshotURL.lastPathComponent,
                hierarchyFilename: hierarchyURL.lastPathComponent,
                appState: appStateDescription(app.state),
                outputDirectory: directoryURL.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

            attachPath(screenshotURL, name: "\(name)-failure-screenshot-path", testCase: testCase)
            attachPath(hierarchyURL, name: "\(name)-failure-hierarchy-path", testCase: testCase)
            attachPath(metadataURL, name: "\(name)-failure-metadata-path", testCase: testCase)
            let screenshotAttachment = XCTAttachment(contentsOfFile: screenshotURL)
            screenshotAttachment.name = "\(name)-failure-screenshot"
            screenshotAttachment.lifetime = .keepAlways
            testCase.add(screenshotAttachment)
            return directoryURL
        } catch {
            XCTFail("Could not write UI failure artifacts for \(name): \(error)", file: file, line: line)
            return nil
        }
    }

    @discardableResult
    static func match(
        _ screenshot: XCUIScreenshot,
        name: String,
        testCase: XCTestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        let actualData = screenshot.pngRepresentation
        guard let actualBitmap = Bitmap(data: actualData) else {
            XCTFail("Could not decode screenshot for \(name)", file: file, line: line)
            writeActualScreenshot(
                screenshot,
                name: name,
                testCase: testCase,
                metrics: nil,
                comparison: nil
            )
            return Result(
                name: name,
                comparedAgainstBaseline: false,
                mismatchRatio: 1,
                width: 0,
                height: 0,
                nonUniformPixelRatio: 0
            )
        }

        let metrics = ScreenshotMetrics(name: name, bitmap: actualBitmap)
        assertUsableScreenshot(metrics, file: file, line: line)

        guard let baselineDirectory = baselineDirectoryPath() else {
            writeActualScreenshot(
                screenshot,
                name: name,
                testCase: testCase,
                metrics: metrics,
                comparison: nil
            )
            return Result(
                name: name,
                comparedAgainstBaseline: false,
                mismatchRatio: 0,
                width: metrics.width,
                height: metrics.height,
                nonUniformPixelRatio: metrics.nonUniformPixelRatio
            )
        }

        let baselineURL = URL(fileURLWithPath: baselineDirectory)
            .appendingPathComponent("\(name).png")
        guard let baselineData = try? Data(contentsOf: baselineURL) else {
            XCTFail("Missing screenshot baseline: \(baselineURL.path)", file: file, line: line)
            writeActualScreenshot(
                screenshot,
                name: name,
                testCase: testCase,
                metrics: metrics,
                comparison: .missingBaseline
            )
            return Result(
                name: name,
                comparedAgainstBaseline: true,
                mismatchRatio: 1,
                width: metrics.width,
                height: metrics.height,
                nonUniformPixelRatio: metrics.nonUniformPixelRatio
            )
        }

        guard let diff = ImageDiff(baselineData: baselineData, actualData: actualData) else {
            XCTFail("Could not decode screenshot or baseline for \(name)", file: file, line: line)
            writeActualScreenshot(
                screenshot,
                name: name,
                testCase: testCase,
                metrics: metrics,
                comparison: .decodeFailed
            )
            return Result(
                name: name,
                comparedAgainstBaseline: true,
                mismatchRatio: 1,
                width: metrics.width,
                height: metrics.height,
                nonUniformPixelRatio: metrics.nonUniformPixelRatio
            )
        }

        let allowedMismatchRatio = Double(
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_MAX_MISMATCH"] ?? ""
        ) ?? 0.05
        XCTAssertLessThanOrEqual(
            diff.mismatchRatio,
            allowedMismatchRatio,
            "Screenshot \(name) mismatch ratio \(diff.mismatchRatio) exceeded \(allowedMismatchRatio)",
            file: file,
            line: line
        )
        writeActualScreenshot(
            screenshot,
            name: name,
            testCase: testCase,
            metrics: metrics,
            comparison: .compared(mismatchRatio: diff.mismatchRatio)
        )
        return Result(
            name: name,
            comparedAgainstBaseline: true,
            mismatchRatio: diff.mismatchRatio,
            width: metrics.width,
            height: metrics.height,
            nonUniformPixelRatio: metrics.nonUniformPixelRatio
        )
    }

    private static func writeActualScreenshot(
        _ screenshot: XCUIScreenshot,
        name: String,
        testCase: XCTestCase,
        metrics: ScreenshotMetrics?,
        comparison: ScreenshotComparison?
    ) {
        let directoryURL = outputDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let outputURL = directoryURL.appendingPathComponent("\(safeFilename(name)).png")
            try screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
            attachPath(outputURL, name: "\(name)-screenshot-path", testCase: testCase)

            if let metrics {
                let metadataURL = directoryURL.appendingPathComponent("\(safeFilename(name)).json")
                let metadata = ScreenshotArtifactMetadata(
                    name: name,
                    filename: outputURL.lastPathComponent,
                    width: metrics.width,
                    height: metrics.height,
                    nonUniformPixelRatio: metrics.nonUniformPixelRatio,
                    comparedAgainstBaseline: comparison?.comparedAgainstBaseline ?? false,
                    mismatchRatio: comparison?.mismatchRatio,
                    comparisonStatus: comparison?.status ?? "artifact_only"
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                attachPath(metadataURL, name: "\(name)-metadata-path", testCase: testCase)
            }
        } catch {
            XCTFail("Could not write screenshot artifact for \(name): \(error)")
        }
    }

    private static func outputDirectoryURL() -> URL {
        let configuredOutputDirectory = ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_OUTPUT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let outputDirectory = configuredOutputDirectory.isEmpty
            ? defaultOutputDirectory
            : configuredOutputDirectory
        return URL(fileURLWithPath: outputDirectory, isDirectory: true)
    }

    private static func baselineDirectoryPath() -> String? {
        let configuredBaselineDirectory = ProcessInfo.processInfo.environment["CMUX_UI_TEST_BASELINE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configuredBaselineDirectory.isEmpty {
            return configuredBaselineDirectory
        }

        let checkedInBaselineURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Screenshots__/baseline", isDirectory: true)
        guard FileManager.default.fileExists(atPath: checkedInBaselineURL.path) else {
            return nil
        }
        return checkedInBaselineURL.path
    }

    private static func attachPath(_ url: URL, name: String, testCase: XCTestCase) {
        let attachment = XCTAttachment(string: url.path)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }

    private static func appStateDescription(_ state: XCUIApplication.State) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .notRunning:
            return "not_running"
        case .runningBackground:
            return "running_background"
        case .runningForeground:
            return "running_foreground"
        @unknown default:
            return "unknown_future_state"
        }
    }

    private static func assertUsableScreenshot(
        _ metrics: ScreenshotMetrics,
        file: StaticString,
        line: UInt
    ) {
        let minimumWidth = Int(
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_MIN_WIDTH"] ?? ""
        ) ?? 200
        let minimumHeight = Int(
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_MIN_HEIGHT"] ?? ""
        ) ?? 200
        let minimumNonUniformRatio = Double(
            ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_MIN_NONUNIFORM_RATIO"] ?? ""
        ) ?? 0.0001

        XCTAssertGreaterThanOrEqual(
            metrics.width,
            minimumWidth,
            "Screenshot \(metrics.name) width \(metrics.width) below \(minimumWidth)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            metrics.height,
            minimumHeight,
            "Screenshot \(metrics.name) height \(metrics.height) below \(minimumHeight)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            metrics.nonUniformPixelRatio,
            minimumNonUniformRatio,
            "Screenshot \(metrics.name) appears blank or nearly uniform",
            file: file,
            line: line
        )
    }

    private static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let filename = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return filename.isEmpty ? "screenshot" : filename
    }

    private struct ScreenshotMetrics: Equatable {
        var name: String
        var width: Int
        var height: Int
        var nonUniformPixelRatio: Double

        init(name: String, bitmap: Bitmap) {
            self.name = name
            width = bitmap.width
            height = bitmap.height
            nonUniformPixelRatio = Self.nonUniformPixelRatio(bitmap.pixels)
        }

        private static func nonUniformPixelRatio(_ pixels: [UInt8]) -> Double {
            guard pixels.count >= 8 else { return 0 }
            let reference = Array(pixels[0..<4])
            var nonUniformPixels = 0
            let pixelCount = pixels.count / 4
            for pixelIndex in 0..<pixelCount {
                let offset = pixelIndex * 4
                var differs = false
                for channel in 0..<4 where pixels[offset + channel] != reference[channel] {
                    differs = true
                    break
                }
                if differs {
                    nonUniformPixels += 1
                }
            }
            return pixelCount == 0 ? 0 : Double(nonUniformPixels) / Double(pixelCount)
        }
    }

    private enum ScreenshotComparison {
        case missingBaseline
        case decodeFailed
        case compared(mismatchRatio: Double)

        var comparedAgainstBaseline: Bool {
            true
        }

        var mismatchRatio: Double? {
            switch self {
            case .missingBaseline, .decodeFailed:
                return nil
            case .compared(let mismatchRatio):
                return mismatchRatio
            }
        }

        var status: String {
            switch self {
            case .missingBaseline:
                return "missing_baseline"
            case .decodeFailed:
                return "decode_failed"
            case .compared:
                return "compared"
            }
        }
    }

    private struct ScreenshotArtifactMetadata: Codable, Equatable {
        var name: String
        var filename: String
        var width: Int
        var height: Int
        var nonUniformPixelRatio: Double
        var comparedAgainstBaseline: Bool
        var mismatchRatio: Double?
        var comparisonStatus: String
    }

    private struct FailureArtifactMetadata: Codable, Equatable {
        var name: String
        var screenshotFilename: String
        var hierarchyFilename: String
        var appState: String
        var outputDirectory: String
    }

    private struct ImageDiff {
        var mismatchRatio: Double

        init?(baselineData: Data, actualData: Data) {
            guard let baseline = Bitmap(data: baselineData),
                  let actual = Bitmap(data: actualData),
                  baseline.width == actual.width,
                  baseline.height == actual.height,
                  baseline.pixels.count == actual.pixels.count else {
                return nil
            }

            let channelTolerance = UInt8(
                Int(ProcessInfo.processInfo.environment["CMUX_UI_TEST_SCREENSHOT_CHANNEL_TOLERANCE"] ?? "") ?? 4
            )
            var mismatchedPixels = 0
            let pixelCount = baseline.pixels.count / 4
            for pixelIndex in 0..<pixelCount {
                let offset = pixelIndex * 4
                if Self.pixelMismatch(
                    baseline: baseline.pixels,
                    actual: actual.pixels,
                    offset: offset,
                    tolerance: channelTolerance
                ) {
                    mismatchedPixels += 1
                }
            }
            mismatchRatio = pixelCount == 0 ? 0 : Double(mismatchedPixels) / Double(pixelCount)
        }

        private static func pixelMismatch(
            baseline: [UInt8],
            actual: [UInt8],
            offset: Int,
            tolerance: UInt8
        ) -> Bool {
            for channel in 0..<4 {
                let lhs = Int(baseline[offset + channel])
                let rhs = Int(actual[offset + channel])
                if abs(lhs - rhs) > Int(tolerance) {
                    return true
                }
            }
            return false
        }
    }

    private struct Bitmap {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        init?(data: Data) {
            guard let image = NSImage(data: data),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            let imageWidth = cgImage.width
            let imageHeight = cgImage.height
            var renderedPixels = Array(repeating: UInt8(0), count: imageWidth * imageHeight * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var didRender = false
            renderedPixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress,
                    width: imageWidth,
                    height: imageHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: imageWidth * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    return
                }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
                didRender = true
            }
            guard didRender else { return nil }
            width = imageWidth
            height = imageHeight
            pixels = renderedPixels
        }
    }
}
