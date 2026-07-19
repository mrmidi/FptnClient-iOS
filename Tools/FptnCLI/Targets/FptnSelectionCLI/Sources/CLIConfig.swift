/*=============================================================================
Copyright (c) 2026 Aleksandr Shabelnikov

Distributed under the MIT License (https://opensource.org/licenses/MIT)
=============================================================================*/

import Foundation
import FptnSharedCore
import FptnServerSelection

public struct CLIConfig: Codable, Sendable {
    public let servers: [VPNServer]
    public let censorshipStrategy: CensorshipStrategy
    public let sni: String
    public let ipv6Available: Bool
    public let tokenConfigurationID: String
    public let bootstrapPolicy: CLIBootstrapPolicy?
    public let selectionPolicy: CLISelectionPolicy?

    enum CodingKeys: String, CodingKey {
        case servers
        case censorshipStrategy = "censorship_strategy"
        case sni
        case ipv6Available = "ipv6_available"
        case tokenConfigurationID = "token_configuration_id"
        case bootstrapPolicy = "bootstrap_policy"
        case selectionPolicy = "selection_policy"
    }

    public struct CLIBootstrapPolicy: Codable, Sendable {
        public let loginAttempts: Int?
        public let dnsAttempts: Int?
        public let stageTimeoutSeconds: Double?
        public let candidateDeadlineSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case loginAttempts = "login_attempts"
            case dnsAttempts = "dns_attempts"
            case stageTimeoutSeconds = "stage_timeout_seconds"
            case candidateDeadlineSeconds = "candidate_deadline_seconds"
        }
    }

    public struct CLISelectionPolicy: Codable, Sendable {
        public let maximumActiveProbes: Int?
        public let selectionDeadlineSeconds: Double?
        public let authenticationQuorum: Int?
        public let rateLimitQuorum: Int?
        public let explorationSlots: Int?

        enum CodingKeys: String, CodingKey {
            case maximumActiveProbes = "maximum_active_probes"
            case selectionDeadlineSeconds = "selection_deadline_seconds"
            case authenticationQuorum = "authentication_quorum"
            case rateLimitQuorum = "rate_limit_quorum"
            case explorationSlots = "exploration_slots"
        }
    }

    public func resolveBootstrapPolicy() -> BootstrapPolicy {
        let base = BootstrapPolicy.production
        return BootstrapPolicy(
            loginAttempts: bootstrapPolicy?.loginAttempts ?? base.loginAttempts,
            dnsAttempts: bootstrapPolicy?.dnsAttempts ?? base.dnsAttempts,
            stageTimeout: bootstrapPolicy?.stageTimeoutSeconds.map { .seconds($0) } ?? base.stageTimeout,
            candidateDeadline: bootstrapPolicy?.candidateDeadlineSeconds.map { .seconds($0) } ?? base.candidateDeadline
        )
    }

    public func resolveSelectionPolicy() -> SelectionPolicy {
        let base = SelectionPolicy.production
        return SelectionPolicy(
            maximumActiveProbes: selectionPolicy?.maximumActiveProbes ?? base.maximumActiveProbes,
            selectionDeadline: selectionPolicy?.selectionDeadlineSeconds.map { .seconds($0) } ?? base.selectionDeadline,
            authenticationQuorum: selectionPolicy?.authenticationQuorum ?? base.authenticationQuorum,
            rateLimitQuorum: selectionPolicy?.rateLimitQuorum ?? base.rateLimitQuorum,
            explorationSlots: selectionPolicy?.explorationSlots ?? base.explorationSlots
        )
    }

    public static func load(from path: String) throws -> CLIConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(CLIConfig.self, from: data)
    }
}
