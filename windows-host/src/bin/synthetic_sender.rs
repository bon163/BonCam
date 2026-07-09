//! Synthetic iPhone sender — a phone-free test client for the host's native
//! WebRTC receiver.
//!
//! The only ways to drive the receive pipeline used to be a physical iPhone or a
//! browser with `--use-fake-device-for-media-stream` (which still needs a GUI and
//! manual clicking). Neither is CI-able, so nearly every entry in HANDOFF.md is
//! "COMPILES but NOT verified live". This binary removes that gap: it is a real
//! WebRTC peer that speaks the exact same `/signal/*` protocol the iOS app and the
//! /phone page speak, offers an H264 video track carrying a synthetic animated
//! test pattern, and answers the host's RTCP PLI by forcing a keyframe — so the
//! whole phone->host->latest.rgba path can be exercised from the command line with
//! no phone and no browser.
//!
//! Run the host (`cargo run -p windows-host`), then in another shell:
//!   cargo run -p windows-host --bin synthetic_sender
//! Options: --host 127.0.0.1 --port 41003 --width 1280 --height 720 --fps 30
//!          --seconds 0 (0 = run until Ctrl+C) --bitrate 4000000
//!
//! Frame rate is bounded by software openh264 ENCODE, not by this code: on a
//! typical machine 1280x720 sustains ~13fps, while 640x360 hits the full 30fps
//! (`--width 640 --height 360`). Build with `--release` for the encoder to run at
//! full speed. 720p at ~13fps is fine for connectivity/PLI/soak checks; use 360p
//! when you specifically need to stress the host's 30fps latest-wins decode path.
//!
//! Verify success in host.log: `answered phone offer as host-native` ->
//! `peer connection state connected` -> `remote track added (video/H264)` ->
//! `decode stats:` with written climbing. `latest.rgba` LastWriteTime should
//! advance and /virtual-camera/status should report raw_frames_ready. Force a
//! `requested keyframe (PLI)` by watching the sender log echo "received PLI".

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bytes::Bytes;
use openh264::encoder::{BitRate, Encoder, EncoderConfig, FrameRate};
use openh264::formats::YUVSlices;
use openh264::Timestamp as EncTimestamp;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{info, warn};
use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::{MediaEngine, MIME_TYPE_H264};
use webrtc::api::APIBuilder;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::interceptor::registry::Registry;
use webrtc::media::Sample;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;
use webrtc::track::track_local::TrackLocal;

struct Args {
    host: String,
    port: u16,
    width: usize,
    height: usize,
    fps: u32,
    seconds: u64,
    bitrate: u32,
}

impl Default for Args {
    fn default() -> Self {
        Self { host: "127.0.0.1".into(), port: 41003, width: 1280, height: 720, fps: 30, seconds: 0, bitrate: 4_000_000 }
    }
}

fn parse_args() -> Result<Args> {
    let mut args = Args::default();
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().ok_or_else(|| anyhow!("{flag} needs a value"));
        match flag.as_str() {
            "--host" => args.host = value()?,
            "--port" => args.port = value()?.parse().context("--port")?,
            "--width" => args.width = value()?.parse().context("--width")?,
            "--height" => args.height = value()?.parse().context("--height")?,
            "--fps" => args.fps = value()?.parse().context("--fps")?,
            "--seconds" => args.seconds = value()?.parse().context("--seconds")?,
            "--bitrate" => args.bitrate = value()?.parse().context("--bitrate")?,
            "-h" | "--help" => {
                println!("synthetic_sender [--host H] [--port P] [--width W] [--height H] [--fps N] [--seconds S] [--bitrate BPS]");
                std::process::exit(0);
            }
            other => bail!("unknown argument {other}"),
        }
    }
    // openh264 requires even dimensions (4:2:0 chroma).
    if args.width % 2 != 0 || args.height % 2 != 0 {
        bail!("width and height must be even");
    }
    Ok(args)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into())).init();
    let args = parse_args()?;
    let base = format!("{}:{}", args.host, args.port);
    info!("synthetic sender -> http://{base} ({}x{} @ {}fps, {} bps)", args.width, args.height, args.fps, args.bitrate);

    // Build the offering peer connection exactly like the /phone page: default
    // codecs + interceptors (so H264 is negotiated against the receiver's default
    // MediaEngine) and no ICE servers (host-only candidates, LAN/loopback).
    let mut media_engine = MediaEngine::default();
    media_engine.register_default_codecs().context("register default codecs")?;
    let mut registry = Registry::new();
    registry = register_default_interceptors(registry, &mut media_engine).context("register interceptors")?;
    let api = APIBuilder::new().with_media_engine(media_engine).with_interceptor_registry(registry).build();
    let pc = Arc::new(api.new_peer_connection(RTCConfiguration::default()).await.context("new peer connection")?);

    let track = Arc::new(TrackLocalStaticSample::new(
        RTCRtpCodecCapability {
            mime_type: MIME_TYPE_H264.to_owned(),
            clock_rate: 90000,
            channels: 0,
            sdp_fmtp_line: "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f".to_owned(),
            rtcp_feedback: vec![],
        },
        "video".to_owned(),
        "synthetic-iphone".to_owned(),
    ));
    let rtp_sender = pc.add_track(Arc::clone(&track) as Arc<dyn TrackLocal + Send + Sync>).await.context("add_track")?;

    // The host requests a fresh keyframe via RTCP PLI whenever its decoder loses
    // the reference chain (mirrors the real iOS behaviour we need to test). Read
    // RTCP off the sender and force an IDR in response.
    let force_idr = Arc::new(AtomicBool::new(false));
    let force_idr_rtcp = force_idr.clone();
    tokio::spawn(async move {
        while let Ok((packets, _)) = rtp_sender.read_rtcp().await {
            for packet in packets {
                if packet.as_any().downcast_ref::<PictureLossIndication>().is_some() {
                    force_idr_rtcp.store(true, Ordering::Relaxed);
                    info!("received PLI from host -> forcing keyframe");
                }
            }
        }
    });

    pc.on_peer_connection_state_change(Box::new(move |state: RTCPeerConnectionState| {
        info!("peer connection state {state}");
        Box::pin(async {})
    }));

    // Trickle our local ICE candidates to the host, shaped exactly as the phone's
    // event.candidate.toJSON() (the host deserializes into RTCIceCandidateInit).
    let base_ice = base.clone();
    pc.on_ice_candidate(Box::new(move |candidate| {
        let base_ice = base_ice.clone();
        Box::pin(async move {
            let Some(candidate) = candidate else { return };
            let value = match candidate.to_json() {
                Ok(init) => match serde_json::to_value(&init) {
                    Ok(value) => value,
                    Err(err) => return warn!("serialize local candidate failed: {err}"),
                },
                Err(err) => return warn!("to_json local candidate failed: {err}"),
            };
            if let Err(err) = http_json(&base_ice, "POST", "/signal/candidate/phone", Some(&value)).await {
                warn!("post phone candidate failed: {err:#}");
            }
        })
    }));

    // Signaling handshake, mirroring the /phone page order.
    http_json(&base, "POST", "/signal/reset", Some(&json!({}))).await.context("signal reset")?;

    let offer = pc.create_offer(None).await.context("create offer")?;
    pc.set_local_description(offer).await.context("set local description")?;
    let local = pc.local_description().await.ok_or_else(|| anyhow!("no local description"))?;
    http_json(&base, "POST", "/signal/offer", Some(&serde_json::to_value(&local)?)).await.context("post offer")?;
    info!("offer sent, waiting for host answer...");

    // Poll for the host's answer (published at GET /signal/answer as {type,sdp,id}).
    let answer = loop {
        if let Some(value) = http_json(&base, "GET", "/signal/answer", None).await? {
            if value.get("type").and_then(Value::as_str) == Some("answer") {
                if let Some(sdp) = value.get("sdp").and_then(Value::as_str) {
                    break sdp.to_string();
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    pc.set_remote_description(RTCSessionDescription::answer(answer).context("build answer")?).await.context("set remote description")?;
    info!("answer applied; connecting...");

    // Poll the host's ICE candidates and feed them in (dedup by string).
    let pc_cand = Arc::clone(&pc);
    let base_cand = base.clone();
    tokio::spawn(async move {
        let mut seen = std::collections::HashSet::new();
        loop {
            match http_json(&base_cand, "GET", "/signal/candidates/receiver", None).await {
                Ok(Some(payload)) => {
                    if let Some(list) = payload.get("candidates").and_then(Value::as_array) {
                        for candidate in list {
                            let key = candidate.to_string();
                            if !seen.insert(key) {
                                continue;
                            }
                            match serde_json::from_value::<RTCIceCandidateInit>(candidate.clone()) {
                                Ok(init) => {
                                    if let Err(err) = pc_cand.add_ice_candidate(init).await {
                                        warn!("add host candidate failed: {err}");
                                    }
                                }
                                Err(err) => warn!("malformed host candidate: {err}"),
                            }
                        }
                    }
                }
                Ok(None) => {}
                Err(err) => warn!("poll host candidates failed: {err:#}"),
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    });

    // Encode + send the synthetic stream. openh264 Encoder is Send, so it can live
    // across the write_sample await in this task.
    let config = EncoderConfig::new().bitrate(BitRate::from_bps(args.bitrate)).max_frame_rate(FrameRate::from_hz(args.fps as f32));
    let mut encoder = Encoder::with_api_config(openh264::OpenH264API::from_source(), config).context("create H264 encoder")?;
    let frame_dur = Duration::from_secs_f64(1.0 / args.fps as f64);
    let mut interval = tokio::time::interval(frame_dur);
    // I420 planes, generated directly (a real phone sends YUV). Feeding the encoder
    // YUV avoids the pure-Rust RGB->YUV conversion that dominated frame time and
    // capped the tool well under 30fps. Reused across frames — zero per-frame alloc.
    let (chroma_w, chroma_h) = (args.width / 2, args.height / 2);
    let mut y_plane = vec![0u8; args.width * args.height];
    let mut u_plane = vec![128u8; chroma_w * chroma_h];
    let mut v_plane = vec![128u8; chroma_w * chroma_h];
    let mut frame_index: u64 = 0;
    let deadline = (args.seconds > 0).then(|| tokio::time::Instant::now() + Duration::from_secs(args.seconds));

    info!("streaming synthetic frames (Ctrl+C to stop)");
    loop {
        tokio::select! {
            _ = interval.tick() => {}
            _ = tokio::signal::ctrl_c() => { info!("Ctrl+C, stopping"); break; }
        }
        if let Some(deadline) = deadline {
            if tokio::time::Instant::now() >= deadline {
                info!("reached --seconds limit, stopping");
                break;
            }
        }

        draw_test_pattern(&mut y_plane, &mut u_plane, &mut v_plane, args.width, args.height, frame_index, args.fps);
        if force_idr.swap(false, Ordering::Relaxed) {
            encoder.force_intra_frame();
        }
        let yuv = YUVSlices::new((&y_plane, &u_plane, &v_plane), (args.width, args.height), (args.width, chroma_w, chroma_w));
        let timestamp = EncTimestamp::from_millis(frame_index * 1000 / args.fps as u64);
        let encoded = encoder.encode_at(&yuv, timestamp).context("encode frame")?;
        let payload = encoded.to_vec();
        if !payload.is_empty() {
            let sample = Sample { data: Bytes::from(payload), duration: frame_dur, ..Default::default() };
            if let Err(err) = track.write_sample(&sample).await {
                warn!("write_sample failed: {err}");
            }
        }

        frame_index += 1;
        if frame_index % (args.fps as u64 * 5) == 0 {
            info!("sent {frame_index} frames ({}s)", frame_index / args.fps as u64);
        }
    }

    pc.close().await.ok();
    info!("closed peer connection after {frame_index} frames");
    Ok(())
}

/// Fill I420 planes with an animated, visually unambiguous test pattern: a
/// scrolling diagonal luma gradient, a bright moving vertical marker bar, a bottom
/// progress bar that advances one screen width every ~10s, and a slowly drifting
/// chroma wash so the color path is exercised too. Any of these frozen or torn in
/// a consuming app immediately shows where the pipeline stalled. Working in YUV
/// (what a phone actually sends) skips the costly RGB->YUV conversion.
fn draw_test_pattern(y_plane: &mut [u8], u_plane: &mut [u8], v_plane: &mut [u8], width: usize, height: usize, frame: u64, fps: u32) {
    let t = frame as usize;
    let bar_x = (t * 8) % width; // scrolls ~8px/frame
    let (bar_lo, bar_hi) = (bar_x.saturating_sub(4), (bar_x + 4).min(width));
    let progress = ((frame % (fps as u64 * 10)) as usize * width) / (fps as usize * 10);
    let bar_top = height.saturating_sub(20);
    // Luma: a diagonal ramp is just a per-row start value plus a wrapping counter,
    // so the inner loop has no per-pixel multiply/modulo. Fast even in an
    // unoptimized debug build (the binary crate isn't opt-2 like the deps).
    for y in 0..height {
        let bar_row = y >= bar_top;
        let mut luma = (y as u8).wrapping_add(t as u8); // (x=0) + y + t
        let row = &mut y_plane[y * width..(y + 1) * width];
        for (x, px) in row.iter_mut().enumerate() {
            *px = if x >= bar_lo && x < bar_hi {
                235 // white marker bar
            } else if bar_row {
                if x < progress {
                    200
                } else {
                    40
                }
            } else {
                luma
            };
            luma = luma.wrapping_add(1);
        }
    }
    // Chroma (quarter-res): a gentle drifting wash — enough to verify color, cheap
    // to compute. Neutral 128 == gray; offsets push toward blue/red over time.
    let chroma_w = width / 2;
    let chroma_h = height / 2;
    let u_base = 128u8.wrapping_add((t / 2) as u8);
    let v_base = 128u8.wrapping_add((t / 3) as u8);
    for cy in 0..chroma_h {
        let off = cy * chroma_w;
        let u_row = u_base.wrapping_add(cy as u8);
        let v_row = v_base.wrapping_sub(cy as u8);
        for cx in 0..chroma_w {
            u_plane[off + cx] = u_row.wrapping_add(cx as u8);
            v_plane[off + cx] = v_row;
        }
    }
}

/// Minimal one-shot HTTP/1.1 JSON client over a fresh `Connection: close` socket.
/// Returns the parsed JSON body, or `None` for a 204/empty body. A test tool
/// talking to localhost doesn't warrant pulling in a full HTTP client dependency.
async fn http_json(base: &str, method: &str, path: &str, body: Option<&Value>) -> Result<Option<Value>> {
    let body_bytes = match body {
        Some(value) => serde_json::to_vec(value)?,
        None => Vec::new(),
    };
    let mut stream = TcpStream::connect(base).await.with_context(|| format!("connect {base}"))?;
    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: {base}\r\nConnection: close\r\nContent-Length: {}\r\n",
        body_bytes.len()
    );
    if body.is_some() {
        request.push_str("Content-Type: application/json\r\n");
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).await?;
    stream.write_all(&body_bytes).await?;
    stream.flush().await?;

    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;
    let split = response.windows(4).position(|w| w == b"\r\n\r\n").ok_or_else(|| anyhow!("malformed HTTP response"))?;
    let head = String::from_utf8_lossy(&response[..split]);
    let status: u16 = head.lines().next().and_then(|line| line.split_whitespace().nth(1)).and_then(|code| code.parse().ok()).ok_or_else(|| anyhow!("no status line"))?;
    if !(200..300).contains(&status) {
        bail!("{method} {path} returned HTTP {status}");
    }
    let body = &response[split + 4..];
    if status == 204 || body.is_empty() {
        return Ok(None);
    }
    Ok(Some(serde_json::from_slice(body).with_context(|| format!("parse JSON from {path}"))?))
}
