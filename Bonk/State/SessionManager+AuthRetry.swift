//
//  SessionManager+AuthRetry.swift
//  Bonk
//
//  Auth retry sheet flow extracted from SessionManager to keep the class body
//  within size limits. Same-file logic, moved verbatim.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

// MARK: - SessionManager Auth Retry

extension SessionManager {
    private func promptForPassword(username: String, host: String) async -> String? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = I18n.shared.t(.authFailedTitle)
        let displayUser = username.isEmpty ? "?" : username
        alert.informativeText = "\(displayUser)@\(host)\n\(I18n.shared.t(.authFailedMessage))"

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let field = AutoEnglishSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = I18n.shared.t(.password)
        container.addSubview(field)
        alert.accessoryView = container

        alert.addButton(withTitle: I18n.shared.t(.retry))
        alert.addButton(withTitle: I18n.shared.t(.cancel))
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    /// New auth retry via sheet - shows AuthRetrySheet with full auth methods and raw error detail.
    func requestAuthRetry(for tab: TerminalTab, rawError: String) async -> AuthRetryResult? {
        let last = lastRetryPassword[tab.id]
        return await withCheckedContinuation { continuation in
            authRetryContinuation = continuation
            authRetryRequest = AuthRetryRequest(tab: tab, host: tab.hostItem, rawError: rawError, lastAttemptPassword: last)
        }
    }

    func completeAuthRetry(with result: AuthRetryResult?) {
        if let authResult = result, !authResult.password.isEmpty, let tabID = authRetryRequest?.tab.id {
            lastRetryPassword[tabID] = authResult.password
        } else if result == nil, let tabID = authRetryRequest?.tab.id {
            // Keep last input for next prefill
        }
        authRetryContinuation?.resume(returning: result)
        authRetryContinuation = nil
        authRetryRequest = nil
    }

    func completeAuthRetry(with host: HostItem) {
        let result = AuthRetryResult(password: host.loadPassword() ?? "", privateKeyPEM: host.loadPrivateKey() ?? "", certificatePEM: host.loadCertificate() ?? "", secureEnclaveTag: host.loadSecureEnclaveKeyTag(), credentialID: host.credentialRef?.persistentModelID, authType: host.authType)
        completeAuthRetry(with: result)
    }

    func cancelAuthRetry() {
        authRetryContinuation?.resume(returning: nil)
        authRetryContinuation = nil
        authRetryRequest = nil
    }

    /// Typed auth failure from reconnect PTY (not via setupPTYSession) must show sheet
    /// Citadel throws sync, OpenSSH tails async; Prompts=1 fails fast to sheet
    func handleServiceAuthFailure(_ failure: SSHFailure, for tab: TerminalTab) async {
        guard tabs.contains(where: { $0.id == tab.id }), let session = tab.session else { return }
        guard case let .authentication(authFailure) = failure else { return }
        let display = SSHErrorMessageParser.explain(authFailure.message, host: tab.hostItem.host, jumpHost: tab.hostItem.jumpHostRef?.host) ?? authFailure.message
        // Single sheet path
        if case .authentication = session.failureReason, session.phase == .failed(display), isShowingDialog(for: tab.id) { return }
        session.failureReason = failure
        setPhase(session, to: .failed(display), host: tab.hostItem.host, engine: "OpenSSH", reason: "authFailed")
        session.signalAuthFailure()
        session.errorMessage = display
        Log.session.error("[SSH_FAILURE] type=authentication backend=openssh (service) msg=\(display.prefix(120), privacy: .public)")
        Log.session.info("[RECOVERY_GATE] blocked=true reason=authenticationFailed (service)")
        guard !isShowingDialog(for: tab.id) else { return }
        setShowingDialog(true, for: tab.id)
        defer { setShowingDialog(false, for: tab.id) }
        if retryState(for: tab.id) == .dialogShown {
            Log.session.error("[AUTH_RETRY] service reconnect failed; cleaning")
            OpenSSHBackend.cleanupOrphanedMuxes()
            setRetryState(.cleanupDone, for: tab.id)
            guard tabs.contains(where: { $0.id == tab.id }) else { return }
            sessionStore.markConnected(tab.id)
            let reuse = transientAuthResults[tab.id]
            if let reuseResult = reuse, reuseResult.authType == .password, !reuseResult.password.isEmpty {
                await connectTab(tab, passwordOverride: reuseResult.password, ephemeralResult: reuseResult, resetAuthRetry: false)
            } else {
                await connectTab(tab, ephemeralResult: reuse, resetAuthRetry: false)
            }
            if case .failed = tab.session?.phase {
                // Keep cleanupDone for next failure
            } else {
                setRetryState(.idle, for: tab.id)
            }
            return
        }
        if retryState(for: tab.id) == .cleanupDone {
            Log.session.error("[AUTH_RETRY] service second failure; re-show sheet")
            setRetryState(.idle, for: tab.id)
        }
        setRetryState(.dialogShown, for: tab.id)
        guard let result = await requestAuthRetry(for: tab, rawError: authFailure.message) else {
            setRetryState(.idle, for: tab.id); return
        }
        let passwordLength = result.password.count
        let fingerprint = passwordLength > 0 ? OpenSSHBackend.passwordFingerprint(result.password) : "-"
        Log.session.info("[AUTH_RETRY] source=ephemeral (service) passwordLength=\(passwordLength) passwordFingerprint=\(fingerprint, privacy: .public) authType=\(result.authType.rawValue, privacy: .public)")
        transientAuthResults[tab.id] = result
        // Isolated retry via ControlMaster bypass
        if result.authType == .password, !result.password.isEmpty {
            await connectTab(tab, passwordOverride: result.password, ephemeralResult: result, resetAuthRetry: false)
        } else {
            await connectTab(tab, ephemeralResult: result, resetAuthRetry: false)
        }
        if case .failed = tab.session?.phase {
            transientAuthResults[tab.id] = nil
        } else {
            setRetryState(.idle, for: tab.id)
        }
    }
}
