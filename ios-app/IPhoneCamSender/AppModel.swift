import AVFoundation
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
    // Default to 1080p: this is a LAN link with bandwidth to spare, and the
    // sender now pins a high maxBitrate so the higher resolution actually holds.
    @Published var selectedPreset: StreamPreset = .hd1080p30
    @Published var cameraPosition: CameraPosition = .back
    @Published var isStreaming = false

    let captureManager = CaptureManager()
    private static let hostAddressDefaultsKey = "hostAddress"

    init() {
        hostAddress = UserDefaults.standard.string(forKey: Self.hostAddressDefaultsKey) ?? hostAddress
    }

    /// Starts the native capture session that backs the in-app hero preview.
    /// Must be stopped (via `stopPreview()`) before the WebRTC WebView captures the
    /// camera, since only one owner can hold the device at a time.
    func startPreview() {
        Task {
            do {
                try await captureManager.configure(position: cameraPosition, preset: selectedPreset)
            } catch {
                connectionState = "Camera error: \(error.localizedDescription)"
            }
        }
    }

    func stopPreview() {
        captureManager.stop()
    }

    /// Applies a camera/quality change reported live by the WebRTC sender page so the
    /// main-screen chips (and the resumed preview) stay in sync with what is streaming.
    func applyWebRTCConfig(facing: String, quality: Int) {
        cameraPosition = facing == "user" ? .front : .back
        selectedPreset = quality == 1080 ? .hd1080p30 : .hd720p30
    }

    func switchCamera() {
        cameraPosition = cameraPosition == .back ? .front : .back
        Task {
            do {
                try await captureManager.switchCamera(to: cameraPosition)
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
            } catch {
                connectionState = "Preset failed: \(error.localizedDescription)"
            }
        }
    }

    /// Mirrors the embedded WebRTC sender page's status line into the native UI so the
    /// hero badge and status chips reflect the real WebRTC connection state.
    func webRTCStatusChanged(_ text: String) {
        connectionState = text
        isStreaming = text.lowercased().contains("streaming to windows")
    }
}
