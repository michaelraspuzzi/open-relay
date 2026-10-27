@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Tap-to-dictate into the composer: on-device speech recognition with live partial results.
@MainActor @Observable
final class Dictation {
    private(set) var isRecording = false
    /// 0…1 input level, for the button's pulse.
    private(set) var level: Float = 0
    var onText: (String) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        Task {
            guard await Self.authorize() else {
                onError("Relay needs Microphone and Speech Recognition access. Turn them on in System Settings › Privacy & Security.")
                return
            }
            do { try begin() } catch { onError("Couldn't start dictation: \(error.localizedDescription)") ; stop() }
        }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        isRecording = false
        level = 0
    }

    private func begin() throws {
        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        Self.installTap(on: engine.inputNode, request: request) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()
        isRecording = true

        task = Self.recognize(with: recognizer, request: request) { [weak self] text, done in
            Task { @MainActor in
                guard let self else { return }
                if let text { self.onText(text) }
                if done { self.stop() }
            }
        }
    }

    // Audio and recognition callbacks run off the main thread, so they're built outside MainActor.

    nonisolated private static func installTap(on input: AVAudioInputNode, request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping @Sendable (Float) -> Void) {
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += samples[i] * samples[i] }
            level(min(1, sqrt(sum / Float(max(count, 1))) * 12))
        }
    }

    nonisolated private static func recognize(with recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    enum DictationError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available right now." }
    }
}
