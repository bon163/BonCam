use std::{
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::Result;
use protocol::{DEFAULT_PREVIEW_HTTP_PORT, DEFAULT_VIDEO_PORT, DEFAULT_WEBRTC_HTTP_PORT};
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::{
    control::ControlServer,
    pairing::PairingStore,
    preview::PreviewSink,
    preview_http::PreviewHttpServer,
    video::VideoReceiver,
    webrtc_http::WebRtcHttpServer,
};

pub struct HostApp;

impl HostApp {
    pub async fn run(&self) -> Result<()> {
        let pairing = Arc::new(Mutex::new(PairingStore::load_or_default("paired-devices.json").await?));
        let preview = Arc::new(PreviewSink::new());

        let control = ControlServer::new(pairing.clone(), preview.clone());
        let video = VideoReceiver::new(preview.clone());
        let preview_http = PreviewHttpServer::new(preview.clone());
        let webrtc_http = WebRtcHttpServer::new(preview.clone());

        info!("windows host listening on tcp 41000, tcp {}, and WebRTC http {}", DEFAULT_VIDEO_PORT, DEFAULT_WEBRTC_HTTP_PORT);
        tokio::spawn(watch_raw_frames(preview.clone()));
        tokio::try_join!(
            control.run(SocketAddr::from(([0, 0, 0, 0], 41_000))),
            video.run(SocketAddr::from(([0, 0, 0, 0], DEFAULT_VIDEO_PORT))),
            preview_http.run(SocketAddr::from(([127, 0, 0, 1], DEFAULT_PREVIEW_HTTP_PORT))),
            webrtc_http.run(SocketAddr::from(([0, 0, 0, 0], DEFAULT_WEBRTC_HTTP_PORT)))
        )?;

        Ok(())
    }
}

// Black-box recorder for the two failure modes seen in the field: the stream
// dying while the host lives (WARN with an exact timestamp the moment bridge
// frames stop) and the host process dying silently (the minute-cadence
// heartbeat bounds the time of death in host.log).
async fn watch_raw_frames(preview: Arc<PreviewSink>) {
    const STALL_AFTER: Duration = Duration::from_secs(3);
    const HEARTBEAT_EVERY: Duration = Duration::from_secs(60);

    let mut last_seq = preview.raw_frame_version();
    let mut last_change = Instant::now();
    let mut flowing = false;
    let mut last_heartbeat = Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let seq = preview.raw_frame_version();
        if seq != last_seq {
            if !flowing {
                info!("raw bridge frames FLOWING (seq {seq})");
                flowing = true;
            }
            last_seq = seq;
            last_change = Instant::now();
        } else if flowing && last_change.elapsed() >= STALL_AFTER {
            let poll = match crate::webrtc_http::last_receiver_poll_age_secs() {
                Some(age) => format!("receiver last signaling poll {age}s ago (>5s = tab dead/suspended, fresh = bridge stalled in a live tab)"),
                None => "receiver never polled".to_string(),
            };
            warn!(
                "raw bridge frames STOPPED (last seq {seq}, {}s ago) — {poll}",
                last_change.elapsed().as_secs()
            );
            flowing = false;
        }
        if last_heartbeat.elapsed() >= HEARTBEAT_EVERY {
            let poll = match crate::webrtc_http::last_receiver_poll_age_secs() {
                Some(age) => format!("{age}s"),
                None => "never".to_string(),
            };
            info!("heartbeat: raw frame seq {seq}, flowing={flowing}, receiver poll age {poll}");
            last_heartbeat = Instant::now();
        }
    }
}
