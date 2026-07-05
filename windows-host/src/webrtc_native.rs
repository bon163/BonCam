//! Native, in-process WebRTC receiver.
//!
//! Historically the host only did signaling: it handed the phone's offer to a
//! browser page (/receiver) that answered, decoded the video track, and posted
//! RGBA frames back over HTTP. That browser was the source of five recurring
//! field failures — nobody clicking "Start bridge", Edge suspending background
//! tabs, the renderer being OOM-killed near frame ~2000 from getImageData GC
//! churn, stale zombie tabs hijacking the answer, and pc-disconnected churn.
//!
//! This module removes the browser entirely: the host is itself the answering
//! WebRTC peer. It consumes the offer with the `webrtc` crate, answers it,
//! trickles ICE, receives the H264 RTP track, decodes it in-process, and writes
//! straight into the shared `PreviewSink` (latest.rgba). The phone client is
//! unchanged — from its side the host still just publishes an answer at
//! GET /signal/answer and candidates at GET /signal/candidates/receiver.

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use bytes::Bytes;
use openh264::{decoder::Decoder, formats::YUVSource};
use serde_json::Value;
use tokio::{runtime::Handle, sync::Mutex};
use tracing::{info, warn};
use webrtc::{
    api::{interceptor_registry::register_default_interceptors, media_engine::MediaEngine, APIBuilder, API},
    ice_transport::{ice_candidate::RTCIceCandidateInit, ice_connection_state::RTCIceConnectionState},
    interceptor::registry::Registry,
    peer_connection::{
        configuration::RTCConfiguration, peer_connection_state::RTCPeerConnectionState,
        sdp::session_description::RTCSessionDescription, RTCPeerConnection,
    },
    rtp::{codecs::h264::H264Packet, packetizer::Depacketizer},
    track::track_remote::TrackRemote,
};

use crate::preview::PreviewSink;

/// The receiver id the host advertises to the phone. The phone client is answer-
/// arbitration agnostic (it just reads the winning answer), but the host-side
/// signaling code tags the answer with an id so the existing /signal/answer/ack
/// plumbing keeps working. A stable literal makes host answers obvious in logs.
pub const HOST_RECEIVER_ID: &str = "host-native";

pub struct NativeWebRtcReceiver {
    api: API,
    preview: Arc<PreviewSink>,
    // Held behind an Arc so the on_ice_candidate closure (which outlives this
    // borrow and is owned by the peer connection) can capture a clone.
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    /// The active answering peer connection, if a session is up.
    pc: Option<Arc<RTCPeerConnection>>,
    /// Local ICE candidates gathered for the current session, already shaped as
    /// the plain `{ candidate, sdpMid, ... }` objects the phone's addIceCandidate
    /// consumes. The phone polls these repeatedly and dedups, so we keep the full
    /// list for the life of the session.
    host_candidates: Vec<Value>,
    /// Phone candidates that arrived before the peer connection existed (the phone
    /// trickles candidates as separate POSTs that can race ahead of the offer).
    pending_phone: Vec<RTCIceCandidateInit>,
}

impl NativeWebRtcReceiver {
    pub fn new(preview: Arc<PreviewSink>) -> Result<Self> {
        let mut media_engine = MediaEngine::default();
        media_engine.register_default_codecs().context("register default codecs")?;
        let mut registry = Registry::new();
        registry = register_default_interceptors(registry, &mut media_engine).context("register interceptors")?;
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .build();
        Ok(Self { api, preview, inner: Arc::new(Mutex::new(Inner::default())) })
    }

    /// Tear down any active session. Called when the phone POSTs /signal/reset
    /// (a new session is starting) so a stale peer connection can't linger.
    pub async fn reset(&self) {
        let mut inner = self.inner.lock().await;
        if let Some(pc) = inner.pc.take() {
            info!("native webrtc: closing previous peer connection on reset");
            let _ = pc.close().await;
        }
        inner.host_candidates.clear();
        inner.pending_phone.clear();
    }

    /// Accept the phone's offer, build the answering peer connection, and return
    /// the answer SDP as a `{ type, sdp }` JSON value for the signaling layer to
    /// publish at GET /signal/answer.
    pub async fn accept_offer(&self, offer: &Value) -> Result<Value> {
        let sdp = offer
            .get("sdp")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("offer has no sdp string"))?
            .to_string();

        // Fresh session: drop any prior pc and buffered state.
        self.reset().await;

        let pc = Arc::new(self.api.new_peer_connection(RTCConfiguration::default()).await.context("new peer connection")?);

        // Local ICE candidates: stash them (shaped as the phone expects) so the
        // /signal/candidates/receiver poller can hand them to the phone.
        let inner_for_ice = self.inner.clone();
        pc.on_ice_candidate(Box::new(move |candidate| {
            let inner_for_ice = inner_for_ice.clone();
            Box::pin(async move {
                let Some(candidate) = candidate else { return };
                match candidate.to_json() {
                    Ok(init) => match serde_json::to_value(&init) {
                        Ok(value) => inner_for_ice.lock().await.host_candidates.push(value),
                        Err(err) => warn!("native webrtc: serialize local candidate failed: {err}"),
                    },
                    Err(err) => warn!("native webrtc: to_json local candidate failed: {err}"),
                }
            })
        }));

        pc.on_peer_connection_state_change(Box::new(move |state: RTCPeerConnectionState| {
            info!("native webrtc: peer connection state {state}");
            Box::pin(async {})
        }));

        pc.on_ice_connection_state_change(Box::new(move |state: RTCIceConnectionState| {
            info!("native webrtc: ice connection state {state}");
            Box::pin(async {})
        }));

        // The remote video track: decode it in-process and feed the preview sink.
        let preview = self.preview.clone();
        let handle = Handle::current();
        pc.on_track(Box::new(move |track, _receiver, _transceiver| {
            let preview = preview.clone();
            let handle = handle.clone();
            Box::pin(async move {
                let mime = track.codec().capability.mime_type;
                info!("native webrtc: remote track added ({mime})");
                tokio::spawn(pump_track(track, preview, handle));
            })
        }));

        // Apply the offer, answer it, and publish the answer via local_description.
        // We trickle ICE separately, so we do NOT wait for gathering to complete.
        let remote = RTCSessionDescription::offer(sdp).context("build offer description")?;
        pc.set_remote_description(remote).await.context("set remote description")?;

        let answer = pc.create_answer(None).await.context("create answer")?;
        pc.set_local_description(answer).await.context("set local description")?;

        let local = pc
            .local_description()
            .await
            .ok_or_else(|| anyhow!("no local description after set_local_description"))?;
        let answer_value = serde_json::to_value(&local).context("serialize answer")?;

        // Feed any phone candidates that arrived before the pc existed, then keep
        // the pc for later trickled candidates.
        {
            let mut inner = self.inner.lock().await;
            let pending = std::mem::take(&mut inner.pending_phone);
            for candidate in pending {
                if let Err(err) = pc.add_ice_candidate(candidate).await {
                    warn!("native webrtc: add buffered phone candidate failed: {err}");
                }
            }
            inner.pc = Some(pc);
        }

        info!("native webrtc: answered phone offer as {HOST_RECEIVER_ID}");
        Ok(answer_value)
    }

    /// Feed a phone ICE candidate into the active peer connection, buffering it if
    /// the offer/answer hasn't been processed yet.
    pub async fn add_phone_candidate(&self, candidate: &Value) {
        let init: RTCIceCandidateInit = match serde_json::from_value(candidate.clone()) {
            Ok(init) => init,
            Err(err) => {
                warn!("native webrtc: ignoring malformed phone candidate: {err}");
                return;
            }
        };
        let mut inner = self.inner.lock().await;
        match inner.pc.clone() {
            Some(pc) => {
                drop(inner);
                if let Err(err) = pc.add_ice_candidate(init).await {
                    warn!("native webrtc: add phone candidate failed: {err}");
                }
            }
            None => inner.pending_phone.push(init),
        }
    }

    /// The local ICE candidates gathered so far, for GET /signal/candidates/receiver.
    pub async fn host_candidates(&self) -> Vec<Value> {
        self.inner.lock().await.host_candidates.clone()
    }

    /// Whether a native session is currently answering. Lets the signaling layer
    /// prefer native candidates over the legacy browser-receiver ones.
    pub async fn is_active(&self) -> bool {
        self.inner.lock().await.pc.is_some()
    }
}

/// Read an H264 RTP track, reassemble access units, and hand each to a decode
/// thread. read_rtp is async and the openh264 Decoder is not Send-friendly across
/// awaits, so decoding runs on a dedicated std thread (mirrors preview.rs).
async fn pump_track(track: Arc<TrackRemote>, preview: Arc<PreviewSink>, handle: Handle) {
    let mime = track.codec().capability.mime_type.to_ascii_lowercase();
    if !mime.contains("h264") {
        warn!("native webrtc: unsupported track codec {mime}; only H264 is decoded");
        return;
    }

    let (tx, rx) = std::sync::mpsc::channel::<Vec<u8>>();
    // Gauge of access units sitting in the channel. If the decode side falls
    // behind a live 30fps source, latency grows silently — this makes it visible
    // in the periodic stats line instead.
    let backlog = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let backlog_rx = backlog.clone();
    std::thread::spawn(move || decode_loop(rx, backlog_rx, preview, handle));

    let mut depacketizer = H264Packet::default();
    let mut access_unit: Vec<u8> = Vec::new();
    loop {
        let packet = match track.read_rtp().await {
            Ok((packet, _)) => packet,
            Err(err) => {
                info!("native webrtc: track read ended: {err}");
                break;
            }
        };
        if packet.payload.is_empty() {
            continue;
        }
        match depacketizer.depacketize(&packet.payload) {
            // FU-A fragments return empty until the final fragment completes the NAL.
            Ok(nal) if !nal.is_empty() => access_unit.extend_from_slice(&nal),
            Ok(_) => {}
            Err(err) => warn!("native webrtc: depacketize failed: {err}"),
        }
        // The marker bit terminates an access unit (SPS/PPS/IDR or a P-frame).
        if packet.header.marker && !access_unit.is_empty() {
            backlog.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            if tx.send(std::mem::take(&mut access_unit)).is_err() {
                info!("native webrtc: decode thread gone, stopping track pump");
                break;
            }
        }
    }
}

/// Owns the openh264 decoder, converts decoded frames to RGBA, and writes them to
/// the shared preview sink (which persists latest.rgba for the virtual camera).
///
/// LATENCY-CRITICAL: this is a live source, so the loop must be latest-wins. The
/// conversion + 3.7MB latest.rgba write can be slower than the 30fps arrival rate
/// (the old browser bridge self-paced with its inFlight guard; a naive decode
/// loop here instead queued every frame and drifted 30-60s behind, seen live
/// 2026-07-05). Every access unit still has to be DECODED — H264 P-frames need
/// the reference chain — but only the newest decoded picture is converted and
/// written; older ones are stale the moment a newer one exists.
fn decode_loop(
    rx: std::sync::mpsc::Receiver<Vec<u8>>,
    backlog: Arc<std::sync::atomic::AtomicUsize>,
    preview: Arc<PreviewSink>,
    handle: Handle,
) {
    use std::sync::{atomic::Ordering, mpsc::TryRecvError};
    use std::time::{Duration, Instant};

    let mut decoder = match Decoder::new() {
        Ok(decoder) => decoder,
        Err(err) => {
            warn!("native webrtc: failed to create H264 decoder: {err}");
            return;
        }
    };
    let mut rgba: Vec<u8> = Vec::new();
    let mut last_error_log = Instant::now() - Duration::from_secs(5);
    let mut decoded_count = 0_u64;
    let mut written_count = 0_u64;
    let mut skipped_count = 0_u64;
    let mut last_stats_log = Instant::now();

    'session: loop {
        let mut access_unit = match rx.recv() {
            Ok(access_unit) => access_unit,
            Err(_) => break,
        };
        loop {
            backlog.fetch_sub(1, Ordering::Relaxed);
            // Peek ahead BEFORE the expensive work: if more AUs are already queued,
            // this one only needs to feed the decoder's reference chain — skip the
            // RGBA conversion and file write and catch up instead.
            let next = rx.try_recv();
            let is_newest = next.is_err();
            match decoder.decode(&access_unit) {
                Ok(Some(decoded)) => {
                    decoded_count += 1;
                    let (width, height) = decoded.dimensions();
                    if is_newest && width != 0 && height != 0 {
                        rgba.resize(width * height * 4, 0);
                        decoded.write_rgba8(&mut rgba);
                        let frame = Bytes::copy_from_slice(&rgba);
                        // submit_raw_rgba_frame is async (writes latest.rgba +
                        // updates state); this thread is outside the runtime, so
                        // block on the shared handle.
                        handle.block_on(preview.submit_raw_rgba_frame(width as u32, height as u32, (width * 4) as u32, frame));
                        written_count += 1;
                    } else if !is_newest {
                        skipped_count += 1;
                    }
                }
                Ok(None) => {}
                Err(err) => {
                    if last_error_log.elapsed() >= Duration::from_millis(500) {
                        warn!("native webrtc: h264 decode error: {err}");
                        last_error_log = Instant::now();
                    }
                }
            }
            if last_stats_log.elapsed() >= Duration::from_secs(10) {
                // A persistently growing backlog with skips already happening means
                // DECODE itself can't keep up (not just the write) — that would need
                // a stronger fix (drop to next IDR + PLI request).
                info!(
                    "native webrtc: decode stats: decoded {decoded_count}, written {written_count}, skipped {skipped_count} stale, backlog {}",
                    backlog.load(Ordering::Relaxed)
                );
                last_stats_log = Instant::now();
            }
            match next {
                Ok(newer) => access_unit = newer,
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break 'session,
            }
        }
    }
    info!("native webrtc: decode thread exiting");
}
