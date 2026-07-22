/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import XCTest
import Foundation

final class CLIIntegrationTests: XCTestCase {

    private var cliBinaryPath: String {
        let bundle = Bundle(for: type(of: self))
        let executableDir = bundle.bundleURL.deletingLastPathComponent()
        return executableDir.appendingPathComponent("FptnSelectionCLI").path
    }

    func testCLIBinaryExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliBinaryPath), "FptnSelectionCLI binary should exist at \(cliBinaryPath)")
    }

    func testCLIAccessibleWithHelp() throws {
        guard FileManager.default.fileExists(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = ["--help"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("Usage:") || output.contains("fptn-selector"), "Output should contain usage info")
    }

    func testCLISimulationScenario() throws {
        guard FileManager.default.fileExists(atPath: cliBinaryPath) else {
            throw XCTSkip("CLI binary not found at \(cliBinaryPath)")
        }

        let scenarioPath = "/tmp/test_scenario.json"
        let scenarioJSON = """
        {
          "servers": [
            { "name": "sim1", "host": "1.1.1.1", "port": 443, "md5Fingerprint": "fp1", "latencyMs": 50, "shouldSucceed": true }
          ]
        }
        """
        try scenarioJSON.write(toFile: scenarioPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: scenarioPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliBinaryPath)
        process.arguments = ["simulate", "--scenario", scenarioPath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("Simulation complete") || output.contains("sim1"), "Output should confirm simulation execution")
    }
}
