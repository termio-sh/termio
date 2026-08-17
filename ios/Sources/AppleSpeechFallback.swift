import AVFoundation
import Foundation
import Speech

/// Last-resort, on-device transcription for iOS 26 and later. Model assets may
/// be downloaded once by the system, but analysis itself stays on the device.
enum AppleSpeechFallback {
    enum LocalError: LocalizedError {
        case unavailable
        case unsupportedLocale
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable: localized("On-device transcription isn't available")
            case .unsupportedLocale: localized("The current language isn't supported on device")
            case .empty: localized("On-device transcription returned no text")
            }
        }
    }

    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { SpeechTranscriber.isAvailable }
        else { false }
    }

    static func transcribe(
        fileURL: URL, completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        guard #available(iOS 26.0, *) else {
            completion(.failure(LocalError.unavailable))
            return
        }
        Task {
            let result: Result<String, Swift.Error>
            do {
                result = .success(try await transcribeOnDevice(fileURL: fileURL))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { completion(result) }
        }
    }

    @available(iOS 26.0, *)
    private static func transcribeOnDevice(fileURL: URL) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw LocalError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw LocalError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installer = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installer.downloadAndInstall()
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        async let transcript = collectResults(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let rawTranscript = try await transcript
        let text = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalError.empty }
        return text
    }

    @available(iOS 26.0, *)
    private static func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            transcript += String(result.text.characters)
        }
        return transcript
    }
}
