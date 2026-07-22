import Foundation

enum TunnelLifecycleIntent: Equatable, Sendable {
    case running
    case stopped
}

enum TunnelLifecycleState: Equatable, Sendable {
    case idle
    case starting
    case connected
    case reasserting(attempt: Int)
    case waitingForNetwork(attempt: Int)
    case stopping
    case failed(reason: String)
}

enum TunnelLifecycleEvent: Equatable, Sendable {
    case startRequested
    case stopRequested(initiator: String)
    case transportConnected(generation: Int)
    case transportDisconnected(generation: Int, reason: String, wasConnected: Bool, pathSatisfied: Bool)
    case reconnectTimerFired(generation: Int, pathSatisfied: Bool)
    case networkPathChanged(isSatisfied: Bool)
    case startTimedOut
    case settingsApplied
    case settingsFailed(reason: String)
}

enum TunnelLifecycleEffect: Equatable, Sendable {
    case startWebSocket
    case stopWebSocket
    case applySettings
    case startReadLoop
    case scheduleReconnect(attempt: Int)
    case cancelReconnect
    case cancelStartTimeout
    case waitForNetwork(attempt: Int)
    case finishStart(error: String?)
    case failTunnel(reason: String)
    case ignoreStaleCallback
    case log(String)
}

struct TunnelLifecycleTransition: Equatable, Sendable {
    let intent: TunnelLifecycleIntent
    let state: TunnelLifecycleState
    let effects: [TunnelLifecycleEffect]
}

struct TunnelLifecycleRuntime: Equatable, Sendable {
    var intent: TunnelLifecycleIntent = .stopped
    var state: TunnelLifecycleState = .idle
    var activeGeneration: Int = 0

    mutating func reduce(_ event: TunnelLifecycleEvent) -> [TunnelLifecycleEffect] {
        let transition = Self.nextTransition(
            intent: intent,
            state: state,
            activeGeneration: activeGeneration,
            event: event
        )
        intent = transition.intent
        state = transition.state
        return transition.effects
    }

    static func nextTransition(
        intent: TunnelLifecycleIntent,
        state: TunnelLifecycleState,
        activeGeneration: Int,
        event: TunnelLifecycleEvent
    ) -> TunnelLifecycleTransition {
        switch event {
        case .startRequested:
            return .init(
                intent: .running,
                state: .starting,
                effects: [.startWebSocket]
            )

        case .stopRequested(let initiator):
            return .init(
                intent: .stopped,
                state: .stopping,
                effects: [
                    .log("stop requested initiator=\(initiator)"),
                    .cancelReconnect,
                    .cancelStartTimeout,
                    .stopWebSocket
                ]
            )

        case .transportConnected(let generation):
            guard intent == .running else {
                return .init(intent: intent, state: state, effects: [.stopWebSocket])
            }
            guard generation == activeGeneration else {
                return .init(intent: intent, state: state, effects: [.ignoreStaleCallback])
            }
            switch state {
            case .starting:
                return .init(intent: intent, state: .connected, effects: [.cancelReconnect, .applySettings])
            case .reasserting, .waitingForNetwork:
                return .init(intent: intent, state: .connected, effects: [.cancelReconnect, .startReadLoop])
            default:
                return .init(intent: intent, state: state, effects: [])
            }

        case .transportDisconnected(let generation, let reason, _, let pathSatisfied):
            guard intent == .running else {
                return .init(
                    intent: intent,
                    state: .stopping,
                    effects: [.log("skip reconnect because intent is stopped reason=\(reason)")]
                )
            }
            guard generation == activeGeneration else {
                return .init(intent: intent, state: state, effects: [.ignoreStaleCallback])
            }
            switch state {
            case .starting:
                return .init(intent: intent, state: .failed(reason: reason), effects: [.finishStart(error: reason)])
            case .connected, .reasserting, .waitingForNetwork:
                let nextAttempt = reconnectAttempt(from: state) + 1
                if pathSatisfied {
                    return .init(
                        intent: intent,
                        state: .reasserting(attempt: nextAttempt),
                        effects: [.scheduleReconnect(attempt: nextAttempt)]
                    )
                }
                return .init(
                    intent: intent,
                    state: .waitingForNetwork(attempt: nextAttempt),
                    effects: [.waitForNetwork(attempt: nextAttempt)]
                )
            default:
                return .init(intent: intent, state: state, effects: [])
            }

        case .reconnectTimerFired(let generation, let pathSatisfied):
            guard intent == .running else {
                return .init(
                    intent: intent,
                    state: state,
                    effects: [.log("skip reconnect timer because intent is stopped")]
                )
            }
            guard generation == activeGeneration else {
                return .init(intent: intent, state: state, effects: [.ignoreStaleCallback])
            }
            let attempt = reconnectAttempt(from: state)
            guard attempt > 0 else {
                return .init(intent: intent, state: state, effects: [])
            }
            if pathSatisfied {
                return .init(intent: intent, state: .reasserting(attempt: attempt), effects: [.startWebSocket])
            }
            return .init(intent: intent, state: .waitingForNetwork(attempt: attempt), effects: [.waitForNetwork(attempt: attempt)])

        case .networkPathChanged(let isSatisfied):
            guard intent == .running else {
                return .init(intent: intent, state: state, effects: [])
            }
            if case .waitingForNetwork(let attempt) = state, isSatisfied {
                return .init(intent: intent, state: .reasserting(attempt: attempt), effects: [.scheduleReconnect(attempt: attempt)])
            }
            return .init(intent: intent, state: state, effects: [])

        case .startTimedOut:
            return .init(
                intent: intent,
                state: .failed(reason: "start timed out"),
                effects: [.finishStart(error: "WebSocket connection timeout"), .stopWebSocket]
            )

        case .settingsApplied:
            return .init(intent: intent, state: .connected, effects: [.startReadLoop, .finishStart(error: nil)])

        case .settingsFailed(let reason):
            return .init(intent: intent, state: .failed(reason: reason), effects: [.finishStart(error: reason), .stopWebSocket])
        }
    }

    static func reconnectAttempt(from state: TunnelLifecycleState) -> Int {
        switch state {
        case .reasserting(let attempt), .waitingForNetwork(let attempt):
            return attempt
        default:
            return 0
        }
    }
}

// PR1B: typed send result for the outbound queue.
enum WebsocketSendResult: UInt8, Sendable {
    case accepted = 0
    case queueFull = 1
    case transportStopped = 2
    case invalidPacket = 3
    case unknown = 255

    init(bridgeValue: UInt8) {
        self = Self(rawValue: bridgeValue) ?? .unknown
    }
}

// PR1C: numeric disconnect diagnostics matching C++ ABI values.
enum WebsocketDisconnectCode: UInt16, Sendable {
    case none = 0
    case peerClosed = 1
    case tcpError = 2
    case tlsError = 3
    case websocketError = 4
    case watchdog = 5
    case localStop = 6
    case queueFailure = 7
    case unknown = 255

    init(bridgeValue: UInt16) {
        self = Self(rawValue: bridgeValue) ?? .unknown
    }
}

enum WebsocketStopOrigin: UInt16, Sendable {
    case none = 0
    case swiftTunnelStop = 1
    case swiftReconnect = 2
    case nativeFailure = 3
    case peer = 4
    case unknown = 255

    init(bridgeValue: UInt16) {
        self = Self(rawValue: bridgeValue) ?? .unknown
    }
}

protocol TunnelWebSocketTransport: AnyObject {
    func start() -> Bool
    func stop(origin: WebsocketStopOrigin) -> Bool
    func sendPacket(_ data: Data) -> WebsocketSendResult
}

protocol ReconnectScheduling: AnyObject {
    func scheduleReconnect(after seconds: Int, _ block: @escaping @Sendable () -> Void)
    func cancelReconnect()
}

protocol NetworkPathObserving: AnyObject {
    var isPathSatisfied: Bool { get }
    var onPathChanged: (@Sendable (Bool) -> Void)? { get set }
    func start()
    func stop()
}

protocol TunnelRuntimeLogging {
    func logRuntimeDecision(_ message: String)
}
