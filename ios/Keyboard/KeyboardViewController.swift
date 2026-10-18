import UIKit

/// The Murmur keyboard: a big mic button plus the few keys you need around dictation.
///
/// It never touches audio — iPadOS doesn't allow keyboards to record. It tells the app to
/// start and stop over `Bridge`, shows what the app reports, and types the result with
/// `textDocumentProxy`, which is the only way any third-party code can put text into
/// another app's field. Inside Jump Desktop that text becomes keystrokes on the Mac.
///
/// The mic button does two things, like Wispr Flow's:
/// - **Hold** past `holdThreshold` and release → push-to-talk.
/// - **Tap** → hands-free; tap again to finish.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let levelBar = UIProgressView(progressViewStyle: .bar)
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)

    private var poller: Timer?

    private enum Mode {
        case idle
        /// Held down; releasing finishes.
        case holding(since: Date)
        /// Tapped; the next tap finishes.
        case handsFree
        /// Stop sent, waiting for the app's result.
        case waiting
    }

    private var mode: Mode = .idle
    /// The request this keyboard is waiting on. Results for any other ID are ignored, so
    /// a stale result can never be typed into a field you've since moved to.
    private var pendingRequestID: String?
    /// Set when a press stops a hands-free dictation, so its release isn't read as a tap.
    private var swallowRelease = false
    /// What the last dictation typed, for Undo.
    private var lastInserted = ""

    private let holdThreshold: TimeInterval = 0.35

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        Bridge.observe(.result) { [weak self] in self?.handleResult() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        globeButton.isHidden = !needsInputModeSwitchKey
        poller?.invalidate()
        poller = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poller?.invalidate()
        poller = nil
        // The field this dictation was meant for is going away; don't type into the next one.
        switch mode {
        case .holding, .handsFree, .waiting:
            Bridge.post(.cancel)
            pendingRequestID = nil
            mode = .idle
        case .idle:
            break
        }
    }

    // MARK: - Mic

    @objc private func micDown() {
        guard hasFullAccess, Bridge.defaults != nil else {
            statusLabel.text = "Turn on Allow Full Access: Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Murmur."
            return
        }

        switch mode {
        case .handsFree:
            swallowRelease = true
            stop()
            return
        case .holding, .waiting:
            return
        case .idle:
            break
        }

        guard Bridge.isSessionAlive else {
            openContainingApp()
            return
        }

        let id = UUID().uuidString
        pendingRequestID = id
        Bridge.defaults?.set(id, forKey: Bridge.Key.requestID)
        Bridge.post(.start)
        mode = .holding(since: Date())
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refresh()
    }

    @objc private func micUp() {
        if swallowRelease {
            swallowRelease = false
            return
        }
        guard case .holding(let since) = mode else { return }

        if Date().timeIntervalSince(since) >= holdThreshold {
            stop()
        } else {
            mode = .handsFree
            refresh()
        }
    }

    private func stop() {
        Bridge.post(.stop)
        mode = .waiting
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refresh()
    }

    private func handleResult() {
        guard let defaults = Bridge.defaults,
              let id = defaults.string(forKey: Bridge.Key.resultID),
              id == pendingRequestID
        else { return }

        pendingRequestID = nil
        mode = .idle
        let text = defaults.string(forKey: Bridge.Key.resultText) ?? ""
        if !text.isEmpty { insert(text) }
        refresh()
    }

    /// Adds a separating space when the text lands right after a word. Fields that don't
    /// report their context (Jump Desktop's, for one) get the text exactly as cleaned.
    private func insert(_ text: String) {
        var output = text
        if let before = textDocumentProxy.documentContextBeforeInput,
           let last = before.last, !last.isWhitespace,
           let first = output.first, !first.isWhitespace, !first.isPunctuation {
            output = " " + output
        }
        textDocumentProxy.insertText(output)
        lastInserted = output
    }

    // MARK: - Keys

    @objc private func undoTapped() {
        guard !lastInserted.isEmpty else { return }
        for _ in lastInserted { textDocumentProxy.deleteBackward() }
        lastInserted = ""
        refresh()
    }

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }
    @objc private func deleteTapped() { textDocumentProxy.deleteBackward() }

    // MARK: - Opening the app

    /// Keyboards can't call `UIApplication.open` — it's marked unavailable to extensions —
    /// but the `UIApplication` object is still in the responder chain. This is the same
    /// route other dictation keyboards use to hand off to their app. It's private API in
    /// spirit, which is fine for a personal build and a risk for App Store review.
    private func openContainingApp() {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, Bridge.sessionURL as NSURL, NSDictionary(), nil)
                statusLabel.text = "Opening Murmur…"
                return
            }
            responder = current.next
        }
        statusLabel.text = "Open the Murmur app and tap Start session."
    }

    // MARK: - Display

    private func refresh() {
        let defaults = Bridge.defaults
        let alive = Bridge.isSessionAlive
        let phase = SessionPhase(rawValue: defaults?.string(forKey: Bridge.Key.phase) ?? "") ?? .off
        let live = defaults?.string(forKey: Bridge.Key.liveText) ?? ""
        let message = defaults?.string(forKey: Bridge.Key.message) ?? ""

        // A dictation in flight whose app went away will never answer.
        if !alive, pendingRequestID != nil {
            mode = .idle
            pendingRequestID = nil
        }

        let recording: Bool
        switch mode {
        case .holding:
            recording = true
            statusLabel.text = "Listening — release to finish"
        case .handsFree:
            recording = true
            statusLabel.text = "Listening — tap to finish"
        case .waiting:
            recording = false
            statusLabel.text = "Working…"
        case .idle:
            recording = false
            if !hasFullAccess {
                statusLabel.text = "Turn on Allow Full Access: Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Murmur."
            } else if !alive {
                statusLabel.text = message.isEmpty ? "Tap the mic to start a Murmur session" : message
            } else if !message.isEmpty {
                statusLabel.text = message
            } else {
                statusLabel.text = "Tap to talk hands-free, or hold and release"
            }
        }

        previewLabel.text = recording && phase == .listening ? live : ""
        levelBar.progress = recording ? Float(defaults?.double(forKey: Bridge.Key.level) ?? 0) : 0

        var config = micButton.configuration ?? .filled()
        config.image = UIImage(systemName: recording ? "stop.fill" : "mic.fill")
        // Red means recording, and only recording.
        config.baseBackgroundColor = recording ? .systemRed : (alive ? .tintColor : .systemGray)
        micButton.configuration = config

        undoButton.isEnabled = !lastInserted.isEmpty
    }

    private func buildLayout() {
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        previewLabel.font = .preferredFont(forTextStyle: .body)
        previewLabel.textAlignment = .center
        previewLabel.numberOfLines = 2
        previewLabel.lineBreakMode = .byTruncatingHead

        levelBar.progressTintColor = .systemGreen

        var micConfig = UIButton.Configuration.filled()
        micConfig.image = UIImage(systemName: "mic.fill")
        micConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        micConfig.cornerStyle = .capsule
        micButton.configuration = micConfig
        micButton.accessibilityLabel = "Dictate"
        micButton.addTarget(self, action: #selector(micDown), for: .touchDown)
        micButton.addTarget(self, action: #selector(micUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.accessibilityLabel = "Next keyboard"
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        undoButton.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        undoButton.accessibilityLabel = "Undo last dictation"
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)

        let space = key(title: "space", action: #selector(spaceTapped))
        let delete = key(symbol: "delete.left", label: "Delete", action: #selector(deleteTapped))
        let enter = key(symbol: "return", label: "Return", action: #selector(returnTapped))

        for button in [globeButton, undoButton] {
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        micButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let row = UIStackView(arrangedSubviews: [globeButton, undoButton, micButton, space, delete, enter])
        row.spacing = 8
        row.alignment = .fill
        row.distribution = .fill
        row.heightAnchor.constraint(equalToConstant: 64).isActive = true
        space.widthAnchor.constraint(equalTo: micButton.widthAnchor, multiplier: 0.8).isActive = true

        let column = UIStackView(arrangedSubviews: [statusLabel, previewLabel, levelBar, row])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            column.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10),
        ])

        // Below required so the system's own keyboard-height constraint wins on rotation.
        let height = view.heightAnchor.constraint(equalToConstant: 190)
        height.priority = .defaultHigh
        height.isActive = true
    }

    private func key(title: String? = nil, symbol: String? = nil, label: String? = nil, action: Selector) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol) }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label ?? title
        button.addTarget(self, action: action, for: .touchUpInside)
        if title == nil { button.widthAnchor.constraint(equalToConstant: 64).isActive = true }
        return button
    }
}
