import AVFoundation
import UIKit

/// One of the bring-your-own-key transcription services the user can pick in
/// Settings ▸ Voice. Each owns its endpoint, auth header, request shape, and
/// its own Keychain entry, so keys never cross providers.
enum TranscriptionProvider: String, CaseIterable {
    case openAI
    case elevenLabs

    /// Settings label.
    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .elevenLabs: "ElevenLabs"
        }
    }

    /// The key editor's field placeholder.
    var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-..."
        case .elevenLabs: "Your ElevenLabs API key"
        }
    }

    /// The Key section's footer — which model does the transcribing.
    var keyFooter: String {
        switch self {
        case .openAI: "Transcribed with OpenAI gpt-4o-transcribe."
        case .elevenLabs: "Transcribed with ElevenLabs Scribe."
        }
    }

    fileprivate var keychainService: String {
        switch self {
        case .openAI: "sh.termio.mobile.openai"
        case .elevenLabs: "sh.termio.mobile.elevenlabs"
        }
    }

    fileprivate var endpointURL: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .elevenLabs: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        }
    }

    /// The transcription model id sent in the request. `gpt-4o-transcribe` is
    /// OpenAI's most accurate speech model; `scribe_v2` is ElevenLabs' Scribe.
    fileprivate var model: String {
        switch self {
        case .openAI: "gpt-4o-transcribe"
        case .elevenLabs: "scribe_v2"
        }
    }
}

/// Voice dictation: record the mic while the recording pill is up (started
/// from the terminal keyboard's (+) menu), then transcribe the clip with the
/// provider the user picked in Settings ▸ Voice and hand the text back to drop
/// into the terminal (never auto-sent — a dictation can't fire a half-formed
/// prompt).
///
/// The clip is short (seconds to a minute) and the text is wanted only once the
/// user taps stop, so this records-then-POSTs rather than opening a realtime
/// socket — see `docs/rfcs/push-to-talk-voice-dictation.md` for why that model
/// wins here.
final class VoiceDictation: NSObject {
    enum Failure: Error {
        case missingKey
        case microphonePermissionDenied
        case recordingFailed
        case empty
        case network(String)
        case api(status: Int, message: String)

        /// A short line fit for the recording pill's error state.
        var hudMessage: String {
            switch self {
            case .missingKey: "Add an API key in Settings ▸ Voice"
            case .microphonePermissionDenied: "Allow microphone access in Settings"
            case .recordingFailed: "Couldn't start recording"
            case .empty: "Didn't catch that — try again"
            case .network: "Network error — check your connection"
            case .api(_, let message): message
            }
        }
    }

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    /// Frames the tap has written ÷ sample rate = the clip length, for the
    /// too-short-jab guard. Written on the audio thread, read after teardown.
    private var recordedFrames: AVAudioFramePosition = 0
    private var inputSampleRate: Double = 48_000
    /// Latest input level, 0…1, for the waveform. Written on the tap's audio
    /// thread, read on the main thread — a benign race for a meter (aligned
    /// 32-bit access), so no render-thread lock.
    private var meterLevel: Float = 0

    var isRecording: Bool { engine?.isRunning ?? false }

    // MARK: - Recording

    /// Requests mic access if needed, then begins recording. `completion` fires
    /// on the main queue once recording is underway (or with why it couldn't).
    func start(completion: @escaping (Result<Void, Failure>) -> Void) {
        guard Self.hasAPIKey(for: MobileSettings.shared.transcriptionProvider) else {
            completion(.failure(.missingKey))
            return
        }
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                completion(.failure(.microphonePermissionDenied))
                return
            }
            do {
                try beginRecording()
                completion(.success(()))
            } catch {
                teardownEngine()
                completion(.failure(.recordingFailed))
            }
        }
    }

    /// Taps the mic through AVAudioEngine and writes straight to an AAC file.
    /// Unlike AVAudioRecorder, stopping the engine flushes every frame the tap
    /// has delivered, so the tail is never clipped and no drain delay is needed
    /// — Apple's recommended path for recording.
    private func beginRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Failure.recordingFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-dictation-\(UUID().uuidString).m4a")
        // AAC in an m4a container (both providers accept it), written at the
        // mic's own rate/channels so the tap buffers need no format conversion.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        recordedFrames = 0
        inputSampleRate = format.sampleRate
        meterLevel = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? file.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            meterLevel = Self.level(of: buffer)
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        self.audioFile = file
        self.fileURL = url
    }

    /// RMS of a buffer mapped to 0…1 over the useful speech band. The band is
    /// deliberately narrow — quiet room ≈ -55 dB, normal speech ≈ -30 dB, loud
    /// ≈ -12 dB — so normal talking fills the bar instead of sitting near the
    /// floor (0 dB is clipping, which speech never reaches).
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { let s = data[i]; sum += s * s }
        let decibels = 20 * log10(max(sqrt(sum / Float(count)), 1e-7))
        let floor: Float = -55
        let ceiling: Float = -12
        return min(1, max(0, (decibels - floor) / (ceiling - floor)))
    }

    /// The current input level, 0…1, for the pill's waveform. Call while
    /// recording; returns 0 otherwise.
    func currentLevel() -> Float {
        isRecording ? meterLevel : 0
    }

    /// Discards the in-flight recording without transcribing (the cancel ✕).
    func cancel() {
        teardownEngine()
        cleanUp()
    }

    /// Stops recording and transcribes the clip. `completion` fires on the main
    /// queue with the transcript or the reason it failed. Stopping the engine
    /// flushes the tap cleanly, so the whole clip is on disk — no drain wait.
    func stopAndTranscribe(completion: @escaping (Result<String, Failure>) -> Void) {
        guard let fileURL, engine != nil else {
            completion(.failure(.recordingFailed))
            return
        }
        // Teardown first so the tap has stopped and recordedFrames is final.
        teardownEngine()
        deactivateSession()
        let duration = Double(recordedFrames) / inputSampleRate

        // A stab at the button (or a bump) isn't a dictation; drop it quietly.
        guard duration >= 0.4 else {
            cleanUp()
            completion(.failure(.empty))
            return
        }
        let provider = MobileSettings.shared.transcriptionProvider
        guard let key = Self.apiKey(for: provider), !key.isEmpty else {
            cleanUp()
            completion(.failure(.missingKey))
            return
        }
        transcribe(fileURL: fileURL, provider: provider, apiKey: key) { [weak self] result in
            self?.cleanUp()
            completion(result)
        }
    }

    /// Stops the engine and closes the file, flushing every delivered frame.
    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        audioFile = nil   // closing the AVAudioFile flushes its remaining frames
    }

    private func cleanUp() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        engine = nil
        audioFile = nil
        fileURL = nil
        deactivateSession()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        let handler: (Bool) -> Void = { granted in
            DispatchQueue.main.async { completion(granted) }
        }
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission(completionHandler: handler)
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission(handler)
        }
    }

    // MARK: - Transcription

    private func transcribe(
        fileURL: URL, provider: TranscriptionProvider, apiKey: String,
        completion: @escaping (Result<String, Failure>) -> Void
    ) {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            completion(.failure(.recordingFailed))
            return
        }

        let request = provider.makeRequest(apiKey: apiKey, audioData: audioData)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, Failure>
            defer { DispatchQueue.main.async { completion(result) } }

            if let error {
                result = .failure(.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(.network("No response"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(.api(
                    status: http.statusCode,
                    message: provider.errorMessage(from: data) ?? "Transcription failed"
                ))
                return
            }
            let transcript = provider.transcript(from: data)
            result = transcript.isEmpty ? .failure(.empty) : .success(transcript)
        }.resume()
    }

    // MARK: - API key (Keychain)

    // One entry per provider (keyed by service), same account. Reads use the
    // service the value was written under, so a key stored before providers
    // were split out still resolves under `.openAI` unchanged.
    private static let keychainAccount = "api-key"

    /// The stored key for `provider`, or nil. Kept in the Keychain, never
    /// UserDefaults.
    static func apiKey(for provider: TranscriptionProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the key for `provider`; a nil or empty value removes it.
    static func setAPIKey(_ newValue: String?, for provider: TranscriptionProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, let data = value.data(using: .utf8)
        else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func hasAPIKey(for provider: TranscriptionProvider) -> Bool {
        apiKey(for: provider)?.isEmpty == false
    }
}

private extension TranscriptionProvider {
    /// Builds the multipart transcription POST for this provider.
    func makeRequest(apiKey: String, audioData: Data) -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        let boundary = "termio-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )
        switch self {
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .elevenLabs:
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        switch self {
        case .openAI:
            field("model", model)
            // Plain-text response: the whole body is the transcript, no JSON to peel.
            field("response_format", "text")
        case .elevenLabs:
            field("model_id", model)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n"
        )
        body.appendString("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    /// Pulls the transcript out of a 2xx response body.
    func transcript(from data: Data) -> String {
        let text: String
        switch self {
        case .openAI:
            // response_format=text: the body is the transcript verbatim.
            text = String(data: data, encoding: .utf8) ?? ""
        case .elevenLabs:
            // JSON: { "text": "…", "language_code": …, "words": [...] }.
            let json = try? JSONSerialization.jsonObject(with: data)
            text = (json as? [String: Any])?["text"] as? String ?? ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A human-readable message from an error response, if the body carries one.
    func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch self {
        case .openAI:
            // { "error": { "message": … } }
            return (json["error"] as? [String: Any])?["message"] as? String
        case .elevenLabs:
            // { "detail": "…" } or { "detail": { "message": … } }
            if let detail = json["detail"] as? String { return detail }
            return (json["detail"] as? [String: Any])?["message"] as? String
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

/// The recording surface that takes over the terminal keyboard's accessory bar
/// when the user picks Voice from the (+) menu — Apple Messages' audio-message
/// aesthetic: a rounded capsule with a cancel (✕) on the left, an elapsed timer
/// and a live waveform in the middle, and the signature red circular stop button
/// (a white rounded square) on the right.
/// Tap Voice to start, tap stop to finish — no hold. After stop it swaps to a
/// "Transcribing…" spinner, then a brief red error line on failure.
final class VoiceRecordingBar: UIView {
    /// The cancel (✕) was tapped — discard the clip, don't transcribe.
    var onCancel: (() -> Void)?
    /// The stop button was tapped — finish recording and transcribe.
    var onStop: (() -> Void)?
    /// The pill hid itself (success, cancel, or an auto-dismissed error) — the
    /// owner restores the keyboard here, on every exit path.
    var onDismissed: (() -> Void)?

    private let capsule = UIView()
    private let cancelButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let stopGlyph = UIView()
    private let timeLabel = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let waveform = WaveformView()

    /// Controls shown while recording; hidden once we're transcribing or errored.
    private var recordingControls: [UIView] { [cancelButton, timeLabel, waveform, stopButton] }

    private var startDate: Date?
    private var timer: Timer?
    /// Guards `onDismissed` to one fire per cycle — `showError` schedules a
    /// delayed `dismiss()`, so a cycle must not restore the key rows twice.
    /// Reset whenever the pill re-enters an active state.
    private var hasDismissed = false

    init() {
        super.init(frame: .zero)
        isHidden = true

        capsule.backgroundColor = .secondarySystemBackground
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)

        // Cancel (✕): Messages' discard affordance, a plain grey circle.
        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        cancelConfig.baseForegroundColor = .secondaryLabel
        cancelButton.configuration = cancelConfig
        cancelButton.backgroundColor = .tertiarySystemFill
        cancelButton.accessibilityLabel = "Cancel recording"
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)

        // Stop: the red circle with a white rounded square — Messages' stop.
        stopButton.backgroundColor = .systemRed
        stopButton.accessibilityLabel = "Stop and transcribe"
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        stopGlyph.backgroundColor = .white
        stopGlyph.layer.cornerRadius = 3.5
        stopGlyph.layer.cornerCurve = .continuous
        stopGlyph.isUserInteractionEnabled = false
        stopGlyph.translatesAutoresizingMaskIntoConstraints = false
        stopButton.addSubview(stopGlyph)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.textColor = .label
        timeLabel.text = "0:00"

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true

        spinner.hidesWhenStopped = true

        for v in [cancelButton, timeLabel, waveform, stopButton, statusLabel, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview(v)
        }
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.heightAnchor.constraint(equalToConstant: 52),

            cancelButton.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 6),
            cancelButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 40),
            cancelButton.heightAnchor.constraint(equalToConstant: 40),

            stopButton.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -6),
            stopButton.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 40),
            stopButton.heightAnchor.constraint(equalToConstant: 40),
            stopGlyph.centerXAnchor.constraint(equalTo: stopButton.centerXAnchor),
            stopGlyph.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            stopGlyph.widthAnchor.constraint(equalToConstant: 15),
            stopGlyph.heightAnchor.constraint(equalToConstant: 15),

            timeLabel.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 14),
            timeLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            waveform.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -12),
            waveform.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 44),
            statusLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        cancelButton.layer.cornerRadius = cancelButton.bounds.height / 2
        stopButton.layer.cornerRadius = stopButton.bounds.height / 2
    }

    /// Shows the recording state and starts the timer. `levelProvider` is polled
    /// for the live waveform so the bar never reaches into the recorder itself.
    func beginRecording(levelProvider: @escaping () -> Float) {
        hasDismissed = false
        isHidden = false
        spinner.stopAnimating()
        statusLabel.isHidden = true
        recordingControls.forEach { $0.isHidden = false }
        waveform.reset()

        startDate = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let startDate else { return }
            let elapsed = Int(Date().timeIntervalSince(startDate))
            timeLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            waveform.push(levelProvider())
        }
    }

    /// Swaps to the "Transcribing…" state after stop.
    func showTranscribing() {
        stopTimer()
        recordingControls.forEach { $0.isHidden = true }
        statusLabel.text = "Transcribing…"
        statusLabel.textColor = .secondaryLabel
        statusLabel.isHidden = false
        spinner.startAnimating()
    }

    /// Flashes a red error line, then hides the bar. Can be reached without a
    /// preceding `beginRecording` (a start failure), so it re-arms the guard.
    func showError(_ message: String) {
        hasDismissed = false
        stopTimer()
        isHidden = false
        spinner.stopAnimating()
        recordingControls.forEach { $0.isHidden = true }
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.dismiss()
        }
    }

    /// Marks the cycle done and hands off to the owner, which animates the pill
    /// out (so the exit stays in sync with the key rows fading back in) — the
    /// bar's own visibility is left to `onDismissed`.
    func dismiss() {
        guard !hasDismissed else { return }
        hasDismissed = true
        stopTimer()
        spinner.stopAnimating()
        onDismissed?()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
    }
}

/// A row of bars whose heights trail a rolling buffer of input levels — the
/// "I'm listening" waveform. Cheap: a handful of layers nudged each tick.
private final class WaveformView: UIView {
    // Enough bars to fill the full-width capsule; they spread to fit whatever
    // width Auto Layout hands us (no fixed width — the bar stretches).
    private let barCount = 26
    private let barWidth: CGFloat = 3
    private var bars: [CALayer] = []
    private var levels: [Float]

    override init(frame: CGRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.systemRed.cgColor
            bar.cornerRadius = barWidth / 2
            layer.addSublayer(bar)
            bars.append(bar)
        }
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        layoutBars()
    }

    /// Shift the newest level in on the right and redraw.
    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(max(0.05, min(1, level)))
        layoutBars()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBars()
    }

    private func layoutBars() {
        // No implicit animations — the timer already ticks fast enough to read
        // as motion, and animating each bar would smear the waveform.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        // Spread the bars evenly across the available width.
        let spacing = bars.count > 1
            ? max(0, (bounds.width - CGFloat(bars.count) * barWidth) / CGFloat(bars.count - 1))
            : 0
        for (index, bar) in bars.enumerated() {
            let height = max(barWidth, CGFloat(levels[index]) * bounds.height)
            let x = CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)
        }
        CATransaction.commit()
    }
}
