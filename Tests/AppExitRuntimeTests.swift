import AppKit
import ApplicationServices

/// Exercises the production saveStatus combination logic with injected AX
/// replies. AXUIElements below are local opaque tokens: no attribute call,
/// process enumeration, TCC prompt, application launch or quit is performed.
@main struct AppExitRuntimeTests {
    typealias Reply = (error: AXError, value: CFTypeRef?)
    struct Failure: Error { let message: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static let clean: Reply = (.success, kCFBooleanFalse)
    static let edited: Reply = (.success, kCFBooleanTrue)

    final class Fixture {
        let app = AXUIElementCreateApplication(1_234_500_001)
        let windows = [AXUIElementCreateApplication(1_234_500_002), AXUIElementCreateApplication(1_234_500_003)]
        var trusted = true
        var appTimeout: AXError = .success
        var windowTimeout: AXError = .success
        var appEdited: Reply = AppExitRuntimeTests.clean
        var windowEdited: [Reply] = [AppExitRuntimeTests.clean, AppExitRuntimeTests.clean]
        var windowModal: [Reply] = [AppExitRuntimeTests.clean, AppExitRuntimeTests.clean]
        var windowCount = 1
        var windowsReply: Reply?
        var calls: [String] = []

        func reader() -> AppExitRuntime.AXReader {
            AppExitRuntime.AXReader(isTrusted: {
                self.calls.append("trusted"); return self.trusted
            }, application: { _ in
                self.calls.append("application"); return self.app
            }, setTimeout: { element, timeout in
                self.calls.append(CFEqual(element, self.app) ? "app.timeout" : "window.timeout")
                guard timeout == Float(0.2) else { return .failure }
                return CFEqual(element, self.app) ? self.appTimeout : self.windowTimeout
            }, copyAttribute: { element, attribute in
                if CFEqual(element, self.app) {
                    if CFEqual(attribute, kAXEditedAttribute as CFString) {
                        self.calls.append("app.edited"); return self.appEdited
                    }
                    if CFEqual(attribute, kAXWindowsAttribute as CFString) {
                        self.calls.append("app.windows")
                        if let override = self.windowsReply { return override }
                        return (.success, Array(self.windows.prefix(self.windowCount)) as CFArray)
                    }
                }
                if let index = self.windows.firstIndex(where: { CFEqual(element, $0) }) {
                    if CFEqual(attribute, kAXEditedAttribute as CFString) {
                        self.calls.append("window\(index).edited"); return self.windowEdited[index]
                    }
                    if CFEqual(attribute, kAXModalAttribute as CFString) {
                        self.calls.append("window\(index).modal"); return self.windowModal[index]
                    }
                }
                self.calls.append("unexpected-attribute"); return (.failure, nil)
            })
        }
        func status() -> (windows: Int?, saved: AppExitSaveState) {
            AppExitRuntime.saveStatus(pid: 1_234_500_001, reader: reader())
        }
    }

    static func number(_ value: Int32) -> CFNumber {
        var value = value
        return CFNumberCreate(nil, .sInt32Type, &value)!
    }
    static func expect(_ fixture: Fixture, _ windows: Int?, _ state: AppExitSaveState, _ message: String) throws {
        let result = fixture.status()
        try require(result.windows == windows && result.saved == state, message)
        try require(!fixture.calls.contains("unexpected-attribute"), "only the declared application/window attributes may be read")
    }
    static func main() throws {
        let falseNumber = number(0), trueNumber = number(1)
        try require(CFGetTypeID(falseNumber) != CFBooleanGetTypeID() && CFGetTypeID(trueNumber) != CFBooleanGetTypeID(), "numeric fixtures must remain CFNumber, not bridged Boolean")

        let one = Fixture()
        try expect(one, 1, .clean, "explicit app/window Edited false and Modal false establish clean")
        try require(one.calls == ["trusted", "application", "app.timeout", "app.edited", "app.windows", "window.timeout", "window0.edited", "window0.modal"], "the app declaration must be checked before windows")
        let zero = Fixture(); zero.windowCount = 0
        try expect(zero, 0, .clean, "zero windows require an explicit clean application declaration")
        let two = Fixture(); two.windowCount = 2
        try expect(two, 2, .clean, "every known window must be checked")

        let appEdited = Fixture(); appEdited.appEdited = edited
        try expect(appEdited, nil, .edited, "application Edited true takes precedence over clean window declarations")
        try require(!appEdited.calls.contains("app.windows"), "app Edited true must short-circuit further reads")
        let windowEdited = Fixture(); windowEdited.windowEdited[0] = edited
        try expect(windowEdited, 1, .edited, "window Edited true blocks exit")
        try require(!windowEdited.calls.contains("window0.modal"), "known edits need no modal probe")

        let unsupported: Reply = (.attributeUnsupported, nil)
        let uncertain: [Reply] = [(.failure, nil), (.cannotComplete, nil),
            (.apiDisabled, nil), (.invalidUIElement, nil), (.success, nil),
            (.success, falseNumber), (.success, trueNumber), (.success, "false" as CFString),
            (.failure, kCFBooleanFalse), (.attributeUnsupported, kCFBooleanFalse),
            (.attributeUnsupported, kCFBooleanTrue), (.attributeUnsupported, falseNumber),
            (.attributeUnsupported, "false" as CFString)]
        for (index, reply) in uncertain.enumerated() {
            let app = Fixture(); app.appEdited = reply
            try expect(app, nil, .unknown, "unavailable/malformed app Edited remains unknown, case \(index)")
            try require(!app.calls.contains("app.windows"), "unknown/error or inconsistent unsupported app declarations cannot gain window fallback")
            let zero = Fixture(); zero.windowCount = 0; zero.appEdited = reply
            try expect(zero, nil, .unknown, "zero windows cannot turn an unknown app declaration into clean, case \(index)")
            let window = Fixture(); window.windowEdited[0] = reply
            try expect(window, 1, .unknown, "unavailable/malformed window Edited remains unknown, case \(index)")
            let modal = Fixture(); modal.windowModal[0] = reply
            try expect(modal, 1, .unknown, "unavailable/malformed Modal remains unknown, case \(index)")
        }
        let fallback = Fixture(); fallback.appEdited = unsupported
        try expect(fallback, 1, .clean, "exact app unsupported with no value may use a nonempty all-known-clean window list")
        let fallbackTwo = Fixture(); fallbackTwo.appEdited = unsupported; fallbackTwo.windowCount = 2
        try expect(fallbackTwo, 2, .clean, "fallback requires every window to be known clean")
        let fallbackEmpty = Fixture(); fallbackEmpty.appEdited = unsupported; fallbackEmpty.windowCount = 0
        try expect(fallbackEmpty, 0, .unknown, "unsupported app plus no windows cannot establish clean")
        for (index, reply) in (uncertain + [unsupported]).enumerated() {
            let window = Fixture(); window.appEdited = unsupported; window.windowEdited[0] = reply
            try expect(window, 1, .unknown, "app unsupported never relaxes unknown window Edited, case \(index)")
            let modal = Fixture(); modal.appEdited = unsupported; modal.windowModal[0] = reply
            try expect(modal, 1, .unknown, "app unsupported never relaxes unknown Modal, case \(index)")
        }
        let fallbackEdited = Fixture(); fallbackEdited.appEdited = unsupported; fallbackEdited.windowEdited[0] = edited
        try expect(fallbackEdited, 1, .edited, "window edits are protected under the unsupported app fallback")
        let fallbackModal = Fixture(); fallbackModal.appEdited = unsupported; fallbackModal.windowModal[0] = edited
        try expect(fallbackModal, 1, .unknown, "Modal true is protected under the unsupported app fallback")
        let fallbackTimeout = Fixture(); fallbackTimeout.appEdited = unsupported; fallbackTimeout.windowTimeout = .failure
        try expect(fallbackTimeout, 1, .unknown, "fallback cannot bypass window timeout failures")
        try require(!fallbackTimeout.calls.contains("window0.edited") && !fallbackTimeout.calls.contains("window0.modal"), "fallback timeout failure prevents all window attribute reads")
        let fallbackMixed = Fixture(); fallbackMixed.appEdited = unsupported; fallbackMixed.windowCount = 2
        fallbackMixed.windowEdited[1] = (.failure, nil)
        try expect(fallbackMixed, 2, .unknown, "one clean window cannot cover another unknown window under fallback")
        print("PASS: exact unsupported app fallback requires nonempty known-clean windows; inconsistent error/value and every unknown window remain protected")

        let modal = Fixture(); modal.windowModal[0] = edited
        try expect(modal, 1, .unknown, "Modal true blocks clean even if Edited flags are false")
        let mixed = Fixture(); mixed.windowCount = 2; mixed.windowEdited[0] = (.failure, nil)
        try expect(mixed, 2, .unknown, "a later clean window cannot erase an earlier unknown window")
        let editedAfterUnknown = Fixture(); editedAfterUnknown.windowCount = 2
        editedAfterUnknown.windowEdited = [(.failure, nil), edited]
        try expect(editedAfterUnknown, 2, .edited, "a later explicit edit is still protected after an unknown window")

        let untrusted = Fixture(); untrusted.trusted = false
        try expect(untrusted, nil, .unknown, "denied trust must stop before application element creation")
        try require(untrusted.calls == ["trusted"], "trust failure must not attempt AX attributes")
        let appTimeout = Fixture(); appTimeout.appTimeout = .failure
        try expect(appTimeout, nil, .unknown, "application timeout configuration failure blocks all reads")
        try require(!appTimeout.calls.contains("app.edited"), "no application attributes after timeout failure")
        let windowTimeout = Fixture(); windowTimeout.windowTimeout = .failure
        try expect(windowTimeout, 1, .unknown, "window timeout configuration failure remains unknown")
        try require(!windowTimeout.calls.contains("window0.edited") && !windowTimeout.calls.contains("window0.modal"), "no window attributes after timeout failure")
        let nonAXWindows = [kCFBooleanFalse!, "not an AX element" as CFString] as [AnyObject]
        let mixedWindows = [one.windows[0], "not an AX element" as CFString] as [AnyObject]
        for (label, elements) in [("CFBoolean/CFString", nonAXWindows), ("AXUIElement/CFString", mixedWindows)] {
            for appReply in [clean, unsupported] {
                let malformed = Fixture(); malformed.appEdited = appReply; malformed.windowsReply = (.success, elements as CFArray)
                try expect(malformed, nil, .unknown, "malformed CFArray \(label) cannot be accepted as AX windows")
                try require(!malformed.calls.contains("window.timeout"), "every window element type must be validated before any window is expanded")
            }
            print("PASS: rejected malformed window CFArray containing \(label) before expansion")
        }
        for reply: Reply in [(.failure, nil), (.success, nil), (.success, "not windows" as CFString),
                             (.success, Array(repeating: one.windows[0], count: 33) as CFArray)] {
            for appReply in [clean, unsupported] {
                let invalid = Fixture(); invalid.appEdited = appReply; invalid.windowsReply = reply
                try expect(invalid, nil, .unknown, "failed, malformed or excessive window lists remain unknown")
                try require(!invalid.calls.contains("window.timeout"), "invalid window lists are not expanded")
            }
        }
        print("PASS: production AppOFF AX combination, strict Boolean types, raw failures, timeout short-circuits and multi-window protection; injected replies only")
    }
}
