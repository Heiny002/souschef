import AVFoundation
import Speech
import Foundation

/// The properties voice ranking needs. `AVSpeechSynthesisVoice` already provides all three;
/// the protocol exists so tests can stand in fakes with a chosen quality, which the real
/// type does not allow (its voices come only from the system, quality read-only).
protocol RankableVoice {
    var language: String { get }
    var quality: AVSpeechSynthesisVoiceQuality { get }
    var identifier: String { get }
}

extension AVSpeechSynthesisVoice: RankableVoice {}

/// Cook Mode voice layer.
/// TTS (AVSpeechSynthesizer) reads steps aloud.
/// SFSpeechRecognizer listens for voice commands between TTS utterances.
@MainActor
final class CookVoiceController: NSObject, ObservableObject, @unchecked Sendable {

    enum VoiceCommand {
        case next, back, startTimer, stopTimer, listTimers, repeatStep, showIngredients
    }

    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var isAvailable = false

    /// Receives detected voice commands.
    var onCommand: ((VoiceCommand) -> Void)?

    // MARK: - Private state

    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var lastCommandDate: Date = .distantPast

    /// True while listening is *wanted* — i.e. it should auto-restart when a recognition
    /// task ends on its own (server-based requests die after ~60s). Cleared by an explicit
    /// stopListening() so deliberate stops don't trigger a restart (H7).
    private var autoRestartWanted = false
    /// Consecutive spontaneous endings without a successful transcript — drives backoff.
    private var restartAttempts = 0
    private var restartWorkItem: DispatchWorkItem?

    // MARK: - Init

    override init() {
        super.init()
        synthesizer.delegate = self
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else { return false }
        let micGranted = await Self.requestMicrophonePermission()
        isAvailable = micGranted
        return micGranted
    }

    /// nonisolated static: framework callbacks fire on arbitrary queues;
    /// Swift 6 would infer @MainActor on closures defined inside a @MainActor context,
    /// causing dispatch_assert_queue_fail when the callback queue isn't the main actor.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    private nonisolated static func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - Voice selection

    /// The best-sounding installed voice, resolved once — enumerating voices on every
    /// utterance would be wasted work in a screen that speaks constantly.
    ///
    /// Apple ships only the compact `.default` voices; the far more natural `.enhanced` and
    /// `.premium` ones are user downloads (Settings → Accessibility → Spoken Content → Voices)
    /// that an app cannot install on the user's behalf. So this is a preference ladder, not a
    /// fixed choice: hardcoding `.premium` would sound WORSE for most people, because on a
    /// phone without that download it resolves to nothing and falls back to the robotic
    /// default. Picking the best *installed* voice degrades gracefully instead.
    static let bestAvailableVoice: AVSpeechSynthesisVoice? = selectVoice(
        from: AVSpeechSynthesisVoice.speechVoices(),
        preferredLanguage: AVSpeechSynthesisVoice.currentLanguageCode()
    )

    /// Rank installed voices: premium > enhanced > default, preferring the user's own
    /// language, then any English voice. Generic over `RankableVoice` because
    /// `AVSpeechSynthesisVoice` can't be constructed with a chosen quality, so the ladder
    /// would otherwise be untestable without a device that happens to have the right
    /// voices downloaded.
    nonisolated static func selectVoice<V: RankableVoice>(from voices: [V],
                                                          preferredLanguage: String) -> V? {
        func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
            switch quality {
            case .premium:  return 3
            case .enhanced: return 2
            default:        return 1
            }
        }
        // Language preference: exact match beats same base language ("en-GB" for an "en-US"
        // device) beats any English, so a user never gets a voice in a language they can't
        // follow just because it scored higher on quality.
        let preferredBase = preferredLanguage.prefix(2).lowercased()
        func languageScore(_ voice: V) -> Int {
            if voice.language.caseInsensitiveCompare(preferredLanguage) == .orderedSame { return 3 }
            if voice.language.prefix(2).lowercased() == preferredBase { return 2 }
            if voice.language.hasPrefix("en") { return 1 }
            return 0
        }

        return voices
            .filter { languageScore($0) > 0 }
            .max { a, b in
                let (la, lb) = (languageScore(a), languageScore(b))
                if la != lb { return la < lb }
                let (qa, qb) = (rank(a.quality), rank(b.quality))
                if qa != qb { return qa < qb }
                // Stable tie-break so the chosen voice doesn't change between launches.
                return a.identifier > b.identifier
            }
    }

    /// Which voice was chosen and at what quality — surfaced for on-device verification,
    /// since voice quality can't be judged from a build log.
    static var voiceDescription: String {
        guard let voice = bestAvailableVoice else { return "system default" }
        let quality: String
        switch voice.quality {
        case .premium:  quality = "premium"
        case .enhanced: quality = "enhanced"
        default:        quality = "default"
        }
        return "\(voice.name) (\(voice.language), \(quality))"
    }

    // MARK: - TTS

    /// Read a step aloud. Stops any ongoing recognition first.
    func speak(_ text: String) {
        stopListening()
        synthesizer.stopSpeaking(at: .immediate)
        setAudioSessionForPlayback()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestAvailableVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.postUtteranceDelay = 0.4

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Speech Recognition

    func startListening() {
        guard isAvailable, !isListening, !isSpeaking else { return }
        guard let recognizer, recognizer.isAvailable else { return }
        autoRestartWanted = true
        setAudioSessionForRecord()

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // On-device removes the ~60s server limit AND keeps kitchen audio off
            // Apple's servers (audit privacy medium). Server-based recognition remains
            // the fallback where unsupported — the auto-restart below covers its limit.
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            let format = inputNode.outputFormat(forBus: 0)
            Self.installAudioTap(on: inputNode, format: format, request: request)

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            recognitionTask = Self.beginRecognition(
                recognizer: recognizer, request: request,
                onTranscript: { [weak self] text in self?.handleTranscript(text) },
                onFinished: { [weak self] in self?.recognitionEnded() }
            )
        } catch {
            isListening = false
            recognitionEnded()
        }
    }

    func stopListening() {
        // Clear the restart intent FIRST — cancelling the task below fires its completion
        // handler, which must not schedule a restart after a deliberate stop.
        autoRestartWanted = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        guard isListening else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    /// A recognition task ended (server ~60s limit, error, or final result) without the
    /// user asking it to. Tear down and restart with capped exponential backoff so voice
    /// commands keep working through a long simmer instead of silently dying (H7).
    private func recognitionEnded() {
        guard autoRestartWanted else { return }   // deliberate stop — no restart
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false

        restartAttempts += 1
        let delay = min(0.5 * pow(2.0, Double(restartAttempts - 1)), 8.0)
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoRestartWanted, !self.isListening, !self.isSpeaking else { return }
            self.startListening()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// nonisolated static: recognitionTask callback fires on an internal Speech queue.
    /// Same pattern as the other three fixes — closure must be defined outside @MainActor.
    private nonisolated static func beginRecognition(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onTranscript: @MainActor @Sendable @escaping (String) -> Void,
        onFinished: @MainActor @Sendable @escaping () -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let transcript = result?.bestTranscription.formattedString {
                Task { @MainActor in onTranscript(transcript.lowercased()) }
            }
            if error != nil || result?.isFinal == true {
                Task { @MainActor in onFinished() }
            }
        }
    }

    /// nonisolated static: tap closure fires on RealtimeMessenger.mServiceQueue.
    /// Swift 6 infers @MainActor on closures defined inside @MainActor functions,
    /// causing dispatch_assert_queue_fail. Defining the closure here removes that inference.
    private nonisolated static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buf, _ in
            request?.append(buf)
        }
    }

    // MARK: - Command detection

    private let commandTable: [(keywords: [String], command: VoiceCommand)] = [
        // listTimers goes first: "what timers do I have going" must never fall through
        // to a looser phrase in a later row.
        (["what timers", "which timers", "list timers", "list the timers", "list my timers",
          "timers do i have", "timers going", "show timers", "show my timers", "my timers"], .listTimers),
        (["next step", "next", "go next", "go forward", "forward", "continue"], .next),
        (["go back", "previous step", "previous", "back", "back up"], .back),
        (["start timer", "begin timer", "set timer", "start the timer"], .startTimer),
        (["stop timer", "pause timer", "cancel timer", "stop the timer"], .stopTimer),
        (["repeat", "say again", "read again", "repeat that", "what was that"], .repeatStep),
        (["show ingredients", "ingredients", "what do i need", "what ingredients"], .showIngredients),
    ]

    private func handleTranscript(_ text: String) {
        restartAttempts = 0   // recognition is demonstrably working — reset the backoff
        guard Date().timeIntervalSince(lastCommandDate) > 2.0 else { return }
        for (keywords, command) in commandTable {
            if keywords.contains(where: { text.contains($0) }) {
                lastCommandDate = Date()
                onCommand?(command)
                stopListening()
                // Brief pause then resume listening
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startListening()
                }
                return
            }
        }
    }

    // MARK: - Audio session helpers

    private func setAudioSessionForPlayback() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    private func setAudioSessionForRecord() {
        let s = AVAudioSession.sharedInstance()
        // .allowBluetooth is deprecated-renamed to .allowBluetoothHFP on newer SDKs, but
        // the new name doesn't exist in Xcode 16.x (CI). Keep the old spelling until the
        // minimum toolchain has the rename — it compiles everywhere.
        try? s.setCategory(.playAndRecord, mode: .default,
                            options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
    }

    /// Call on dismiss — stops all audio and deactivates the session.
    func deactivate() {
        stopSpeaking()
        stopListening()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension CookVoiceController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.startListening()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
        }
    }
}
