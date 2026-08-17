import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class VoiceInputService: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case preparing
        case listening
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isTranscribing = false

    var isActive: Bool {
        state != .idle
    }

    private let audioEngine = AVAudioEngine()
    private let silenceDelay: Duration
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var legacyRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyRecognitionTask: SFSpeechRecognitionTask?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var inputTapIsInstalled = false
    private var finalizedTranscript = AttributedString()
    private var volatileTranscript = AttributedString()
    private var latestTranscript = ""
    private var latestCapturedTranscript = ""
    private var triggerPhrases: [[String]] = []
    private var ignoredWordCount = 0
    private var captureStartWordIndex: Int?
    private var sessionID: UUID?
    private var onTranscript: ((String) -> Void)?
    private var onUtterance: (() -> Void)?
    private var onError: ((Error) -> Void)?

    init(silenceDelay: Duration = .seconds(3)) {
        self.silenceDelay = silenceDelay
    }

    func start(
        triggerPhrases: [String],
        onTranscript: @escaping (String) -> Void,
        onUtterance: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        guard state == .idle else { return }

        let triggerPhrases = triggerPhrases
            .map { Self.words(in: $0).map(\.normalized) }
            .filter { !$0.isEmpty }
        guard !triggerPhrases.isEmpty else {
            throw VoiceInputError.triggerPhraseMissing
        }

        self.triggerPhrases = triggerPhrases

        state = .requestingPermission

        do {
            try await requestPermissions()
            guard state == .requestingPermission else { return }

            state = .preparing
            try await startAnalysis(
                onTranscript: onTranscript,
                onUtterance: onUtterance,
                onError: onError
            )
        } catch {
            let reportedError = error as? VoiceInputError
                ?? VoiceInputError.setupFailed(Self.diagnosticDescription(for: error))
            stop()
            throw reportedError
        }
    }

    func stop() {
        let analyzerToStop = analyzer

        sessionID = nil
        silenceTask?.cancel()
        silenceTask = nil
        resultsTask?.cancel()
        resultsTask = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        if inputTapIsInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapIsInstalled = false
        }

        inputContinuation?.finish()
        inputContinuation = nil
        legacyRecognitionRequest?.endAudio()
        legacyRecognitionTask?.cancel()
        legacyRecognitionRequest = nil
        legacyRecognitionTask = nil
        analyzer = nil
        transcriber = nil
        finalizedTranscript = AttributedString()
        volatileTranscript = AttributedString()
        latestTranscript = ""
        latestCapturedTranscript = ""
        triggerPhrases = []
        ignoredWordCount = 0
        captureStartWordIndex = nil
        isTranscribing = false
        onTranscript = nil
        onUtterance = nil
        onError = nil
        state = .idle

        if let analyzerToStop {
            Task {
                await analyzerToStop.cancelAndFinishNow()
            }
        }
    }

    func updateTriggerPhrases(_ phrases: [String]) {
        let triggerPhrases = phrases
            .map { Self.words(in: $0).map(\.normalized) }
            .filter { !$0.isEmpty }
        guard !triggerPhrases.isEmpty else {
            stop()
            return
        }

        self.triggerPhrases = triggerPhrases
        resetWakePhraseDetection(ignoringCurrentTranscript: true)
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch speechStatus {
        case .authorized:
            break
        case .denied:
            throw VoiceInputError.speechRecognitionDenied
        case .restricted:
            throw VoiceInputError.speechRecognitionRestricted
        case .notDetermined:
            throw VoiceInputError.speechRecognitionDenied
        @unknown default:
            throw VoiceInputError.speechRecognitionDenied
        }

        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneGranted else {
            throw VoiceInputError.microphoneDenied
        }
    }

    private func startAnalysis(
        onTranscript: @escaping (String) -> Void,
        onUtterance: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            try startLegacyRecognition(
                onTranscript: onTranscript,
                onUtterance: onUtterance,
                onError: onError
            )
            return
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        if let installationRequest = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await installationRequest.downloadAndInstall()
        }

        guard state == .preparing else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputNode = audioEngine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: microphoneFormat
        ) else {
            throw VoiceInputError.audioFormatUnavailable
        }

        guard let converter = VoiceAudioBufferConverter(
            inputFormat: microphoneFormat,
            outputFormat: analyzerFormat
        ) else {
            throw VoiceInputError.audioFormatUnavailable
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        guard state == .preparing else { return }

        let currentSessionID = UUID()
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        sessionID = currentSessionID
        latestTranscript = ""
        finalizedTranscript = AttributedString()
        volatileTranscript = AttributedString()
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.inputContinuation = inputContinuation
        self.onTranscript = onTranscript
        self.onUtterance = onUtterance
        self.onError = onError

        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.handleTranscriptionResult(result, sessionID: currentSessionID)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.handleRuntimeError(error, sessionID: currentSessionID)
            }
        }

        try await analyzer.start(inputSequence: inputSequence)
        guard sessionID == currentSessionID, state == .preparing else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: microphoneFormat) { [weak self] buffer, _ in
            do {
                let convertedBuffer = try converter.convert(buffer)
                inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
            } catch {
                Task { @MainActor in
                    self?.handleRuntimeError(error, sessionID: currentSessionID)
                }
            }
        }
        inputTapIsInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        state = .listening
    }

    private func startLegacyRecognition(
        onTranscript: @escaping (String) -> Void,
        onUtterance: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw VoiceInputError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, microphoneFormat.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }

        let currentSessionID = UUID()
        sessionID = currentSessionID
        latestTranscript = ""
        self.onTranscript = onTranscript
        self.onUtterance = onUtterance
        self.onError = onError
        legacyRecognitionRequest = request

        legacyRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                self?.handleLegacyRecognitionResult(
                    result,
                    error: error,
                    sessionID: currentSessionID
                )
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: microphoneFormat) { buffer, _ in
            request.append(buffer)
        }
        inputTapIsInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        state = .listening
    }

    private func handleTranscriptionResult(
        _ result: SpeechTranscriber.Result,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID, state == .listening else { return }

        if result.isFinal {
            finalizedTranscript += result.text
            volatileTranscript = AttributedString()
        } else {
            volatileTranscript = result.text
        }

        let combinedTranscript = finalizedTranscript + volatileTranscript
        let transcript = String(combinedTranscript.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        handleTranscript(transcript, sessionID: sessionID)
    }

    private func handleLegacyRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        sessionID: UUID
    ) {
        guard self.sessionID == sessionID, state == .listening else { return }

        if let result {
            let transcript = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            handleTranscript(transcript, sessionID: sessionID)
        }

        if let error {
            handleRuntimeError(error, sessionID: sessionID)
        }
    }

    private func handleRuntimeError(_ error: Error, sessionID: UUID) {
        guard self.sessionID == sessionID else { return }

        let onError = self.onError
        let reportedError = VoiceInputError.recognitionFailed(Self.diagnosticDescription(for: error))
        stop()
        onError?(reportedError)
    }

    private func handleTranscript(_ transcript: String, sessionID: UUID) {
        guard self.sessionID == sessionID,
              state == .listening,
              !transcript.isEmpty,
              transcript != latestTranscript else {
            return
        }

        latestTranscript = transcript
        let transcriptWords = Self.words(in: transcript)

        if transcriptWords.count < ignoredWordCount {
            resetWakePhraseDetection(ignoringCurrentTranscript: false)
        }

        var triggerWasDetected = false
        if captureStartWordIndex == nil,
           let triggerRange = triggerRange(in: transcriptWords) {
            captureStartWordIndex = triggerRange.upperBound
            isTranscribing = true
            triggerWasDetected = true
        }

        guard let captureStartWordIndex else { return }

        let capturedTranscript: String
        if captureStartWordIndex < transcriptWords.count {
            let startIndex = transcriptWords[captureStartWordIndex].range.lowerBound
            capturedTranscript = String(transcript[startIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            capturedTranscript = ""
        }

        let capturedTranscriptChanged = capturedTranscript != latestCapturedTranscript
        guard capturedTranscriptChanged || triggerWasDetected else { return }

        latestCapturedTranscript = capturedTranscript
        if capturedTranscriptChanged {
            onTranscript?(capturedTranscript)
        }

        scheduleFinishAfterSilence(for: sessionID)
    }

    private func triggerRange(in transcriptWords: [TranscriptWord]) -> Range<Int>? {
        var bestMatch: Range<Int>?

        for triggerWords in triggerPhrases where transcriptWords.count >= triggerWords.count {
            let firstCandidate = min(ignoredWordCount, transcriptWords.count)
            let lastCandidate = transcriptWords.count - triggerWords.count
            guard firstCandidate <= lastCandidate else { continue }

            for candidate in firstCandidate...lastCandidate {
                let candidateRange = candidate..<(candidate + triggerWords.count)
                guard zip(transcriptWords[candidateRange], triggerWords).allSatisfy({ word, triggerWord in
                    word.normalized == triggerWord
                }) else {
                    continue
                }

                if bestMatch == nil
                    || candidateRange.lowerBound < bestMatch!.lowerBound
                    || (candidateRange.lowerBound == bestMatch!.lowerBound
                        && candidateRange.count > bestMatch!.count) {
                    bestMatch = candidateRange
                }
                break
            }
        }

        return bestMatch
    }

    private func scheduleFinishAfterSilence(for sessionID: UUID) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self, silenceDelay] in
            do {
                try await Task.sleep(for: silenceDelay)
            } catch {
                return
            }

            guard let self,
                  self.sessionID == sessionID,
                  self.isTranscribing else {
                return
            }

            let hasUtterance = !self.latestCapturedTranscript.isEmpty
            let onUtterance = self.onUtterance
            self.resetWakePhraseDetection(ignoringCurrentTranscript: true)
            if hasUtterance {
                onUtterance?()
            }
        }
    }

    private func resetWakePhraseDetection(ignoringCurrentTranscript: Bool) {
        silenceTask?.cancel()
        silenceTask = nil
        ignoredWordCount = ignoringCurrentTranscript ? Self.words(in: latestTranscript).count : 0
        captureStartWordIndex = nil
        latestCapturedTranscript = ""
        isTranscribing = false
    }

    private static func words(in text: String) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { substring, range, _, _ in
            guard let substring else { return }
            let normalized = substring
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased(with: .current)
            words.append(TranscriptWord(normalized: normalized, range: range))
        }
        return words
    }

    private static func diagnosticDescription(for error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) [\(error.domain) \(error.code)]"
    }
}

private struct TranscriptWord {
    let normalized: String
    let range: Range<String.Index>
}

private final class VoiceAudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let sampleRateRatio: Double

    init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }

        self.converter = converter
        self.outputFormat = outputFormat
        sampleRateRatio = outputFormat.sampleRate / inputFormat.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let scaledFrameCount = ceil(Double(buffer.frameLength) * sampleRateRatio)
        let frameCapacity = AVAudioFrameCount(max(scaledFrameCount + 32, 1))
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw VoiceInputError.audioConversionFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }

            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw conversionError ?? VoiceInputError.audioConversionFailed
        }

        return convertedBuffer
    }
}

enum VoiceInputError: LocalizedError {
    case audioConversionFailed
    case audioFormatUnavailable
    case microphoneDenied
    case microphoneUnavailable
    case recognizerUnavailable
    case recognitionFailed(String)
    case setupFailed(String)
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case triggerPhraseMissing

    var errorDescription: String? {
        switch self {
        case .audioConversionFailed:
            return "Chat could not convert microphone audio for speech recognition."
        case .audioFormatUnavailable:
            return "Apple speech recognition could not find a compatible microphone format."
        case .microphoneDenied:
            return "Microphone access is off. Allow Chat to use the microphone in System Settings, then try again."
        case .microphoneUnavailable:
            return "No microphone input is currently available."
        case .recognizerUnavailable:
            return "Apple speech recognition is currently unavailable for your language."
        case .recognitionFailed(let details):
            return "Voice input stopped because speech recognition failed. \(details)"
        case .setupFailed(let details):
            return "Voice input could not be prepared. \(details)"
        case .speechRecognitionDenied:
            return "Speech recognition access is off. Allow Chat to use Speech Recognition in System Settings, then try again."
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this Mac."
        case .triggerPhraseMissing:
            return "Set a voice phrase for this persona before starting voice mode."
        }
    }
}
