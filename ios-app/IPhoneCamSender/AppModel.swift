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
    // 60fps is opt-in (default 30). At a fixed bitrate 60fps halves the bits per
    // frame, so it trades sharpness for smoothness; keep it a deliberate choice.
    @Published var highFrameRate: Bool = false {
        didSet {
            UserDefaults.standard.set(highFrameRate, forKey: Self.highFrameRateDefaultsKey)
        }
    }
    @Published var isStreaming = false

    let captureManager = CaptureManager()
    private static let hostAddressDefaultsKey = "hostAddress"
    private static let highFrameRateDefaultsKey = "highFrameRate"

    /// The frame rate the WebRTC sender should target. 30 by default, 60 when the
    /// user enables high frame rate in Settings.
    var targetFps: Int { highFrameRate ? 60 : 30 }

    init() {
        hostAddress = UserDefaults.standard.string(forKey: Self.hostAddressDefaultsKey) ?? hostAddress
        // UserDefaults.bool returns false (i.e. 30fps) when the key was never set.
        highFrameRate = UserDefaults.standard.bool(forKey: Self.highFrameRateDefaultsKey)
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
    func applyWebRTCConfig(facing: String, quality: Int, fps: Int) {
        cameraPosition = facing == "user" ? .front : .back
        selectedPreset = quality == 1080 ? .hd1080p30 : .hd720p30
        highFrameRate = fps >= 60
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
