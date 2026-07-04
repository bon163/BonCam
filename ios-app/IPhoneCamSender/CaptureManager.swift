import AVFoundation
import Foundation

protocol CaptureManagerDelegate: AnyObject {
    func captureManager(_ manager: CaptureManager, didEncode frame: EncodedFrame)
}

final class CaptureManager: NSObject {
    let session = AVCaptureSession()
    weak var delegate: CaptureManagerDelegate?

    private let queue = DispatchQueue(label: "capture.manager.queue")
    private let output = AVCaptureVideoDataOutput()
    private var encoder: VideoEncoder?
    private var previewEncoder: PreviewImageEncoder?
    private var activePreset: StreamPreset = .hd720p30
    private var position: CameraPosition = .back
    private var sessionID = UUID()
    private var frameID: UInt64 = 0
    private var previewFrameID: UInt64 = 0

    func configure(position: CameraPosition, preset: StreamPreset) async throws {
        self.position = position
        self.activePreset = preset

        let granted = await requestCameraAccess()
        if !granted {
            throw NSError(domain: "CaptureManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"])
        }

        session.beginConfiguration()
        session.sessionPreset = preset == .hd720p30 ? .hd1280x720 : .hd1920x1080
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let device = try cameraDevice(for: position)
        try configureFrameRate(for: device, fps: preset.targetFPS)
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        let dimensions = preset.dimensions
        encoder = VideoEncoder(width: dimensions.width, height: dimensions.height, bitrate: preset.bitrate, fps: preset.targetFPS)
        encoder?.delegate = self
        previewEncoder = PreviewImageEncoder()
        previewEncoder?.delegate = self
        session.commitConfiguration()
        session.startRunning()
    }

    func startStreaming(sessionID: UUID) async throws {
        if !session.isRunning {
            session.startRunning()
        }
        self.sessionID = sessionID
        frameID = 0
        previewFrameID = 0
    }

    func stop() {
        session.stopRunning()
    }

    func switchCamera(to position: CameraPosition) async throws {
        try await configure(position: position, preset: activePreset)
    }

    func applyPreset(_ preset: StreamPreset) async throws {
        try await configure(position: position, preset: preset)
    }

    private func cameraDevice(for position: CameraPosition) throws -> AVCaptureDevice {
        let avPosition: AVCaptureDevice.Position = position == .back ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            throw NSError(domain: "CaptureManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Camera not available"])
        }
        return device
    }

    private func configureFrameRate(for device: AVCaptureDevice, fps: Int32) throws {
        let frameDuration = CMTime(value: 1, timescale: fps)
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
    }

    private func requestCameraAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension CaptureManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        encoder?.encode(sampleBuffer: sampleBuffer)
        previewEncoder?.maybeEncode(sampleBuffer: sampleBuffer)
    }
}

extension CaptureManager: VideoEncoderDelegate {
    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, isKeyframe: Bool, timestampUS: UInt64) {
        frameID += 1
        delegate?.captureManager(self, didEncode: EncodedFrame(
            sessionID: sessionID,
            streamKind: .h264,
            frameID: frameID,
            timestampUS: timestampUS,
            isKeyframe: isKeyframe,
            data: data
        ))
    }
}

extension CaptureManager: PreviewImageEncoderDelegate {
    func previewImageEncoder(_ encoder: PreviewImageEncoder, didEncode data: Data, timestampUS: UInt64) {
        previewFrameID += 1
        delegate?.captureManager(self, didEncode: EncodedFrame(
            sessionID: sessionID,
            streamKind: .jpegPreview,
            frameID: previewFrameID,
            timestampUS: timestampUS,
            isKeyframe: true,
            data: data
        ))
    }
}
