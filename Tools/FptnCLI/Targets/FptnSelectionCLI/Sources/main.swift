/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection
import FptnConnectionOrchestration

@main
struct FptnSelectorApp {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            return
        }

        let command = args[1]

        switch command {
        case "auto-select":
            await runAutoSelect(args: args)
        case "manual-bootstrap":
            await runManualBootstrap(args: args)
        case "scan-all":
            await runScanAll(args: args)
        case "diagnostic":
            await runDiagnostic(args: args)
        case "simulate":
            await runSimulate(args: args)
        case "matrix":
            await runMatrix(args: args)
        case "soak-sim":
            await runSoakSim(args: args)
        default:
            print("Unknown command: \(command)")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        FPTN Server Selector CLI

        Usage:
          fptn-selector auto-select --config <path>
          fptn-selector manual-bootstrap --config <path> --server <host:port>
          fptn-selector scan-all --config <path>
          fptn-selector diagnostic --config <path>
          fptn-selector simulate --scenario <path>
          fptn-selector matrix --config <path> --iterations <n>
          fptn-selector soak-sim --iterations <n>
        """)
    }
}

func runAutoSelect(args: [String]) async {
    print("auto-select: not yet implemented in M2 phase 1")
}

func runManualBootstrap(args: [String]) async {
    print("manual-bootstrap: not yet implemented in M2 phase 1")
}

func runScanAll(args: [String]) async {
    print("scan-all: not yet implemented in M2 phase 1")
}

func runDiagnostic(args: [String]) async {
    print("diagnostic: not yet implemented in M2 phase 1")
}

func runSimulate(args: [String]) async {
    print("simulate: not yet implemented in M2 phase 1")
}

func runMatrix(args: [String]) async {
    print("matrix: not yet implemented in M2 phase 1")
}

func runSoakSim(args: [String]) async {
    print("soak-sim: not yet implemented in M2 phase 1")
}
