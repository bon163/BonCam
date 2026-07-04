import Foundation

enum CameraPosition: String, Codable {
    case front
    case back
}

enum StreamPreset: String, Codable {
    case hd720p30
    case hd1080p30

    var dimensions: (width: Int32, height: Int32) {
        switch self {
        case .hd720p30:
            return (1280, 720)
        case .hd1080p30:
            return (1920, 1080)
        }
    }

    var bitrate: Int {
        switch self {
        case .hd720p30:
            return 1_200_000
        case .hd1080p30:
            return 2_500_000
        }
    }

    var targetFPS: Int32 {
        switch self {
        case .hd720p30:
            return 10
        case .hd1080p30:
            return 10
        }
    }
}

enum VideoStreamKind: String, Codable {
    case h264 = "h264"
    case jpegPreview = "jpeg_preview"
}

enum StatusEventKind: String, Codable {
    case batteryLow = "battery_low"
    case networkPoor = "network_poor"
    case appBackgrounded = "app_backgrounded"
    case appForegrounded = "app_foregrounded"
    case phoneLocked = "phone_locked"
    case phoneUnlocked = "phone_unlocked"
    case thermalWarning = "thermal_warning"
}

struct SessionConfig: Codable {
    let cameraPosition: CameraPosition
    let preset: StreamPreset
    let fps: Int
    let bitrateTarget: Int
}

struct StreamInfo: Codable {
    let codec: String
    let width: Int
    let height: Int
    let fps: Int
    let orientationDegrees: Int
    let deviceName: String
}

struct EncodedFrame {
    let sessionID: UUID
    let streamKind: VideoStreamKind
    let frameID: UInt64
    let timestampUS: UInt64
    let isKeyframe: Bool
    let data: Data
}

struct VideoPacketHeader: Codable {
    let sessionID: UUID
    let streamKind: VideoStreamKind
    let frameID: UInt64
    let packetIndex: UInt16
    let packetCount: UInt16
    let timestampUS: UInt64
    let isKeyframe: Bool
}

enum ControlMessage: Codable {
    case pairCodeRequired(PairCodeRequired)
    case pairRequest(PairRequest)
    case pairConfirm(PairConfirm)
    case startStream(StartStream)
    case stopStream(StopStream)
    case switchCamera(SwitchCamera)
    case setPreset(SetPreset)
    case requestKeyframe(RequestKeyframe)
    case statusEvent(StatusEvent)
    case streamStarted(StreamStarted)

    enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    enum MessageType: String, Codable {
        case pairCodeRequired = "pair_code_required"
        case pairRequest = "pair_request"
        case pairConfirm = "pair_confirm"
        case startStream = "start_stream"
        case stopStream = "stop_stream"
        case switchCamera = "switch_camera"
        case setPreset = "set_preset"
        case requestKeyframe = "request_keyframe"
        case statusEvent = "status_event"
        case streamStarted = "stream_started"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .pairCodeRequired:
            self = .pairCodeRequired(try container.decode(PairCodeRequired.self, forKey: .payload))
        case .pairRequest:
            self = .pairRequest(try container.decode(PairRequest.self, forKey: .payload))
        case .pairConfirm:
            self = .pairConfirm(try container.decode(PairConfirm.self, forKey: .payload))
        case .startStream:
            self = .startStream(try container.decode(StartStream.self, forKey: .payload))
        case .stopStream:
            self = .stopStream(try container.decode(StopStream.self, forKey: .payload))
        case .switchCamera:
            self = .switchCamera(try container.decode(SwitchCamera.self, forKey: .payload))
        case .setPreset:
            self = .setPreset(try container.decode(SetPreset.self, forKey: .payload))
        case .requestKeyframe:
            self = .requestKeyframe(try container.decode(RequestKeyframe.self, forKey: .payload))
        case .statusEvent:
            self = .statusEvent(try container.decode(StatusEvent.self, forKey: .payload))
        case .streamStarted:
            self = .streamStarted(try container.decode(StreamStarted.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pairCodeRequired(let payload):
            try container.encode(MessageType.pairCodeRequired, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .pairRequest(let payload):
            try container.encode(MessageType.pairRequest, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .pairConfirm(let payload):
            try container.encode(MessageType.pairConfirm, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .startStream(let payload):
            try container.encode(MessageType.startStream, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .stopStream(let payload):
            try container.encode(MessageType.stopStream, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .switchCamera(let payload):
            try container.encode(MessageType.switchCamera, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setPreset(let payload):
            try container.encode(MessageType.setPreset, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .requestKeyframe(let payload):
            try container.encode(MessageType.requestKeyframe, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .statusEvent(let payload):
            try container.encode(MessageType.statusEvent, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .streamStarted(let payload):
            try container.encode(MessageType.streamStarted, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

struct PairCodeRequired: Codable { let protocolVersion: Int; let code: String }
struct PairRequest: Codable { let protocolVersion: Int; let deviceID: UUID; let deviceName: String; let pairCode: String }
struct PairConfirm: Codable { let protocolVersion: Int; let accepted: Bool; let reason: String?; let sessionID: UUID; let trustedDeviceID: UUID? }
struct StartStream: Codable { let protocolVersion: Int; let sessionID: UUID; let config: SessionConfig; let hostVideoPort: UInt16 }
struct StopStream: Codable { let protocolVersion: Int; let sessionID: UUID; let reason: String? }
struct SwitchCamera: Codable { let protocolVersion: Int; let sessionID: UUID; let cameraPosition: CameraPosition }
struct SetPreset: Codable { let protocolVersion: Int; let sessionID: UUID; let preset: StreamPreset }
struct RequestKeyframe: Codable { let protocolVersion: Int; let sessionID: UUID; let reason: String }
struct StatusEvent: Codable { let protocolVersion: Int; let sessionID: UUID; let kind: StatusEventKind; let detail: String? }
struct StreamStarted: Codable { let protocolVersion: Int; let sessionID: UUID; let info: StreamInfo }
