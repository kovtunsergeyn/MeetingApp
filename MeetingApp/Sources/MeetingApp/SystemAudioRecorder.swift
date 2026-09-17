import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

// Пишет системный звук (то, что играет из динамиков/наушников — то есть
// голоса собеседников из Zoom/браузера) в отдельный файл через ScreenCaptureKit.
// Требует разрешение «Запись экрана» для этого приложения — видео при этом
// не сохраняется, картинка нужна ScreenCaptureKit только формально.
@MainActor
final class SystemAudioRecorder: NSObject, ObservableObject, SCStreamDelegate {
    @Published var isRecording = false
    @Published var permissionDenied = false
    @Published var lastErrorMessage: String? = nil

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let sampleQueue = DispatchQueue(label: "ru.sk.meetingapp.system-audio")

    func start() async -> URL? {
        lastErrorMessage = nil

        // ScreenCaptureKit сам по себе ненадёжно показывает системный диалог
        // согласия — то опаздывает, то не появляется вовсе, и тогда сразу
        // прилетает -3801, будто пользователь отказался. Поэтому сначала
        // явно проверяем и запрашиваем через CoreGraphics: если уже разрешено —
        // идём дальше сразу, если нет — показываем диалог и ждём ответа.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            let granted = await waitForScreenCaptureAccess(timeout: 30)
            guard granted else {
                lastErrorMessage = "Разрешение «Запись экрана» не подтверждено (диалог не был отвечен «Разрешить» в течение 30 секунд)."
                permissionDenied = true
                return nil
            }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                lastErrorMessage = "Не нашёл ни одного экрана для захвата звука (SCShareableContent.displays пуст)."
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // Видео нам не нужно — сводим его к минимуму, чтобы не тратить ресурсы.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("system-audio-\(UUID().uuidString).m4a")
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                lastErrorMessage = "AVAssetWriter отказался принять аудиодорожку (canAdd(input) == false)."
                return nil
            }
            writer.add(input)
            writer.startWriting()

            self.assetWriter = writer
            self.audioInput = input
            self.sessionStarted = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            isRecording = true
            return url
        } catch {
            lastErrorMessage = "\(error)"
            permissionDenied = true
            return nil
        }
    }

    // Ждём, пока пользователь ответит на системный диалог (или до таймаута),
    // проверяя статус каждые полсекунды.
    private func waitForScreenCaptureAccess(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGPreflightScreenCaptureAccess() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return CGPreflightScreenCaptureAccess()
    }

    func stop() async -> URL? {
        guard let stream else { return nil }
        try? await stream.stopCapture()
        self.stream = nil
        isRecording = false

        guard let writer = assetWriter, let input = audioInput else { return nil }
        input.markAsFinished()
        await writer.finishWriting()
        assetWriter = nil
        audioInput = nil
        return writer.status == .completed ? writer.outputURL : nil
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, let input = audioInput, let writer = assetWriter else { return }
        guard writer.status == .writing || writer.status == .unknown else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.isRecording = false
        }
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        Task { @MainActor [weak self] in
            self?.handle(sampleBuffer)
        }
    }
}
