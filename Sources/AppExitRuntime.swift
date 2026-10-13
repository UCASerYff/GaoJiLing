import AppKit
import ApplicationServices

struct AppExitInspection: Sendable {
    var identity: ProcessIdentity?
    var windows: Int?
    var saved: AppExitSaveState
}

@MainActor struct AppExitAttempt {
    var accepted: Bool
    var hasExited: () -> Bool
}

/// Dependency boundary used by isolated tests. Production exposes only a
/// normal-quit request for the exact verified process, never a signal/command.
@MainActor struct AppExitDriver {
    var observations: ([AppExitRule], MetricsSample, Date) -> [AppExitObservation]
    var inspect: @Sendable (AppExitObservation) -> AppExitInspection
    var validate: (AppExitObservation) -> Bool
    var request: (AppExitObservation) -> AppExitAttempt
    static var live: Self {
        Self(observations: AppExitRuntime.observations, inspect: { observation in
            guard AppExitRuntime.identity(pid: observation.identity.pid) == observation.identity else {
                return AppExitInspection(identity: nil, windows: nil, saved: .unknown)
            }
            let status = AppExitRuntime.saveStatus(pid: observation.identity.pid)
            let confirmed = AppExitRuntime.identity(pid: observation.identity.pid)
            return AppExitInspection(identity: confirmed, windows: status.windows,
                saved: confirmed == observation.identity ? status.saved : .unknown)
        }, validate: { AppExitRuntime.revalidate($0) != nil }, request: { observation in
            guard let app = AppExitRuntime.revalidate(observation) else { return AppExitAttempt(accepted: false, hasExited: { false }) }
            return AppExitAttempt(accepted: app.terminate(), hasExited: { app.isTerminated })
        })
    }
}

enum AppExitRuntime {
    static func identity(pid: Int32) -> ProcessIdentity? {
        var start: UInt64 = 0; var uid: UInt32 = 0
        guard gjl_process_identity(pid, &start, &uid) != 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: start, uid: uid)
    }

    /// AX reads only application/window state, never document text. No prompt is
    /// generated here. Failure/unsupported "edited" attributes stay unknown.
    static func saveStatus(pid: Int32) -> (windows: Int?, saved: AppExitSaveState) {
        guard AXIsProcessTrusted() else { return (nil, .unknown) }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(app, 0.2) == .success else { return (nil, .unknown) }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], windows.count <= 32 else { return (nil, .unknown) }
        // No window does not prove that no background document exists. Require
        // an explicit app-level clean declaration in that case, or skip.
        if windows.isEmpty {
            return (0, editedState(app))
        }
        var unknown = false
        for window in windows {
            _ = AXUIElementSetMessagingTimeout(window, 0.2)
            let state = editedState(window)
            if state == .edited { return (windows.count, .edited) }
            if state == .unknown { unknown = true }
            var modal: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXModalAttribute as CFString, &modal) == .success,
               let modal, CFGetTypeID(modal) == CFBooleanGetTypeID(), (modal as? Bool) == true { return (windows.count, .unknown) }
        }
        return (windows.count, unknown ? .unknown : .clean)
    }
    private static func editedState(_ element: AXUIElement) -> AppExitSaveState {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEditedAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID(), let edited = value as? Bool else { return .unknown }
        return edited ? .edited : .clean
    }

    @MainActor static func observations(rules: [AppExitRule], sample: MetricsSample, now: Date) -> [AppExitObservation] {
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        var values: [AppExitObservation] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier, let url = app.bundleURL,
                  let rule = rules.first(where: { $0.enabled && $0.bundleID == bundle && $0.path == url.resolvingSymlinksInPath().path }),
                  let identity = identity(pid: app.processIdentifier) else { continue }
            guard let metadata = Bundle(url: url), AppExitProtection.reason(bundle: metadata, path: rule.path, name: rule.name) == nil else { continue }
            let process = sample.processes.first { $0.identities?.contains(identity) == true }
            let fresh = process?.observedAt.map { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 12 } == true && process?.availabilityReason == nil
            values.append(AppExitObservation(identity: identity, bundleID: bundle, path: rule.path, name: rule.name, observedAt: now,
                isFrontmost: active == app.processIdentifier || app.isActive,
                memoryBytes: fresh ? process.flatMap { $0.memoryBytes >= 0 && $0.memoryBytes < Double(UInt64.max) ? UInt64($0.memoryBytes) : nil } : nil,
                windowCount: nil, saveState: .unknown, idleSeconds: idle.isFinite && idle >= 0 ? idle : nil))
        }
        return values
    }

    @MainActor static func revalidate(_ observation: AppExitObservation) -> NSRunningApplication? {
        guard identity(pid: observation.identity.pid) == observation.identity,
              observation.identity.uid == geteuid(), let app = NSRunningApplication(processIdentifier: observation.identity.pid),
              !app.isTerminated, !app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier != observation.identity.pid,
              app.bundleIdentifier == observation.bundleID, app.bundleURL?.resolvingSymlinksInPath().path == observation.path else { return nil }
        return app
    }
}
