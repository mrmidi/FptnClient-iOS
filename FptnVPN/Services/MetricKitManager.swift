/*=============================================================================
Copyright (c) 2024-2025 Stas Skokov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import MetricKit

final class MetricKitManager: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitManager()

    private override init() {
        super.init()
        MXMetricManager.shared.add(self)
        logger.info("MetricKitManager initialized")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            logger.info("MetricKit metric payload received: \(payload.dictionaryRepresentation())")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            logger.warning("MetricKit diagnostic payload received")

            if let crashDiagnostics = payload.crashDiagnostics {
                for crash in crashDiagnostics {
                    logger.error("MetricKit crash: \(crash)")
                }
            }

            if let hangDiagnostics = payload.hangDiagnostics {
                for hang in hangDiagnostics {
                    logger.warning("MetricKit hang: \(hang)")
                }
            }

            if let cpuExceptionDiagnostics = payload.cpuExceptionDiagnostics {
                for cpuException in cpuExceptionDiagnostics {
                    logger.warning("MetricKit CPU exception: \(cpuException)")
                }
            }

            if let diskWriteExceptionDiagnostics = payload.diskWriteExceptionDiagnostics {
                for diskWrite in diskWriteExceptionDiagnostics {
                    logger.warning("MetricKit disk write exception: \(diskWrite)")
                }
            }
        }
    }
}
