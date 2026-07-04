import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var hostAddress = "192.168.1.10" {
        didSet {
            UserDefaults.standard.set(hostAddress, forKey: Self.hostAddressDefaultsKey)
        }
    }
    @Published var pairCode = ""
    @Published var connectionState = "Idle"
    @Published var selectedPreset: StreamPreset = .hd720p30
    @Published var cameraPosition: CameraPosition = .back
    @Published var isStreaming = false

    let captureManager = CaptureManager()
    let transport = StreamTransport()
    private static let hostAddressDefaultsKey = "hostAddress"
    private var cancellables = Set<AnyCancellable>()

    init() {
        hostAddress = UserDefaults.standard.string(forKey: Self.hostAddressDefaultsKey) ?? hostAddress
        captureManager.delegate = self
        Task { await transport.setDelegate(self) }
        observeLifecycle()
    }

    func start() {
        Task {
            do {
                try await captureManager.configure(position: cameraPosition, preset: selectedPreset)
                try await transport.connect(host: hostAddress)
                connectionState = "Connected"
            } catch {
                connectionState = "Failed: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        Task {
            await transport.stopStreaming(reason: "user_stopped")
            captureManager.stop()
            isStreaming = false
            connectionState = "Stopped"
        }
    }

    func switchCamera() {
        cameraPosition = cameraPosition == .back ? .front : .back
        Task {
            do {
                try await captureManager.switchCamera(to: cameraPosition)
                await transport.sendSwitchCamera(position: cameraPosition)
            } catch {
                connectionState = "Switch failed: \(error.localizedDescription)"
            }
        }
    }

    func togglePreset() {
        selectedPreset = selectedPreset == .hd720p30 ? .hd1080p30 : .hd720p30
        Task {
            do {
                try await captureManager.applyPreset(selectedPreset)
                await transport.sendPreset(selectedPreset)
            } catch {
                connectionState = "Preset failed: \(error.localizedDescription)"
            }
        }
    }

    private func observeLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { await self?.transport.sendStatus(.appBackgrounded, detail: nil) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { await self?.transport.sendStatus(.appForegrounded, detail: nil) }
            }
            .store(in: &cancellables)
    }
}

extension AppModel: CaptureManagerDelegate {
    func captureManager(_ manager: CaptureManager, didEncode frame: EncodedFrame) {
        Task {
            await transport.sendVideo(frame: frame)
        }
    }
}

extension AppModel: StreamTransportDelegate {
    nonisolated func transportDidReceivePairCode(_ code: String) {
        Task { @MainActor in
            self.pairCode = code
            self.connectionState = "Pairing"
        }
        Task {
            await transport.sendPairRequest(code: code, deviceName: UIDevice.current.name)
        }
    }

    nonisolated func transportDidStartStream(sessionID: UUID, config: SessionConfig) {
        Task { @MainActor in
            self.isStreaming = true
            self.connectionState = "Streaming"
            self.cameraPosition = config.cameraPosition
            self.selectedPreset = config.preset
        }
        Task {
            do {
                try await captureManager.startStreaming(sessionID: sessionID)
            } catch {
                await MainActor.run {
                    self.connectionState = "Capture failed: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated func transportDidStopStream(reason: String?) {
        Task { @MainActor in
            self.captureManager.stop()
            self.isStreaming = false
            self.connectionState = reason ?? "Stopped"
        }
    }
}
