import AVFoundation
import Combine
import Foundation

struct TextToSpeechPlaybackConfiguration: Sendable {
    let executablePath: String
    let voiceName: String
    let voiceModel: String
}

private final class TextToSpeechProcessController: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var cancellationWasRequested = false

    nonisolated init() {}

    nonisolated func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationWasRequested else { return false }
        self.process = process
        return true
    }

    nonisolated func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if self.process === process {
            self.process = nil
        }
    }

    nonisolated func cancel() {
        lock.lock()
        cancellationWasRequested = true
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    nonisolated var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationWasRequested
    }
}

@MainActor
final class TextToSpeechPlaybackService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var generatedAudioChunkIndexesByMessageID: [UUID: [Int]] = [:]
    @Published private(set) var isGenerating = false
    @Published private(set) var isPlaying = false
    @Published private(set) var playingMessageID: UUID?
    @Published private(set) var playingChunkIndex: Int?
    @Published private(set) var playbackCurrentTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0

    private struct GenerationRequest {
        let messageID: UUID
        let chunkIndex: Int
        let text: String
        let configuration: TextToSpeechPlaybackConfiguration
        let onError: (Error) -> Void
    }

    private struct PlaybackRequest {
        let messageID: UUID
        let chunkIndex: Int
        let outputURL: URL
        let onError: (Error) -> Void
    }

    private var pendingGenerationRequests: [GenerationRequest] = []
    private var pendingPlaybackRequests: [PlaybackRequest] = []
    private var generatedAudioURLs: [UUID: [Int: URL]] = [:]
    private var automaticPlaybackSuppressedMessageIDs: Set<UUID> = []

    private var generationTask: Task<Void, Never>?
    private var currentGenerationID: UUID?

    private var currentPlaybackRequest: PlaybackRequest?
    private var audioPlayer: AVAudioPlayer?
    private var playbackProgressTask: Task<Void, Never>?

    func enqueue(
        messageID: UUID,
        text: String,
        configuration: TextToSpeechPlaybackConfiguration,
        onError: @escaping (Error) -> Void
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        automaticPlaybackSuppressedMessageIDs.remove(messageID)
        removeGeneratedAudio(for: messageID)
        let chunks = Self.audioChunks(for: trimmedText)
        pendingGenerationRequests.append(
            contentsOf: chunks.enumerated().map { chunkIndex, chunk in
                GenerationRequest(
                    messageID: messageID,
                    chunkIndex: chunkIndex,
                    text: chunk,
                    configuration: configuration,
                    onError: onError
                )
            }
        )
        processNextGenerationIfNeeded()
    }

    func replay(
        messageID: UUID,
        chunkIndex: Int,
        onError: @escaping (Error) -> Void
    ) {
        guard let outputURL = generatedAudioURLs[messageID]?[chunkIndex],
              FileManager.default.fileExists(atPath: outputURL.path) else {
            removeGeneratedAudioChunk(messageID: messageID, chunkIndex: chunkIndex)
            onError(TextToSpeechPlaybackError.audioUnavailable)
            return
        }

        pendingPlaybackRequests.append(
            PlaybackRequest(
                messageID: messageID,
                chunkIndex: chunkIndex,
                outputURL: outputURL,
                onError: onError
            )
        )
        processNextPlaybackIfNeeded()
    }

    func cancelGeneration() {
        currentGenerationID = nil
        generationTask?.cancel()
        generationTask = nil
        pendingGenerationRequests.removeAll()
        isGenerating = false
    }

    func stopPlayback() {
        if let messageID = currentPlaybackRequest?.messageID {
            automaticPlaybackSuppressedMessageIDs.insert(messageID)
        }
        pendingPlaybackRequests.removeAll()
        finishCurrentPlayback(continueWithNextRequest: false)
    }

    func seekPlayback(to time: TimeInterval) {
        guard let audioPlayer else { return }
        let clampedTime = min(max(time, 0), audioPlayer.duration)
        audioPlayer.currentTime = clampedTime
        playbackCurrentTime = clampedTime
    }

    func stop() {
        cancelGeneration()
        stopPlayback()
    }

    func clearGeneratedAudio() {
        stop()
        for outputURL in Set(generatedAudioURLs.values.flatMap { $0.values }) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        generatedAudioURLs.removeAll()
        generatedAudioChunkIndexesByMessageID.removeAll()
        automaticPlaybackSuppressedMessageIDs.removeAll()
    }

    private func processNextGenerationIfNeeded() {
        guard currentGenerationID == nil, !pendingGenerationRequests.isEmpty else { return }

        let request = pendingGenerationRequests.removeFirst()
        let generationID = UUID()
        currentGenerationID = generationID
        isGenerating = true

        generationTask = Task { [weak self] in
            do {
                let outputURL = try await Self.generateAudio(
                    text: request.text,
                    configuration: request.configuration
                )

                guard let self, self.currentGenerationID == generationID else {
                    try? FileManager.default.removeItem(at: outputURL)
                    return
                }

                try Task.checkCancellation()
                self.storeGeneratedAudio(
                    outputURL,
                    messageID: request.messageID,
                    chunkIndex: request.chunkIndex
                )
                if !self.automaticPlaybackSuppressedMessageIDs.contains(request.messageID) {
                    self.pendingPlaybackRequests.append(
                        PlaybackRequest(
                            messageID: request.messageID,
                            chunkIndex: request.chunkIndex,
                            outputURL: outputURL,
                            onError: request.onError
                        )
                    )
                    self.processNextPlaybackIfNeeded()
                }
                self.finishCurrentGeneration()
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.currentGenerationID == generationID else { return }
                self.pendingGenerationRequests.removeAll {
                    $0.messageID == request.messageID
                }
                self.finishCurrentGeneration()
                request.onError(error)
            }
        }
    }

    private func finishCurrentGeneration() {
        generationTask = nil
        currentGenerationID = nil
        isGenerating = false
        processNextGenerationIfNeeded()
    }

    private func processNextPlaybackIfNeeded() {
        guard audioPlayer == nil, !pendingPlaybackRequests.isEmpty else { return }

        let request = pendingPlaybackRequests.removeFirst()
        do {
            let player = try AVAudioPlayer(contentsOf: request.outputURL)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                throw TextToSpeechPlaybackError.playbackFailed
            }

            currentPlaybackRequest = request
            audioPlayer = player
            playingMessageID = request.messageID
            playingChunkIndex = request.chunkIndex
            isPlaying = true
            playbackCurrentTime = player.currentTime
            playbackDuration = player.duration
            startPlaybackProgressUpdates()
        } catch {
            resetCurrentPlayback()
            request.onError(error)
            processNextPlaybackIfNeeded()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            let onError = self.currentPlaybackRequest?.onError
            self.finishCurrentPlayback()
            if !flag {
                onError?(TextToSpeechPlaybackError.playbackFailed)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reportedError = error ?? TextToSpeechPlaybackError.playbackFailed
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            let onError = self.currentPlaybackRequest?.onError
            self.finishCurrentPlayback()
            onError?(reportedError)
        }
    }

    private func finishCurrentPlayback(continueWithNextRequest: Bool = true) {
        audioPlayer?.stop()
        resetCurrentPlayback()
        if continueWithNextRequest {
            processNextPlaybackIfNeeded()
        }
    }

    private func resetCurrentPlayback() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
        audioPlayer = nil
        currentPlaybackRequest = nil
        playingMessageID = nil
        playingChunkIndex = nil
        isPlaying = false
        playbackCurrentTime = 0
        playbackDuration = 0
    }

    private func startPlaybackProgressUpdates() {
        playbackProgressTask?.cancel()
        playbackProgressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }

                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackCurrentTime = audioPlayer.currentTime
                self.playbackDuration = audioPlayer.duration
            }
        }
    }

    private func storeGeneratedAudio(_ outputURL: URL, messageID: UUID, chunkIndex: Int) {
        var messageAudio = generatedAudioURLs[messageID] ?? [:]
        if let previousURL = messageAudio.updateValue(outputURL, forKey: chunkIndex),
           previousURL != outputURL {
            try? FileManager.default.removeItem(at: previousURL)
        }
        generatedAudioURLs[messageID] = messageAudio
        generatedAudioChunkIndexesByMessageID[messageID] = messageAudio.keys.sorted()
    }

    private func removeGeneratedAudio(for messageID: UUID) {
        if let messageAudio = generatedAudioURLs.removeValue(forKey: messageID) {
            for outputURL in messageAudio.values {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        generatedAudioChunkIndexesByMessageID.removeValue(forKey: messageID)
    }

    private func removeGeneratedAudioChunk(messageID: UUID, chunkIndex: Int) {
        guard var messageAudio = generatedAudioURLs[messageID] else { return }
        if let outputURL = messageAudio.removeValue(forKey: chunkIndex) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        if messageAudio.isEmpty {
            generatedAudioURLs.removeValue(forKey: messageID)
            generatedAudioChunkIndexesByMessageID.removeValue(forKey: messageID)
        } else {
            generatedAudioURLs[messageID] = messageAudio
            generatedAudioChunkIndexesByMessageID[messageID] = messageAudio.keys.sorted()
        }
    }

    private nonisolated static func audioChunks(
        for text: String,
        maximumWordCount: Int = 100
    ) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(in: trimmedText) > maximumWordCount else {
            return trimmedText.isEmpty ? [] : [trimmedText]
        }

        var sentences: [String] = []
        trimmedText.enumerateSubstrings(
            in: trimmedText.startIndex..<trimmedText.endIndex,
            options: .bySentences
        ) { substring, _, _, _ in
            guard let substring else { return }
            let sentence = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        if sentences.isEmpty {
            sentences = [trimmedText]
        }

        let sentenceSizedParts = sentences.flatMap { sentence -> [String] in
            guard wordCount(in: sentence) > maximumWordCount else {
                return [sentence]
            }

            let words = sentence.split(whereSeparator: { $0.isWhitespace })
            return stride(from: 0, to: words.count, by: maximumWordCount).map { start in
                let end = min(start + maximumWordCount, words.count)
                return words[start..<end].joined(separator: " ")
            }
        }

        var chunks: [String] = []
        var currentSentences: [String] = []
        var currentWordCount = 0

        for part in sentenceSizedParts {
            let partWordCount = wordCount(in: part)
            if !currentSentences.isEmpty,
               currentWordCount + partWordCount > maximumWordCount {
                chunks.append(currentSentences.joined(separator: " "))
                currentSentences.removeAll(keepingCapacity: true)
                currentWordCount = 0
            }

            currentSentences.append(part)
            currentWordCount += partWordCount
        }

        if !currentSentences.isEmpty {
            chunks.append(currentSentences.joined(separator: " "))
        }

        return chunks
    }

    private nonisolated static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private nonisolated static func generateAudio(
        text: String,
        configuration: TextToSpeechPlaybackConfiguration
    ) async throws -> URL {
        let processController = TextToSpeechProcessController()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let executablePath = configuration.executablePath
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard executablePath.hasPrefix("/") else {
                    throw TextToSpeechPlaybackError.invalidExecutablePath
                }
                guard !processController.isCancelled else {
                    throw CancellationError()
                }

                let outputDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ChatVoiceAudio", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
                let outputURL = outputDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("wav")

                do {
                    let process = Process()
                    let diagnosticPipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = [
                        "--voice", configuration.voiceName,
                        "--tool", configuration.voiceModel,
                        "--text", text,
                        "--output", outputURL.path
                    ]
                    process.standardOutput = diagnosticPipe
                    process.standardError = diagnosticPipe

                    guard processController.register(process) else {
                        throw CancellationError()
                    }
                    defer { processController.clear(process) }

                    do {
                        try process.run()
                    } catch {
                        if processController.isCancelled {
                            throw CancellationError()
                        }
                        throw TextToSpeechPlaybackError.launchFailed(
                            path: executablePath,
                            diagnostic: error.localizedDescription
                        )
                    }

                    if processController.isCancelled, process.isRunning {
                        process.terminate()
                    }

                    let diagnosticData = diagnosticPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard !processController.isCancelled else {
                        throw CancellationError()
                    }

                    guard process.terminationStatus == 0 else {
                        let diagnostic = String(data: diagnosticData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TextToSpeechPlaybackError.commandFailed(
                            status: process.terminationStatus,
                            diagnostic: diagnostic
                        )
                    }

                    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                    let fileSize = attributes[.size] as? NSNumber
                    guard fileSize?.intValue ?? 0 > 0 else {
                        throw TextToSpeechPlaybackError.outputMissing
                    }

                    return outputURL
                } catch {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw error
                }
            }.value
        } onCancel: {
            processController.cancel()
        }
    }
}

enum TextToSpeechPlaybackError: LocalizedError {
    case audioUnavailable
    case commandFailed(status: Int32, diagnostic: String?)
    case invalidExecutablePath
    case launchFailed(path: String, diagnostic: String)
    case outputMissing
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .audioUnavailable:
            return "The generated voice audio is no longer available."
        case .commandFailed(let status, let diagnostic):
            let details: String
            if let diagnostic, !diagnostic.isEmpty {
                details = " \(diagnostic)"
            } else {
                details = ""
            }
            return "The voice tool exited with status \(status).\(details)"
        case .invalidExecutablePath:
            return "The voice tool needs an absolute executable path."
        case .launchFailed(let path, let diagnostic):
            return "The voice tool could not be launched at \(path). \(diagnostic)"
        case .outputMissing:
            return "The voice tool did not create a playable WAV file."
        case .playbackFailed:
            return "The generated voice audio could not be played."
        }
    }
}
