import AppKit
import SwiftUI
import CoreAudio
import MeetingCore

// Небольшое плавающее облако-уведомление внизу экрана — отдельное от главного
// окна приложения (не модальное), не отбирает фокус у браузера/встречи.
@MainActor
final class MeetingAlertPanelController {
    static let shared = MeetingAlertPanelController()

    private var panel: NSPanel?

    func show(store: JobStore, platform: String, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()

        NSSound(named: "Glass")?.play()

        let size = NSSize(width: 380, height: 132)
        let content = MeetingAlertBubbleView(
            store: store,
            platform: platform,
            onStart: { [weak self] in onStart(); self?.hide() },
            onDismiss: { [weak self] in onDismiss(); self?.hide() }
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting

        if let screenFrame = NSScreen.main?.visibleFrame {
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.minY + 32
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Содержимое облака

struct MeetingAlertBubbleView: View {
    @ObservedObject var store: JobStore
    let platform: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "video.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Похоже, у тебя встреча")
                        .font(.headline)
                    Text("\(platform) — записать и сделать саммари?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    Button("Начать запись") { onStart() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Не сейчас") { onDismiss() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            MicrophonePickerView(store: store)
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.1)))
    }
}

// MARK: - Выбор микрофона (используется и в облаке, и на вкладке «Записи встреч»)

struct MicrophonePickerView: View {
    @ObservedObject var store: JobStore

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: Binding<AudioDeviceID>(
                get: { store.selectedMicrophoneDeviceID ?? AudioDevices.defaultInputDeviceID() ?? 0 },
                set: { newValue in
                    store.selectedMicrophoneDeviceID = newValue == AudioDevices.defaultInputDeviceID() ? nil : newValue
                }
            )) {
                ForEach(store.availableMicrophones) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
        }
        .onAppear { store.refreshMicrophoneList() }
    }
}
