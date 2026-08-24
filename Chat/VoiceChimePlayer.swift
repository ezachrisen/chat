import AVFoundation
import Foundation

enum VoiceChimeCue {
    case dictationStarted
    case utteranceSent
    case responseReady
    case segmentContinues
    case handover

    fileprivate var resourceName: String {
        switch self {
        case .dictationStarted: "dictation-started"
        case .utteranceSent: "utterance-sent"
        case .responseReady: "response-ready"
        case .segmentContinues: "segment-continues"
        case .handover: "handover"
        }
    }
}

@MainActor
final class VoiceChimePlayer {
    static let shared = VoiceChimePlayer()

    private var audioPlayer: AVAudioPlayer?

    private init() {}

    @discardableResult
    func play(_ cue: VoiceChimeCue) -> Duration {
        guard let resourceURL = resourceURL(for: cue) else { return .zero }

        do {
            let player = try AVAudioPlayer(contentsOf: resourceURL)
            player.volume = 0.72
            player.prepareToPlay()
            guard player.play() else { return .zero }

            audioPlayer = player
            return .milliseconds(Int64((player.duration * 1_000).rounded(.up)))
        } catch {
            return .zero
        }
    }

    func stopAll() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func resourceURL(for cue: VoiceChimeCue) -> URL? {
        Bundle.main.url(
            forResource: cue.resourceName,
            withExtension: "wav",
            subdirectory: "VoiceChimes"
        ) ?? Bundle.main.url(
            forResource: cue.resourceName,
            withExtension: "wav"
        )
    }
}
