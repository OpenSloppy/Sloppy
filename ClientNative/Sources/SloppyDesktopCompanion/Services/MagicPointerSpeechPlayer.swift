import Foundation
import AVFoundation

@MainActor
final class MagicPointerSpeechPlayer: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?
    var localeIdentifier = "ru-RU"

    override init() { super.init(); synthesizer.delegate = self }

    func speak(_ text: String) async {
        stop()
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: String(text.prefix(6_000)))
        utterance.voice = AVSpeechSynthesisVoice(language: localeIdentifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        let continuation = self.continuation
        self.continuation = nil; currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        continuation?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { complete(utterance) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { complete(utterance) }

    private func complete(_ utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        let continuation = self.continuation
        self.continuation = nil; currentUtterance = nil
        continuation?.resume()
    }
}
