import AVFoundation
import Foundation

/// A one-shot OpenAI Realtime transcription connection.
///
/// All audio and the final commit cross `stateQueue`, so the commit can never
/// overtake the last microphone buffer. Audio captured before the WebSocket is
/// ready is retained briefly and flushed immediately after `session.update`.
final class OpenAIRealtimeTranscriber: NSObject {
    enum RealtimeError: LocalizedError {
        case connection(String)
        case api(String)
        case empty
        case timedOut

        var errorDescription: String? {
            switch self {
            case .connection(let message), .api(let message): message
            case .empty: localized("OpenAI returned an empty transcript")
            case .timedOut: localized("OpenAI Realtime transcription timed out")
            }
        }
    }

    private static let model = "gpt-live-transcribe"
    /// 100 ms of mono 24 kHz PCM16. This keeps WebSocket overhead low without
    /// adding perceptible latency to the completed transcript.
    private static let chunkByteCount = 4_800

    private let stateQueue = DispatchQueue(label: "sh.termio.openai-realtime")
    private let apiKey: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opened = false
    private var commitRequested = false
    private var finished = false
    private var pendingAudio = Data()
    private var deferredError: RealtimeError?
    private var completion: ((Result<String, RealtimeError>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func start() {
        stateQueue.async { [weak self] in self?.connect() }
    }

    /// Accepts mono 24 kHz little-endian PCM16.
    func append(_ audio: Data) {
        guard !audio.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self, !finished, !commitRequested else { return }
            pendingAudio.append(audio)
            if opened { flushAudio(includeRemainder: false) }
        }
    }

    /// Flushes every accepted byte, then sends the explicit Realtime commit.
    func commit(completion: @escaping (Result<String, RealtimeError>) -> Void) {
        stateQueue.async { [weak self] in
            guard let self, !finished else { return }
            self.completion = completion
            commitRequested = true
            if let deferredError {
                finish(.failure(deferredError))
                return
            }
            if opened { sendCommit() }
            armTimeout()
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self, !finished else { return }
            finished = true
            timeoutWorkItem?.cancel()
            task?.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
            task = nil
            session = nil
            completion = nil
            pendingAudio.removeAll(keepingCapacity: false)
        }
    }

    private func connect() {
        guard !finished,
              let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)")
        else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let delegateQueue = OperationQueue()
        delegateQueue.name = "sh.termio.openai-realtime.delegate"
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue
        )
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 2 << 20
        self.session = session
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func configure(_ task: URLSessionWebSocketTask) {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": ["model": Self.model],
                        // The stop button owns the turn boundary.
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        send(event, on: task)
    }

    private func flushAudio(includeRemainder: Bool) {
        guard let task else { return }
        while pendingAudio.count >= Self.chunkByteCount {
            let chunk = pendingAudio.prefix(Self.chunkByteCount)
            pendingAudio.removeFirst(Self.chunkByteCount)
            sendAudio(Data(chunk), on: task)
        }
        if includeRemainder, !pendingAudio.isEmpty {
            let remainder = pendingAudio
            pendingAudio.removeAll(keepingCapacity: false)
            sendAudio(remainder, on: task)
        }
    }

    private func sendAudio(_ audio: Data, on task: URLSessionWebSocketTask) {
        send([
            "type": "input_audio_buffer.append",
            "audio": audio.base64EncodedString(),
        ], on: task)
    }

    private func sendCommit() {
        guard let task else { return }
        flushAudio(includeRemainder: true)
        send(["type": "input_audio_buffer.commit"], on: task)
    }

    private func send(_ event: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8)
        else {
            record(.connection(localized("Couldn't encode an OpenAI Realtime event")))
            return
        }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.stateQueue.async {
                self?.record(.connection(error.localizedDescription))
            }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            stateQueue.async {
                guard !self.finished, task === self.task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    if !self.finished { self.receive(on: task) }
                case .failure(let error):
                    self.record(.connection(error.localizedDescription))
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let transcript = (json["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finish(transcript.isEmpty ? .failure(.empty) : .success(transcript))
        case "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? localized("OpenAI Realtime failed")
            record(.api(message))
        default:
            break
        }
    }

    private func record(_ error: RealtimeError) {
        guard !finished else { return }
        if commitRequested {
            finish(.failure(error))
        } else {
            deferredError = error
        }
    }

    private func armTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !finished else { return }
            finish(.failure(.timedOut))
        }
        timeoutWorkItem = workItem
        stateQueue.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    private func finish(_ result: Result<String, RealtimeError>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
        pendingAudio.removeAll(keepingCapacity: false)
        let completion = completion
        self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }
}

extension OpenAIRealtimeTranscriber: URLSessionWebSocketDelegate {
    func urlSession(
        _: URLSession, webSocketTask task: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        stateQueue.async { [weak self] in
            guard let self, !finished, task === self.task else { return }
            opened = true
            configure(task)
            flushAudio(includeRemainder: false)
            if commitRequested { sendCommit() }
        }
    }

    func urlSession(
        _: URLSession, webSocketTask task: URLSessionWebSocketTask,
        didCloseWith _: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        stateQueue.async { [weak self] in
            guard let self, !finished, task === self.task else { return }
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
                ?? localized("OpenAI Realtime connection closed")
            record(.connection(detail))
        }
    }
}

/// Converts the hardware input format to the Realtime API's PCM requirement.
/// The converter is confined to AVAudioEngine's tap callback.
final class OpenAIRealtimePCMConverter {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var ended = false

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        guard !ended else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        _ = converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0,
              let samples = output.int16ChannelData?[0]
        else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Signals end-of-stream and returns samples retained by the resampler's
    /// filter latency. Call exactly once after the audio engine has stopped.
    func finish() -> Data {
        guard !ended else { return Data() }
        ended = true
        var tail = Data()

        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 1_024
            ) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            guard conversionError == nil else { break }
            if output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                tail.append(Data(
                    bytes: samples,
                    count: Int(output.frameLength) * MemoryLayout<Int16>.size
                ))
            }
            if status != .haveData || output.frameLength == 0 { break }
        }
        return tail
    }
}
