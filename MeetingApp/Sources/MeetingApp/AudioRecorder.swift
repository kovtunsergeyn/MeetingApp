import Foundation
import AVFoundation

// Запись голоса с микрофона в файл для последующей транскрибации.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isRecording: Bool = false
    @Published var elapsedSeconds: Int = 0
    @Published var permissionDenied: Bool = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?

    func start() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginRecording()
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    private func beginRecording() {
        let dir = FileManager.default.temporaryDirectory
        let name = "запись-микрофона-" + ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + ".m4a"
        let url = dir.appendingPathComponent(name)
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.record()
            self.recorder = recorder
            self.isRecording = true
            self.elapsedSeconds = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsedSeconds += 1 }
            }
        } catch {
            self.permissionDenied = true
        }
    }

    // Останавливает запись и возвращает путь к готовому аудиофайлу.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        outputURL = nil
    }
}
