import Foundation
import AVFoundation
import MeetingCore

// Небольшой проигрыватель записи встречи. Нужен, чтобы проверить спорное место
// в расшифровке, не разыскивая файл в Finder и не открывая ради него отдельное
// приложение: сомнительные куски проще послушать прямо рядом с текстом.
@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {

    @Published private(set) var currentPath: String? = nil
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    // Открывает файл, но не начинает воспроизведение: человек сам решает, когда
    // слушать. Повторный вызов с тем же файлом ничего не сбрасывает.
    func load(path: String) {
        guard currentPath != path else { return }
        stop()
        guard FileManager.default.fileExists(atPath: path) else {
            currentPath = nil
            duration = 0
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            self.currentPath = path
            self.duration = player.duration
            self.currentTime = 0
        } catch {
            player = nil
            currentPath = nil
            duration = 0
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = min(max(time, 0), player.duration)
        currentTime = player.currentTime
    }

    // Перемотка на пятнадцать секунд — привычный шаг, которым удобно
    // возвращаться к только что прозвучавшей фразе.
    func skip(by seconds: Double) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentPath = nil
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }

    static func timeText(_ seconds: Double) -> String {
        return TimeFormat.mmss(seconds)
    }
}
