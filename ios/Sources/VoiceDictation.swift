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
        case .elevenLabs: localized("Your ElevenLabs API key")
        }
    }

    /// The Key section's footer — which model does the transcribing.
    var keyFooter: String {
        switch self {
        case .openAI: localized("OpenAI Realtime, with file and on-device fallback.")
        case .elevenLabs: localized("Transcribed with ElevenLabs Scribe.")
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

/// Voice dictation records a durable WAV while also streaming OpenAI-compatible
/// PCM when OpenAI is selected. The stop button establishes one ordered audio
/// boundary: the final tap buffer is accepted before the Realtime commit. If
/// Realtime fails, the same WAV goes to the provider's file endpoint, then to
/// Apple's on-device SpeechTranscriber as the final fallback.
final class VoiceDictation: NSObject {
    enum Failure: Error {
        case missingKey
        case microphonePermissionDenied
        case recordingFailed
        case empty
        case localUnavailable
        case network(String)
        case api(status: Int, message: String)

        /// A short line fit for the recording pill's error state.
        var hudMessage: String {
            switch self {
            case .missingKey: localized("Add an API key in Settings ▸ Voice")
            case .microphonePermissionDenied: localized("Allow microphone access in Settings")
            case .recordingFailed: localized("Couldn't start recording")
            case .empty: localized("Didn't catch that — try again")
            case .localUnavailable: localized("On-device transcription isn't available")
            case .network: localized("Network error — check your connection")
            case .api(_, let message): message
            }
        }
    }

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    /// The tap and stop path share this very short critical section. It makes
    /// "last append, then commit" a real ordering guarantee instead of a timer.
    private let captureLock = NSLock()
    private var acceptingAudio = false
    private var realtime: OpenAIRealtimeTranscriber?
    private var realtimeConverter: OpenAIRealtimePCMConverter?
    private var activeProvider: TranscriptionProvider?
    private var activeAPIKey: String?
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
        let provider = MobileSettings.shared.transcriptionProvider
        let apiKey = Self.apiKey(for: provider)
        guard apiKey?.isEmpty == false || AppleSpeechFallback.isAvailable else {
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
                try beginRecording(provider: provider, apiKey: apiKey)
                completion(.success(()))
            } catch {
                teardownEngine(cancelRealtime: true)
                cleanUp()
                completion(.failure(.recordingFailed))
            }
        }
    }

    /// Taps the mic through AVAudioEngine and writes straight to a WAV (linear
    /// PCM) file. PCM keeps every delivered frame on disk the instant it's
    /// written — there's no encoder buffering un-emitted frames — so an AAC
    /// clip's classic missing-tail can't happen. The one remaining requirement
    /// is that the AVAudioFile is actually deallocated to finalize (patch the
    /// WAV header sizes); AVAudioFile has no close(), so `teardownEngine` drops
    /// the last strong reference to it — which is why the tap below reaches the
    /// file through `self` instead of capturing it, keeping `audioFile` the
    /// single lasting owner. See developer.apple.com/forums/thread/710683.
    private func beginRecording(provider: TranscriptionProvider, apiKey: String?) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw Failure.recordingFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termio-dictation-\(UUID().uuidString).wav")
        // 16-bit linear PCM in a WAV container (both providers accept it),
        // recorded at the mic's own rate/channels so the tap buffers need no
        // resampling on the way in.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)

        recordedFrames = 0
        inputSampleRate = format.sampleRate
        meterLevel = 0
        activeProvider = provider
        activeAPIKey = apiKey
        self.audioFile = file
        self.fileURL = url
        self.engine = engine

        if provider == .openAI, let apiKey, !apiKey.isEmpty,
           let converter = OpenAIRealtimePCMConverter(inputFormat: format) {
            let realtime = OpenAIRealtimeTranscriber(apiKey: apiKey)
            self.realtime = realtime
            realtimeConverter = converter
            realtime.start()
        }

        captureLock.lock()
        acceptingAudio = true
        captureLock.unlock()
        // Reach the file through `self` (not a capture), taking only a transient
        // strong ref per call, so `audioFile` stays its single lasting owner —
        // niling that in teardown then deterministically finalizes the WAV.
        // A small buffer (~21 ms at 48 kHz) keeps little audio un-delivered
        // between tap calls, so stop clips as little of the tail as possible.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            captureLock.lock()
            defer { captureLock.unlock() }
            guard acceptingAudio, let file = audioFile else { return }
            try? file.write(from: buffer)
            recordedFrames += AVAudioFramePosition(buffer.frameLength)
            if let pcm = realtimeConverter?.convert(buffer) {
                realtime?.append(pcm)
            }
            meterLevel = Self.level(of: buffer)
        }

        engine.prepare()
        try engine.start()
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
        teardownEngine(cancelRealtime: true)
        cleanUp()
    }

    /// Stops recording and transcribes the clip. `completion` fires on the main
    /// queue with the transcript or the reason it failed.
    func stopAndTranscribe(completion: @escaping (Result<String, Failure>) -> Void) {
        guard let fileURL, engine != nil, let provider = activeProvider else {
            completion(.failure(.recordingFailed))
            return
        }
        let apiKey = activeAPIKey
        let realtime = self.realtime
        teardownEngine(cancelRealtime: false)
        deactivateSession()
        let duration = Double(recordedFrames) / inputSampleRate

        // A stab at the button (or a bump) isn't a dictation; drop it quietly.
        guard duration >= 0.4 else {
            realtime?.cancel()
            cleanUp()
            completion(.failure(.empty))
            return
        }

        if let realtime {
            realtime.commit { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let transcript):
                    finish(result: .success(transcript), completion: completion)
                case .failure:
                    transcribeFileThenLocal(
                        fileURL: fileURL, provider: provider, apiKey: apiKey,
                        completion: completion
                    )
                }
            }
        } else {
            transcribeFileThenLocal(
                fileURL: fileURL, provider: provider, apiKey: apiKey,
                completion: completion
            )
        }
    }

    /// Stops hardware first, then waits for any tap callback already in flight.
    /// Once the lock is acquired, all accepted buffers have been written and
    /// enqueued to Realtime; niling `audioFile` then finalizes the WAV header.
    private func teardownEngine(cancelRealtime: Bool) {
        let engine = engine
        engine?.stop()
        captureLock.lock()
        acceptingAudio = false
        if cancelRealtime { realtime?.cancel() }
        if !cancelRealtime, let tail = realtimeConverter?.finish(), !tail.isEmpty {
            // AVAudioConverter has its own sample-rate-conversion latency.
            // Explicit end-of-stream draining ensures those last samples are
            // queued before `stopAndTranscribe` calls Realtime `commit`.
            realtime?.append(tail)
        }
        realtimeConverter = nil
        audioFile = nil
        captureLock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        self.engine = nil
        if cancelRealtime { realtime = nil }
    }

    private func cleanUp() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        realtime?.cancel()
        engine = nil
        audioFile = nil
        fileURL = nil
        realtime = nil
        realtimeConverter = nil
        activeProvider = nil
        activeAPIKey = nil
        acceptingAudio = false
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

    private func transcribeFileThenLocal(
        fileURL: URL, provider: TranscriptionProvider, apiKey: String?,
        completion: @escaping (Result<String, Failure>) -> Void
    ) {
        guard let apiKey, !apiKey.isEmpty else {
            transcribeLocally(fileURL: fileURL, cloudFailure: nil, completion: completion)
            return
        }
        transcribe(fileURL: fileURL, provider: provider, apiKey: apiKey) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                finish(result: result, completion: completion)
            case .failure(let cloudFailure):
                transcribeLocally(
                    fileURL: fileURL, cloudFailure: cloudFailure, completion: completion
                )
            }
        }
    }

    private func transcribeLocally(
        fileURL: URL, cloudFailure: Failure?,
        completion: @escaping (Result<String, Failure>) -> Void
    ) {
        AppleSpeechFallback.transcribe(fileURL: fileURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let transcript):
                finish(result: .success(transcript), completion: completion)
            case .failure:
                finish(
                    result: .failure(cloudFailure ?? .localUnavailable),
                    completion: completion
                )
            }
        }
    }

    private func finish(
        result: Result<String, Failure>,
        completion: @escaping (Result<String, Failure>) -> Void
    ) {
        cleanUp()
        completion(result)
    }

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
                result = .failure(.network(localized("No response")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                result = .failure(.api(
                    status: http.statusCode,
                    message: provider.errorMessage(from: data) ?? localized("Transcription failed")
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
            "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
        )
        body.appendString("Content-Type: audio/wav\r\n\r\n")
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
/// when the user picks Voice from the (+) menu — a single floating glass layer
/// with quiet control wells and a live waveform, matching ChatGPT's compact
/// dictation treatment without stacking glass inside glass.
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

    private let shadowHost = UIView()
    private let capsule: UIVisualEffectView
    private let materialEffect: UIVisualEffect
    private let cancelButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let stopGlyph = UIView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusStack = UIStackView()
    private let waveform = WaveformView()

    /// Controls shown while recording; hidden once we're transcribing or errored.
    private var recordingControls: [UIView] { [cancelButton, waveform, stopButton] }

    private var timer: Timer?
    /// Guards `onDismissed` to one fire per cycle — `showError` schedules a
    /// delayed `dismiss()`, so a cycle must not restore the key rows twice.
    /// Reset whenever the pill re-enters an active state.
    private var hasDismissed = false

    init() {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            // The pill is one composite control surface. Making that surface
            // interactive gives it the system's touch-driven light response;
            // the inset wells remain simple fills, not a second glass layer.
            glass.isInteractive = true
            effect = glass
        } else {
            effect = UIBlurEffect(style: .systemChromeMaterial)
        }
        materialEffect = effect
        capsule = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        isHidden = true

        // A quiet, diffuse shadow supplies elevation over the keyboard's nearly
        // white material. The glass itself supplies the adaptive edge highlight;
        // a uniform separator stroke would make the surface read as an outline.
        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shadowHost)

        capsule.clipsToBounds = true
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.addSubview(capsule)

        // Both controls occupy the same neutral well. Only the glyphs differ,
        // keeping cancel and stop balanced instead of making stop a heavy disc.
        var cancelConfig = UIButton.Configuration.plain()
        cancelConfig.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        cancelConfig.baseForegroundColor = .label
        cancelConfig.cornerStyle = .capsule
        cancelConfig.background.backgroundColor = .tertiarySystemFill
        cancelButton.configuration = cancelConfig
        cancelButton.clipsToBounds = true
        cancelButton.accessibilityLabel = localized("Cancel recording")
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)

        stopButton.backgroundColor = .tertiarySystemFill
        stopButton.clipsToBounds = true
        stopButton.accessibilityLabel = localized("Stop and transcribe")
        stopButton.addAction(UIAction { [weak self] _ in self?.onStop?() }, for: .touchUpInside)
        stopGlyph.backgroundColor = .label
        stopGlyph.layer.cornerRadius = 3.5
        stopGlyph.layer.cornerCurve = .continuous
        stopGlyph.isUserInteractionEnabled = false
        stopGlyph.translatesAutoresizingMaskIntoConstraints = false
        stopButton.addSubview(stopGlyph)

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        spinner.hidesWhenStopped = true
        statusStack.axis = .horizontal
        statusStack.alignment = .center
        statusStack.spacing = 8
        statusStack.isHidden = true
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(spinner)
        statusStack.addArrangedSubview(statusLabel)

        for v in [cancelButton, waveform, stopButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            capsule.contentView.addSubview(v)
        }
        capsule.contentView.addSubview(statusStack)
        NSLayoutConstraint.activate([
            shadowHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadowHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            shadowHost.heightAnchor.constraint(equalToConstant: 56),

            capsule.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            capsule.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),

            cancelButton.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 8),
            cancelButton.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),

            stopButton.trailingAnchor.constraint(equalTo: capsule.contentView.trailingAnchor, constant: -8),
            stopButton.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 44),
            stopButton.heightAnchor.constraint(equalToConstant: 44),
            stopGlyph.centerXAnchor.constraint(equalTo: stopButton.centerXAnchor),
            stopGlyph.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            stopGlyph.widthAnchor.constraint(equalToConstant: 16),
            stopGlyph.heightAnchor.constraint(equalToConstant: 16),

            waveform.leadingAnchor.constraint(equalTo: cancelButton.trailingAnchor, constant: 18),
            waveform.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -18),
            waveform.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 28),

            statusStack.centerXAnchor.constraint(equalTo: capsule.contentView.centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: capsule.contentView.centerYAnchor),
            statusStack.leadingAnchor.constraint(greaterThanOrEqualTo: capsule.contentView.leadingAnchor, constant: 24),
            statusStack.trailingAnchor.constraint(lessThanOrEqualTo: capsule.contentView.trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        cancelButton.layer.cornerRadius = cancelButton.bounds.height / 2
        cancelButton.layer.cornerCurve = .circular
        stopButton.layer.cornerRadius = stopButton.bounds.height / 2
        stopButton.layer.cornerCurve = .circular

        shadowHost.layer.cornerRadius = shadowHost.bounds.height / 2
        shadowHost.layer.cornerCurve = .continuous
        shadowHost.layer.shadowColor = UIColor.black.cgColor
        shadowHost.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.18 : 0.07
        shadowHost.layer.shadowRadius = 14
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 4)
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds,
            cornerRadius: shadowHost.bounds.height / 2
        ).cgPath

        // Native glass supplies accessibility outlines on iOS 26. The material
        // fallback gets the same structural cue only when stronger contrast is
        // explicitly requested; the normal appearance has no uniform border.
        if #unavailable(iOS 26.0), UIAccessibility.isDarkerSystemColorsEnabled {
            capsule.layer.borderWidth = 1
            capsule.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        } else {
            capsule.layer.borderWidth = 0
            capsule.layer.borderColor = nil
        }
    }

    /// Start the glass transition from no optical effect so UIKit can perform
    /// its native materialize animation alongside the pill's scale entrance.
    func prepareToMaterialize(reduceMotion: Bool) {
        capsule.effect = reduceMotion ? materialEffect : nil
    }

    func setMaterialized(_ materialized: Bool, reduceMotion: Bool) {
        capsule.effect = reduceMotion || materialized ? materialEffect : nil
    }

    /// Shows the recording state and starts the timer. `levelProvider` is polled
    /// for the live waveform so the bar never reaches into the recorder itself.
    func beginRecording(levelProvider: @escaping () -> Float) {
        hasDismissed = false
        isHidden = false
        spinner.stopAnimating()
        statusStack.isHidden = true
        recordingControls.forEach { $0.isHidden = false }
        waveform.reset()

        timer?.invalidate()
        let meterTimer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.waveform.push(levelProvider())
        }
        RunLoop.main.add(meterTimer, forMode: .common)
        timer = meterTimer
    }

    /// Swaps to the "Transcribing…" state after stop.
    func showTranscribing() {
        stopTimer()
        recordingControls.forEach { $0.isHidden = true }
        statusLabel.text = localized("Transcribing…")
        statusLabel.textColor = .secondaryLabel
        statusStack.isHidden = false
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
        statusStack.isHidden = false
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
    }
}

/// A row of bars whose heights trail a rolling buffer of input levels — the
/// "I'm listening" waveform. Cheap: a handful of layers nudged each tick.
private final class WaveformView: UIView {
    // A denser sample history lets silence read as a dotted line and speech
    // grow into rounded columns, rather than a sparse row of heavy black bars.
    private let barCount = 38
    private let barWidth: CGFloat = 3
    private var bars: [CALayer] = []
    private var levels: [Float]
    private var smoothedLevel: Float = 0

    override init(frame: CGRect) {
        levels = Array(repeating: 0, count: barCount)
        super.init(frame: frame)
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = UIColor.secondaryLabel.cgColor
            bar.cornerRadius = barWidth / 2
            layer.addSublayer(bar)
            bars.append(bar)
        }
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false

        // A dynamic UIColor is baked when assigned to CALayer, so re-resolve it
        // when appearance or accessibility contrast changes.
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
        ]) { (self: WaveformView, _) in
            let resolved = UIColor.secondaryLabel.resolvedColor(with: self.traitCollection).cgColor
            self.bars.forEach { $0.backgroundColor = resolved }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        levels = Array(repeating: 0, count: barCount)
        smoothedLevel = 0
        layoutBars()
    }

    /// Shift the newest level in on the right and redraw.
    func push(_ level: Float) {
        let gated = max(0, min(1, (level - 0.04) / 0.96))
        let shaped = powf(gated, 0.68)
        smoothedLevel = smoothedLevel * 0.68 + shaped * 0.32
        levels.removeFirst()
        levels.append(smoothedLevel)
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
