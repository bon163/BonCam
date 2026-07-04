use std::sync::Arc;

use serde::Serialize;

use crate::preview::PreviewSink;

#[derive(Serialize)]
pub struct VirtualCameraStatus {
    pub device_name: &'static str,
    pub registration_state: &'static str,
    pub frame_source_state: &'static str,
    pub latest_frame: Option<crate::preview::RawVideoFrameInfo>,
}

pub struct VirtualCameraManager {
    preview: Arc<PreviewSink>,
}

impl VirtualCameraManager {
    pub fn new(preview: Arc<PreviewSink>) -> Self {
        Self { preview }
    }

    pub async fn status(&self) -> VirtualCameraStatus {
        let latest_frame = self.preview.latest_raw_frame_info().await;
        VirtualCameraStatus {
            device_name: "iPhone Camera",
            registration_state: "managed_by_windows_virtual_camera_registrar",
            frame_source_state: if latest_frame.is_some() { "raw_frames_ready" } else { "waiting_for_raw_bridge" },
            latest_frame,
        }
    }
}
