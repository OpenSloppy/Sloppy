enum DesktopComposerAction {
    case record, finishRecording, transcribing, send

    var title: String {
        switch self {
        case .record: "Voice"
        case .finishRecording: "Finish"
        case .transcribing: "Transcribing…"
        case .send: "Send"
        }
    }

    var symbol: String {
        switch self {
        case .record: "mic"
        case .finishRecording: "stop.circle.fill"
        case .transcribing: "waveform"
        case .send: "arrow.up"
        }
    }
}
