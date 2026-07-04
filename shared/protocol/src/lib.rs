use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_CONTROL_PORT: u16 = 41_000;
pub const DEFAULT_VIDEO_PORT: u16 = 41_001;
pub const DEFAULT_PREVIEW_HTTP_PORT: u16 = 41_002;
pub const DEFAULT_WEBRTC_HTTP_PORT: u16 = 41_003;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum CameraPosition {
    Front,
    Back,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum StreamPreset {
    Hd720p30,
    Hd1080p30,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum CodecKind {
    H264,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum VideoStreamKind {
    H264,
    JpegPreview,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StatusEventKind {
    BatteryLow,
    NetworkPoor,
    AppBackgrounded,
    AppForegrounded,
    PhoneLocked,
    PhoneUnlocked,
    ThermalWarning,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamInfo {
    pub codec: CodecKind,
    pub width: u32,
    pub height: u32,
    pub fps: u16,
    pub orientation_degrees: u16,
    pub device_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionConfig {
    pub camera_position: CameraPosition,
    pub preset: StreamPreset,
    pub fps: u16,
    pub bitrate_target: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairRequest {
    pub protocol_version: u16,
    pub device_id: Uuid,
    pub device_name: String,
    pub pair_code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairConfirm {
    pub protocol_version: u16,
    pub accepted: bool,
    pub reason: Option<String>,
    pub session_id: Uuid,
    pub trusted_device_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StartStream {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub config: SessionConfig,
    pub host_video_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StopStream {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SwitchCamera {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub camera_position: CameraPosition,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetPreset {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub preset: StreamPreset,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestKeyframe {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusEvent {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub kind: StatusEventKind,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairCodeRequired {
    pub protocol_version: u16,
    pub code: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StreamStarted {
    pub protocol_version: u16,
    pub session_id: Uuid,
    pub info: StreamInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum ControlMessage {
    PairCodeRequired(PairCodeRequired),
    PairRequest(PairRequest),
    PairConfirm(PairConfirm),
    StartStream(StartStream),
    StopStream(StopStream),
    SwitchCamera(SwitchCamera),
    SetPreset(SetPreset),
    RequestKeyframe(RequestKeyframe),
    StatusEvent(StatusEvent),
    StreamStarted(StreamStarted),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VideoPacketHeader {
    pub session_id: Uuid,
    pub stream_kind: VideoStreamKind,
    pub frame_id: u64,
    pub packet_index: u16,
    pub packet_count: u16,
    pub timestamp_us: u64,
    pub is_keyframe: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostStatus {
    pub discovered_phones: Vec<String>,
    pub paired_phones: Vec<String>,
    pub active_session: Option<Uuid>,
    pub preview_state: String,
    pub virtual_camera_state: String,
}
