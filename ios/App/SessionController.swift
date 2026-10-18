import AVFoundation
import Foundation
import MurmurDictionary
import Observation
import UIKit

/// Owns the microphone for the iPad app and runs every dictation, whether it was started
/// by the keyboard or by the in-app button.
///
/// The shape is forced by two iPadOS rules:
///
/// 1. **Keyboards can't record.** So the keyboard asks this app to, over `Bridge`.
/// 2. **Apps can't *start* recording from the background.** `AVAudioEngine.start()` fails
///    once the app isn't frontmost. So a *session* starts the mic while the app is in front
///    and then keeps it running — with the `audio` background mode, a live input keeps the
///    process alive. Between dictations the audio is simply dropped; during one it's routed
///    to a fresh speech engine.
///
/// That's why the orange mic indicator stays on for the whole session, and why the session
/// stops itself after an idle timeout.
@MainActor
@Observable
final class SessionController {
    static let shared = SessionController()

    struct HistoryItem: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    private(set) var phase: SessionPhase = .off
    private(set) var liveText = ""
    private(set) var level: Float = 0
    /// Shown in the app and mirrored to the keyboard. Cleared when the next one succeeds.
    private(set) var message: String?
    private(set) var history: [HistoryItem] = []
    /// The most recent in-app dictation, for the "Try it here" box.
    private(set) var lastInAppResult = ""

    var idleMinutes: Int {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "idleMinutes") }
    }
    var cleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    var smartCleanup: Bool {
        didSet { UserDefaults.standard.set(smartCleanup, forKey: "smartCleanup") }
    }

    private let capture = AudioCapture()
    private let router = ChunkRouter()
    private var audioFormat: AVAudioFormat?
    private var ticker: Timer?
    private var lastActivity = Date()

    /// Identifies the utterance that currently owns `phase`. Cancelling or stopping replaces
    /// it, so an abandoned utterance that's still finishing in the background can't later
    /// overwrite the state of the one that followed it.
    private var utteranceToken = UUID()
    private var observers: [NSObjectProtocol] = []

    /// A forgotten toggle-mode dictation shouldn't record forever.
    private let maxUtterance: TimeInterval = 5 * 60

    private init() {
        let defaults = UserDefaults.standard
        idleMinutes = defaults.object(forKey: "idleMinutes") as? Int ?? 15
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        // On by default here, unlike the Mac: it falls back to the rule pass by itself
        // when Apple Intelligence is off, so there's no cost to trying.
        smartCleanup = defaults.object(forKey: "smartCleanup") as? Bool ?? true

        DictionaryFile.ensureExists()
        // A stale "ready" from a previous run that was killed would make the keyboard
        // think a session exists. The heartbeat would catch it too, but only after 3s.
        publish()

        Bridge.observe(.start) { [weak self] in
            guard let self else { return }
            let id = Bridge.defaults?.string(forKey: Bridge.Key.requestID)
            self.beginUtterance(requestID: id)
        }
        Bridge.observe(.stop) { [weak self] in self?.endUtterance() }
        Bridge.observe(.cancel) { [weak self] in self?.cancelUtterance() }

        observeAudioSession()
    }

    // MARK: - Session

    var isRunning: Bool { phase != .off }

    /// Opens the mic. Must be called while the app is in the foreground.
    func startSession() async {
        guard phase == .off else { return }

        guard await Self.requestMicrophone() else {
            report("Microphone access is off. Turn it on in Settings ▸ Apps ▸ Murmur.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` so starting Murmur doesn't silence Jump Desktop's audio or
            // whatever else is playing. `.allowBluetooth` lets AirPods be the mic.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true)

            // Started once up front, in the same order the Mac app uses — start, then ask
            // for the format. Starting installs the speech model if it's missing, which can
            // only be waited on sensibly now, while the app is on screen. The format is asked
            // once per session because the capture format can't change mid-session.
            let probe = AppleSpeechEngine()
            _ = try await probe.start()
            let preferred = await probe.preferredInputFormat()
            await probe.finish()
            guard let format = preferred else {
                throw TranscriptionError.noAudioFormat
            }
            audioFormat = format
            try startCapture(format: format)
        } catch {
            report("Couldn't start the microphone: \(error.localizedDescription)")
            stopSession()
            return
        }

        phase = .ready
        message = nil
        lastActivity = Date()
        startTicker()
        publish()
        Log.app.info("session started")
    }

    func stopSession(reason: String? = nil) {
        router.detach()
        utteranceToken = UUID()
        capture.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        ticker?.invalidate()
        ticker = nil
        phase = .off
        liveText = ""
        level = 0
        if let reason { message = reason }
        publish()
        let detail = reason ?? "by request"
        Log.app.info("session stopped: \(detail, privacy: .public)")
    }

    private func startCapture(format: AVAudioFormat) throws {
        let router = self.router
        try capture.start(
            outputFormat: format,
            onBuffer: { chunk in router.yield(chunk) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.updateLevel(level) }
            }
        )
    }

    // MARK: - Utterances

    func beginUtterance(requestID: String?) {
        guard phase == .ready else {
            Log.app.info("start ignored in phase \(self.phase.rawValue, privacy: .public)")
            // Answer anyway, or the keyboard would sit on "Working…" waiting for a result
            // that this request will never get.
            if let requestID {
                message = "Still finishing the last dictation. Try again in a moment."
                publish()
                answer(requestID: requestID, text: "")
            }
            return
        }
        phase = .listening
        liveText = ""
        message = nil
        lastActivity = Date()
        let token = UUID()
        utteranceToken = token

        // Unbounded, so audio captured while the engine is still spinning up is held rather
        // than dropped — that's what keeps the first word of every dictation.
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        router.attach(continuation)
        publish()

        let started = Date()
        Task {
            try? await Task.sleep(for: .seconds(maxUtterance))
            if phase == .listening, lastActivity <= started { endUtterance() }
        }

        Task { await run(stream: stream, requestID: requestID, token: token) }
    }

    func endUtterance() {
        guard phase == .listening else { return }
        phase = .processing
        level = 0
        router.detach()
        publish()
    }

    func cancelUtterance() {
        guard phase == .listening || phase == .processing else { return }
        router.detach()
        utteranceToken = UUID()
        phase = .ready
        liveText = ""
        level = 0
        lastActivity = Date()
        publish()
    }

    private func run(stream: AsyncStream<AudioChunk>, requestID: String?, token: UUID) async {
        let engine = AppleSpeechEngine()
        var raw = ""

        do {
            let results = try await engine.start()

            // Ordered: one task drains the stream, so buffers reach the engine in capture
            // order. It ends when `endUtterance` finishes the stream.
            let feeder = Task.detached(priority: .userInitiated) {
                for await chunk in stream { await engine.feed(chunk) }
            }
            let consumer = Task { @MainActor [weak self] () -> String in
                var latest = ""
                do {
                    for try await chunk in results {
                        latest = chunk.text
                        if self?.phase == .listening, self?.utteranceToken == token {
                            self?.liveText = chunk.text
                        }
                    }
                } catch {
                    Log.speech.error("results failed: \(error.localizedDescription)")
                }
                return latest
            }

            await feeder.value
            await engine.finish()
            raw = await consumer.value
        } catch {
            await engine.finish()
            guard token == utteranceToken else { return abandon(requestID) }
            router.detach()
            finish(requestID: requestID, text: "", failure: error.localizedDescription)
            return
        }

        guard token == utteranceToken else { return abandon(requestID) }
        let output = await process(raw)
        // Cleanup can take seconds; the user may have cancelled during it.
        guard token == utteranceToken else { return abandon(requestID) }
        finish(requestID: requestID, text: output, failure: nil)
    }

    /// A cancelled or superseded utterance still answers the keyboard, with nothing, but
    /// leaves the controller's state alone — it no longer owns it.
    private func abandon(_ requestID: String?) {
        if let requestID { answer(requestID: requestID, text: "") }
    }

    /// Cleanup, then the dictionary — same order as the Mac app, and for the same reason:
    /// the dictionary is the guaranteed pass, so it runs last and can't be switched off.
    private func process(_ raw: String) async -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }

        let cleaned: String
        if cleanupEnabled {
            let formatter: any TextFormatter = smartCleanup ? FoundationModelFormatter() : RuleBasedFormatter()
            cleaned = await formatter.format(raw)
        } else {
            cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return DictionaryStore.shared.corrector.apply(to: cleaned).text
    }

    private func finish(requestID: String?, text: String, failure: String?) {
        if let failure { report(failure) }

        if !text.isEmpty {
            history.insert(HistoryItem(date: Date(), text: text), at: 0)
            if history.count > 30 { history.removeLast(history.count - 30) }
            if requestID == nil { lastInAppResult = text }
        }

        // Answered even when empty, so the keyboard stops showing "Working…".
        if let requestID { answer(requestID: requestID, text: text) }

        liveText = ""
        lastActivity = Date()
        if phase != .off { phase = .ready }
        publish()
    }

    /// Text first, then the ID: the keyboard keys off the ID, so it must never see a new ID
    /// next to the previous request's text.
    private func answer(requestID: String, text: String) {
        guard let defaults = Bridge.defaults else { return }
        defaults.set(text, forKey: Bridge.Key.resultText)
        defaults.set(requestID, forKey: Bridge.Key.resultID)
        Bridge.post(.result)
    }

    // MARK: - Shared state

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if phase == .ready, idleMinutes > 0,
           Date().timeIntervalSince(lastActivity) > Double(idleMinutes) * 60 {
            stopSession(reason: "Session ended after \(idleMinutes) idle minutes.")
            return
        }
        publish()
    }

    /// Mirrors state into the App Group so the keyboard can draw it.
    private func publish() {
        guard let defaults = Bridge.defaults else { return }
        defaults.set(phase.rawValue, forKey: Bridge.Key.phase)
        defaults.set(Date().timeIntervalSince1970, forKey: Bridge.Key.heartbeat)
        defaults.set(liveText, forKey: Bridge.Key.liveText)
        defaults.set(Double(level), forKey: Bridge.Key.level)
        defaults.set(message ?? "", forKey: Bridge.Key.message)
    }

    private func report(_ text: String) {
        Log.app.error("\(text, privacy: .public)")
        message = text
        publish()
    }

    private func updateLevel(_ new: Float) {
        guard phase == .listening else { return }
        level += (new - level) * 0.35
    }

    // MARK: - Audio session events

    private func observeAudioSession() {
        let center = NotificationCenter.default

        // A phone or FaceTime call, Siri, or another app taking the mic. Recording can't be
        // resumed from the background afterwards, so the session ends cleanly instead.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                self?.stopSession(reason: "Another app took the microphone. Start a new session.")
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopSession(reason: "Audio system reset. Start a new session.") }
        })

        // Plugging in or unplugging a mic, or AirPods connecting, stops the engine. Try to
        // pick straight back up; if that's refused (it will be from the background), stop.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartCaptureAfterRouteChange() }
        })
    }

    private func restartCaptureAfterRouteChange() {
        guard phase != .off, let audioFormat else { return }
        capture.stop()
        do {
            try startCapture(format: audioFormat)
            Log.audio.info("capture restarted after route change")
        } catch {
            stopSession(reason: "The microphone changed. Start a new session.")
        }
    }

    private static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        default: return false
        }
    }
}

/// Hands audio from the real-time thread to whichever utterance is listening, if any.
///
/// The audio thread can't touch main-actor state, so the current destination sits behind
/// a lock. Between utterances there is no destination and buffers are dropped.
final class ChunkRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func attach(_ continuation: AsyncStream<AudioChunk>.Continuation) {
        lock.withLock { self.continuation = continuation }
    }

    /// Finishing the stream is what tells the utterance's feeder that the audio is over.
    func detach() {
        let old = lock.withLock { () -> AsyncStream<AudioChunk>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        old?.finish()
    }

    func yield(_ chunk: AudioChunk) {
        lock.withLock { _ = continuation?.yield(chunk) }
    }
}

/// The dictionary text file shared with `DictionaryStore`.
///
/// `DictionaryStore` only starts watching the file if it exists when the store is created,
/// so this makes sure it does — otherwise edits from the in-app editor would never load.
@MainActor
enum DictionaryFile {
    static func ensureExists() {
        let url = DictionaryStore.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? template.write(to: url, atomically: true, encoding: .utf8)
    }

    static func read() -> String {
        (try? String(contentsOf: DictionaryStore.fileURL, encoding: .utf8)) ?? template
    }

    static func write(_ text: String) {
        try? text.write(to: DictionaryStore.fileURL, atomically: true, encoding: .utf8)
    }

    private static let template = """
        # Murmur dictionary — one entry per line.
        #
        #   Anthropic                 a word the speech engine should know
        #   cloud code -> Claude Code when you hear X, write Y
        #   # off: some rule -> Rule  a disabled entry

        """
}
