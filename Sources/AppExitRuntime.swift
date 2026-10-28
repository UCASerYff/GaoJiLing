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

    /// Internal dependency boundary for the production saved-state reader.
    /// Tests inject raw AX replies; the live implementation never prompts.
    struct AXReader {
        var isTrusted: () -> Bool
        var application: (Int32) -> AXUIElement
        var setTimeout: (AXUIElement, Float) -> AXError
        var copyAttribute: (AXUIElement, CFString) -> (error: AXError, value: CFTypeRef?)
        static var live: Self {
            Self(isTrusted: { AXIsProcessTrusted() }, application: { AXUIElementCreateApplication($0) },
                setTimeout: { AXUIElementSetMessagingTimeout($0, $1) }, copyAttribute: { element, attribute in
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(element, attribute, &value)
                    return (error, value)
                })
        }
    }

    /// AX reads only application/window state, never document text or prompts.
    /// Only app Edited attributeUnsupported with no value may fall back to a
    /// nonempty list of known-clean windows. Other failures and unknowns skip.
    static func saveStatus(pid: Int32) -> (windows: Int?, saved: AppExitSaveState) {
        saveStatus(pid: pid, reader: .live)
    }
    static func saveStatus(pid: Int32, reader: AXReader) -> (windows: Int?, saved: AppExitSaveState) {
        guard reader.isTrusted() else { return (nil, .unknown) }
        let app = reader.application(pid)
        guard reader.setTimeout(app, 0.2) == .success else { return (nil, .unknown) }
        // An explicit app edit always takes precedence over window flags.
        // An unsupported error carrying a value is inconsistent, not a fallback.
        let appReply = reader.copyAttribute(app, kAXEditedAttribute as CFString)
        let appEdited = booleanAttribute(appReply)
        let windowFallback = appReply.error == .attributeUnsupported && appReply.value == nil
        if appEdited == true { return (nil, .edited) }
        guard appEdited == false || windowFallback else { return (nil, .unknown) }
        let reply = reader.copyAttribute(app, kAXWindowsAttribute as CFString)
        // Core Foundation element casts do not prove each array member's type.
        // Validate every member before passing any of them to an AX operation.
        guard reply.error == .success, let value = reply.value,
              CFGetTypeID(value) == CFArrayGetTypeID(), let elements = value as? [AnyObject],
              elements.count <= 32, elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }),
              let windows = elements as? [AXUIElement] else { return (nil, .unknown) }
        if windows.isEmpty { return (0, appEdited == false ? .clean : .unknown) }
        var unknown = false
        for window in windows {
            guard reader.setTimeout(window, 0.2) == .success else { return (windows.count, .unknown) }
            if let edited = booleanAttribute(reader.copyAttribute(window, kAXEditedAttribute as CFString)) {
                if edited { return (windows.count, .edited) }
            } else { unknown = true }
            // Only an explicit Boolean false excludes a modal/save operation.
            if booleanAttribute(reader.copyAttribute(window, kAXModalAttribute as CFString)) != false { unknown = true }
        }
        return (windows.count, unknown ? .unknown : .clean)
    }
    private static func booleanAttribute(_ reply: (error: AXError, value: CFTypeRef?)) -> Bool? {
        guard reply.error == .success, let value = reply.value,
              CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else { return nil }
        return boolean
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
