import AVFoundation
import Foundation
import Speech

/// Push-to-talk for Simplified Chinese and US English.
/// Prefers the on-device recognizer. Audio is not written to disk.
final class SpeechDictation {
    enum Language: String {
        case chinese = "zh-CN"
        case english = "en-US"

        var title: String { self == .chinese ? "中文" : "English" }

        mutating func toggle() {
            self = self == .chinese ? .english : .chinese
        }
    }

    private(set) var language: Language = .chinese
    private(set) var listening = false
    private(set) var usesOnDevice = false
    private(set) var partial = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sawFinal = false
    private var tapInstalled = false
    private let lock = NSLock()

    func currentPartial() -> String {
        lock.lock()
        defer { lock.unlock() }
        return partial
    }

    func toggleLanguage() {
        guard !listening else { return }
        language.toggle()
    }

    func preparePermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func authorizationMessage() -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            return "语音识别尚未授权"
        case .denied, .restricted:
            return "语音识别被拒绝，请在系统设置中允许"
        @unknown default:
            return "语音识别不可用"
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return nil
        case .undetermined:
            return "麦克风尚未授权"
        case .denied:
            return "麦克风被拒绝，请在系统设置中允许"
        @unknown default:
            return "麦克风不可用"
        }
    }

    /// Empty string means listening started.
    func start() -> String {
        if let blocked = authorizationMessage() { return blocked }
        guard !listening, request == nil else { return "上一段听写还在结束" }
        let locale = Locale(identifier: language.rawValue)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            return "\(language.title) 识别器不可用"
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        usesOnDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = usesOnDevice
        lock.lock()
        partial = ""
        sawFinal = false
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            return "麦克风没有可用的输入格式"
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result {
                self.partial = result.bestTranscription.formattedString
                if result.isFinal { self.sawFinal = true }
            }
            if error != nil { self.sawFinal = true }
            self.lock.unlock()
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            task?.cancel()
            task = nil
            self.request = nil
            teardownEngine()
            return "无法打开麦克风"
        }
        listening = true
        return ""
    }

    func finish(_ completion: @escaping (String) -> Void) {
        guard listening else { completion(""); return }
        listening = false
        teardownEngine()
        request?.endAudio()
        poll(tries: 24, completion: completion)
    }

    private func poll(tries: Int, completion: @escaping (String) -> Void) {
        lock.lock()
        let done = sawFinal || tries == 0
        let text = partial
        lock.unlock()
        if done {
            task?.finish()
            task = nil
            request = nil
            completion(text)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.poll(tries: tries - 1, completion: completion)
        }
    }

    private func teardownEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }
}
