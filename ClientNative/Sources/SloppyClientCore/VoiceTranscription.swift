import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

public struct VoiceTranscriptionRequest: Codable, Sendable, Equatable {
    public var audioBase64: String
    public var mimeType: String
    public var language: String?
    public var prompt: String?

    public init(
        audioBase64: String,
        mimeType: String,
        language: String? = nil,
        prompt: String? = nil
    ) {
        self.audioBase64 = audioBase64
        self.mimeType = mimeType
        self.language = language
        self.prompt = prompt
    }
}

public struct VoiceTranscriptionResponse: Codable, Sendable, Equatable {
    public var text: String
    public var provider: String
    public var model: String

    public init(text: String, provider: String, model: String) {
        self.text = text
        self.provider = provider
        self.model = model
    }
}

public actor VoiceService {
    private let http: BackendHTTPClient

    public init(http: BackendHTTPClient) {
        self.http = http
    }

    public func transcribe(_ request: VoiceTranscriptionRequest) async throws -> VoiceTranscriptionResponse {
        try await http.post("/v1/voice/transcriptions", body: request)
    }
}

public struct DictationRecorderSnapshot: Sendable, Equatable {
    public var elapsed: TimeInterval
    public var level: Double
    public var powerDBFS: Double?

    public init(elapsed: TimeInterval = 0, level: Double = 0, powerDBFS: Double? = nil) {
        self.elapsed = elapsed
        self.level = level
        self.powerDBFS = powerDBFS
    }
}

public struct DictationCapture: Sendable, Equatable {
    public var fileURL: URL
    public var mimeType: String
    public var duration: TimeInterval

    public init(fileURL: URL, mimeType: String, duration: TimeInterval) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.duration = duration
    }
}

public enum DictationRecorderError: LocalizedError, Sendable {
    case unavailable
    case microphonePermissionDenied
    case couldNotStartRecording
    case noCapture

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Dictation is not available on this device."
        case .microphonePermissionDenied:
            return "Microphone access is required to record dictation."
        case .couldNotStartRecording:
            return "Could not start recording dictation."
        case .noCapture:
            return "No dictation recording was captured."
        }
    }
}

public actor DictationRecorder {
    #if canImport(AVFoundation)
    private var recorder: AVAudioRecorder?
    #endif
    private var fileURL: URL?
    private var startedAt: Date?

    public init() {}

    public func start() async throws {
        #if canImport(AVFoundation)
        guard await requestMicrophonePermission() else {
            throw DictationRecorderError.microphonePermissionDenied
        }

        #if os(iOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true, options: [])
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sloppy-dictation-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw DictationRecorderError.couldNotStartRecording
        }

        self.recorder = recorder
        self.fileURL = url
        self.startedAt = Date()
        #else
        throw DictationRecorderError.unavailable
        #endif
    }

    public func snapshot() -> DictationRecorderSnapshot {
        #if canImport(AVFoundation)
        guard let recorder else {
            return DictationRecorderSnapshot()
        }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        let normalized = Double(max(0.04, min(1, pow(10, averagePower / 20))))
        return DictationRecorderSnapshot(
            elapsed: recorder.currentTime,
            level: normalized,
            powerDBFS: Double(averagePower)
        )
        #else
        return DictationRecorderSnapshot()
        #endif
    }

    public func stop() async throws -> DictationCapture {
        #if canImport(AVFoundation)
        guard let recorder, let fileURL else {
            throw DictationRecorderError.noCapture
        }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileURL = nil
        self.startedAt = nil

        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif

        return DictationCapture(
            fileURL: fileURL,
            mimeType: "audio/m4a",
            duration: duration
        )
        #else
        throw DictationRecorderError.unavailable
        #endif
    }

    public func cancel() async {
        #if canImport(AVFoundation)
        recorder?.stop()
        recorder = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        self.fileURL = nil
        self.startedAt = nil
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
        #endif
    }

    #if canImport(AVFoundation)
    private func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        #endif

        #if os(iOS) || os(visionOS)
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #else
        return true
        #endif
    }
    #endif
}

public enum AppleSpeechTranscriber {
    public static func transcribe(
        fileURL: URL,
        localeIdentifier: String? = nil
    ) async throws -> String {
        #if canImport(Speech)
        let authorization = await requestAuthorization()
        guard authorization == .authorized else {
            throw AppleSpeechTranscriberError.speechRecognitionPermissionDenied
        }

        let locale = localeIdentifier.map(Locale.init(identifier:))
        let recognizer = locale.map(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw AppleSpeechTranscriberError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !didResume {
                    didResume = true
                    continuation.resume(throwing: error)
                    return
                }

                guard let result, result.isFinal, !didResume else {
                    return
                }

                didResume = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
        #else
        throw AppleSpeechTranscriberError.recognizerUnavailable
        #endif
    }

    #if canImport(Speech)
    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    #endif
}

public enum AppleSpeechTranscriberError: LocalizedError, Sendable {
    case speechRecognitionPermissionDenied
    case recognizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionPermissionDenied:
            return "Speech Recognition access is required for on-device transcription fallback."
        case .recognizerUnavailable:
            return "Speech Recognition is currently unavailable."
        }
    }
}
