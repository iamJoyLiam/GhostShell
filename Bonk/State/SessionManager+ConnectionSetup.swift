//
//  SessionManager+ConnectionSetup.swift
//  Bonk
//
//  Connection config resolution extracted from connectTab to keep the function
//  body within size limits. Same-file logic, moved verbatim.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

// MARK: - SessionManager Connection Setup

/// Resolved inputs for one connectTab attempt.
struct ConnectionSetup {
    var service: SSHNetworkService
    var effectiveConfig: SSHConnectionConfig
    let config: SSHConnectionConfig
    let configWithGen: SSHConnectionConfig
    let requirements: SSHConnectionRequirements
    let decision: SSHConnectionDecision
    let effectiveEphemeral: SessionManager.AuthRetryResult?
}

extension SessionManager {
    /// Merges retry state, builds configs, and runs VNext routing/lifecycle.
    /// Returns nil (after marking the phase failed) when resolution fails.
    func resolveConnectionSetup(
        for tab: TerminalTab,
        session: TerminalSession,
        generation: UUID,
        passwordOverride: String?,
        ephemeralResult: AuthRetryResult?
    ) async -> ConnectionSetup? {
        // Merge transient retry result; keep for cleaning retry, clear on success (300ms)
        let effectiveEphemeral = ephemeralResult ?? transientAuthResults[tab.id]
        if let effectiveResult = effectiveEphemeral { transientAuthResults[tab.id] = effectiveResult }
        guard let config = preparedConfig(for: tab, session: session, passwordOverride: passwordOverride, ephemeralResult: effectiveEphemeral) else {
            setPhase(session, to: .failed("resolve config"), host: tab.hostItem.host, engine: "Resolver", reason: "config")
            return nil
        }
        // Inject generation for full-chain propagation
        var configWithGen = config
        configWithGen = SSHConnectionConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            jumpHost: config.jumpHost,
            maxReconnectAttempts: config.maxReconnectAttempts,
            baseReconnectDelay: config.baseReconnectDelay,
            algorithmRequirements: config.algorithmRequirements,
            bypassControlMaster: config.bypassControlMaster,
            generation: generation
        )
        setPhase(session, to: .connectingTransport, host: configWithGen.host, engine: "Resolver", reason: "VNext routing")
        // Lifecycle consumes config with ephemeralResult to avoid HostItem overwrite
        let lifecycle = SSHSessionLifecycle(networkService: SSHNetworkService(hostKeyStore: hostKeyStore), hostKeyStore: hostKeyStore)
        guard let resolved = await lifecycle.resolve(config: configWithGen, forcedCompatibility: tab.hostItem.forceCompatibility == true) else {
            setPhase(session, to: .failed("resolve"), host: tab.hostItem.host, engine: "Lifecycle", reason: "resolve")
            return nil
        }
        let vnextReq = resolved.requirements
        let vnextCached: SSHSessionCoordinator.CachedProfile? = nil
        let vnextDecision = resolved.decision
        logVNextDecision(vnextDecision, config: config, requirements: vnextReq)
        var service = resolved.service
        var effectiveConfig = resolved.effectiveConfig
        // Ensure generation forwarded to effectiveConfig
        if effectiveConfig.generation == nil {
            effectiveConfig = SSHConnectionConfig(
                host: effectiveConfig.host,
                port: effectiveConfig.port,
                username: effectiveConfig.username,
                authMethod: effectiveConfig.authMethod,
                jumpHost: effectiveConfig.jumpHost,
                maxReconnectAttempts: effectiveConfig.maxReconnectAttempts,
                baseReconnectDelay: effectiveConfig.baseReconnectDelay,
                algorithmRequirements: effectiveConfig.algorithmRequirements,
                bypassControlMaster: effectiveConfig.bypassControlMaster,
                generation: generation
            )
        }
        if let effectiveResult = effectiveEphemeral {
            let src = ephemeralResult == nil ? "transient" : "ephemeral"
            let passwordLength = effectiveResult.password.count
            let fingerprint = passwordLength > 0 ? OpenSSHBackend.passwordFingerprint(effectiveResult.password) : "-"
            Log.session.info("[AUTH_RETRY] source=\(src, privacy: .public) passwordLength=\(passwordLength) passwordFingerprint=\(fingerprint, privacy: .public) authType=\(effectiveResult.authType.rawValue, privacy: .public) effectiveHost=\(effectiveConfig.host, privacy: .public)")
        }
        if case .compatibility = vnextDecision, let algos = vnextCached?.algorithms, !algos.isEmpty {
            Log.session.info("[VNext] Using cached compat algorithms: kex=\(algos.kex)")
        }
        return ConnectionSetup(
            service: service,
            effectiveConfig: effectiveConfig,
            config: config,
            configWithGen: configWithGen,
            requirements: vnextReq,
            decision: vnextDecision,
            effectiveEphemeral: effectiveEphemeral
        )
    }
}
