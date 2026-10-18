import Foundation

/// The wire between the keyboard extension and the app.
///
/// They are separate processes, and the keyboard is not allowed to record audio — iPadOS
/// blocks microphone access from keyboard extensions outright. So the app owns the mic and
/// the speech engine, and the keyboard is a remote control:
///
/// - **Keyboard → app:** Darwin notifications (`start`, `stop`, `cancel`). They cross
///   process boundaries instantly and need no shared memory. The request ID rides along
///   in the shared defaults, because Darwin notifications carry no payload.
/// - **App → keyboard:** the shared App Group defaults, which the keyboard polls while
///   it's on screen, plus a `result` notification so finished text lands immediately.
///
/// Both sides need the App Group entitlement, and the keyboard only gets it when the user
/// turns on **Allow Full Access** — without that, `defaults` is nil on the keyboard side.
enum Bridge {
    /// Injected through Info.plist from `Config.xcconfig`, so the group ID lives in one place.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "MurmurAppGroup") as? String ?? ""

    static let defaults = UserDefaults(suiteName: appGroup)

    static let urlScheme = "murmur-dictate"
    /// Opened by the keyboard when no session is running. The app must be in the
    /// foreground to start recording, which is the whole reason this round trip exists.
    static let sessionURL = URL(string: "\(urlScheme)://session")!

    enum Key {
        static let heartbeat = "session.heartbeat"
        static let phase = "session.phase"
        static let liveText = "session.liveText"
        static let level = "session.level"
        static let message = "session.message"
        static let requestID = "request.id"
        static let resultID = "result.id"
        static let resultText = "result.text"
    }

    enum Signal: String {
        case start = "murmur.dictate.start"
        case stop = "murmur.dictate.stop"
        case cancel = "murmur.dictate.cancel"
        case result = "murmur.dictate.result"
    }

    /// The heartbeat is written every quarter second while a session runs. Past this, the
    /// app has been suspended or killed even if `phase` still says otherwise — a killed
    /// process can't clean up after itself.
    static let heartbeatTimeout: TimeInterval = 3

    static var isSessionAlive: Bool {
        guard let defaults else { return false }
        let beat = defaults.double(forKey: Key.heartbeat)
        let phase = SessionPhase(rawValue: defaults.string(forKey: Key.phase) ?? "") ?? .off
        return phase != .off && Date().timeIntervalSince1970 - beat < heartbeatTimeout
    }

    static func post(_ signal: Signal) {
        DarwinCenter.shared.post(signal.rawValue)
    }

    static func observe(_ signal: Signal, _ handler: @escaping @MainActor () -> Void) {
        DarwinCenter.shared.observe(signal.rawValue, handler)
    }
}

/// What the app is doing, as the keyboard sees it.
enum SessionPhase: String {
    /// No session — the keyboard has to bounce through the app to start one.
    case off
    /// Mic open and idle; a tap on the keyboard starts dictating instantly.
    case ready
    case listening
    case processing
}

/// Thin wrapper over the Darwin notify center, whose C callback can't capture context.
///
/// One instance per process; the observer pointer handed to CoreFoundation is this object,
/// and the callback finds its way back to the Swift handler by notification name.
final class DarwinCenter: @unchecked Sendable {
    static let shared = DarwinCenter()

    /// Only touched on the main thread.
    private var handlers: [String: @MainActor () -> Void] = [:]
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    func post(_ name: String) {
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Replaces any earlier handler for `name`. A keyboard extension process can outlive
    /// several view controllers, and only the newest one should react.
    func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        let isNew = handlers[name] == nil
        handlers[name] = handler
        guard isNew else { return }

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let key = name.rawValue as String
                let center = Unmanaged<DarwinCenter>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { center.handlers[key]?() }
                }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }
}
