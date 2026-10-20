import Foundation
import AVFoundation

// Запись голоса с микрофона в файл для последующей транскрибации.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {

    @Published var isRecording: Bool = false
    @Published var elapsedSeconds: Int = 0
    @Published var permissionDenied: Bool = false

    // Уровень сигнала с микрофона, 0…1. Нужен, чтобы показать «эквалайзер»:
    // по бегущему таймеру непонятно, идёт ли запись на самом деле и слышно ли
    // голос, а по живой шкале это видно сразу.
    @Published var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?

    // destination — куда писать; без него запись идёт во временную папку.
    func start(to destination: URL? = nil) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginRecording(to: destination)
                } else {
                    self.permissionDenied = true
                }
            }
        }
    }

    private func beginRecording(to destination: URL?) {
        let name = "запись-микрофона-" + ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-") + ".wav"
        let url = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent(name)
        outputURL = url

        // Несжатый звук: прерванный AAC-файл читается плохо или не читается
        // вовсе, а PCM сохраняет всё, что успело записаться до обрыва.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            self.isRecording = true
            self.elapsedSeconds = 0
            // Шкала обновляется чаще секунды, иначе она выглядит мёртвой.
            var ticks = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    ticks += 1
                    if ticks % 10 == 0 { self.elapsedSeconds += 1 }
                    self.updateLevel()
                }
            }
        } catch {
            self.permissionDenied = true
        }
    }

    // Громкость приходит в децибелах (-160…0). Переводим в понятную долю:
    // тише -50 дБ считаем тишиной, дальше растягиваем на всю шкалу.
    private func updateLevel() {
        guard let recorder, recorder.isRecording else {
            level = 0
            return
        }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        let floor = -50.0
        let normalized = decibels <= floor ? 0 : (decibels - floor) / (0 - floor)
        // Сглаживаем, чтобы полосы не дёргались на каждом такте.
        level = level * 0.6 + min(max(normalized, 0), 1) * 0.4
    }

    // Останавливает запись и возвращает путь к готовому аудиофайлу.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
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
        level = 0
        outputURL = nil
    }
}
