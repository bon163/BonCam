use std::{collections::BTreeMap, net::SocketAddr, sync::Arc};

use anyhow::{anyhow, Result};
use bytes::Bytes;
use protocol::{VideoPacketHeader, VideoStreamKind};
use tokio::{
    io::AsyncReadExt,
    net::{TcpListener, TcpStream},
    sync::Mutex,
};
use tracing::{debug, info, warn};

use crate::preview::PreviewSink;

pub struct VideoReceiver {
    preview: Arc<PreviewSink>,
    assembly: Arc<Mutex<BTreeMap<FrameKey, FrameAssembly>>>,
}

impl VideoReceiver {
    pub fn new(preview: Arc<PreviewSink>) -> Self {
        Self {
            preview,
            assembly: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    pub async fn run(&self, addr: SocketAddr) -> Result<()> {
        let listener = TcpListener::bind(addr).await?;
        loop {
            let (stream, peer) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(err) => {
                    warn!("video accept failed (continuing): {err}");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };
            info!("video connection from {}", peer);
            let preview = self.preview.clone();
            let assembly = self.assembly.clone();
            tokio::spawn(async move {
                if let Err(err) = handle_video_client(stream, preview, assembly).await {
                    warn!("video connection failed: {err:#}");
                }
            });
        }
    }
}

async fn handle_video_client(
    mut stream: TcpStream,
    preview: Arc<PreviewSink>,
    assembly: Arc<Mutex<BTreeMap<FrameKey, FrameAssembly>>>,
) -> Result<()> {
    loop {
        let packet = match read_packet(&mut stream).await {
            Ok(packet) => packet,
            Err(err) if is_clean_eof(&err) => break,
            Err(err) => return Err(err),
        };

        if let Some((header, payload)) = decode_packet(&packet)? {
            debug!("video packet {:?}/{}", header.stream_kind, header.frame_id);
            let maybe_frame = {
                let mut assembly = assembly.lock().await;
                let key = FrameKey {
                    stream_kind: header.stream_kind,
                    frame_id: header.frame_id,
                };
                let entry = assembly.entry(key).or_default();
                entry.insert(header, payload);
                entry.try_finish()
            };

            if let Some((kind, frame, is_keyframe)) = maybe_frame {
                match kind {
                    VideoStreamKind::H264 => preview.submit_h264_annex_b(frame, is_keyframe).await,
                    VideoStreamKind::JpegPreview => preview.submit_jpeg_preview(frame).await,
                }
            }
        }
    }

    Ok(())
}

async fn read_packet(stream: &mut TcpStream) -> Result<Vec<u8>> {
    let mut length_bytes = [0_u8; 4];
    stream.read_exact(&mut length_bytes).await?;
    let packet_len = u32::from_be_bytes(length_bytes) as usize;
    if packet_len == 0 || packet_len > 8 * 1024 * 1024 {
        return Err(anyhow!("invalid packet length: {}", packet_len));
    }
    let mut packet = vec![0_u8; packet_len];
    stream.read_exact(&mut packet).await?;
    Ok(packet)
}

fn is_clean_eof(err: &anyhow::Error) -> bool {
    err.downcast_ref::<std::io::Error>()
        .map(|io| io.kind() == std::io::ErrorKind::UnexpectedEof || io.kind() == std::io::ErrorKind::ConnectionReset)
        .unwrap_or(false)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct FrameKey {
    stream_kind: VideoStreamKind,
    frame_id: u64,
}

#[derive(Default)]
struct FrameAssembly {
    stream_kind: Option<VideoStreamKind>,
    is_keyframe: bool,
    expected: Option<u16>,
    parts: BTreeMap<u16, Bytes>,
}

impl FrameAssembly {
    fn insert(&mut self, header: VideoPacketHeader, payload: Bytes) {
        self.stream_kind = Some(header.stream_kind);
        self.is_keyframe = header.is_keyframe;
        self.expected = Some(header.packet_count);
        self.parts.insert(header.packet_index, payload);
    }

    fn try_finish(&mut self) -> Option<(VideoStreamKind, Bytes, bool)> {
        let expected = self.expected?;
        let kind = self.stream_kind?;
        if self.parts.len() != expected as usize {
            return None;
        }

        let mut out = Vec::new();
        for idx in 0..expected {
            let part = self.parts.remove(&idx)?;
            out.extend_from_slice(&part);
        }
        Some((kind, Bytes::from(out), self.is_keyframe))
    }
}

fn decode_packet(raw: &[u8]) -> Result<Option<(VideoPacketHeader, Bytes)>> {
    if raw.len() < 4 {
        warn!("dropping undersized packet");
        return Ok(None);
    }

    let header_len = u32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]) as usize;
    if raw.len() < 4 + header_len {
        warn!("dropping packet with invalid header length");
        return Ok(None);
    }

    let header: VideoPacketHeader = serde_json::from_slice(&raw[4..4 + header_len])?;
    let payload = Bytes::copy_from_slice(&raw[4 + header_len..]);
    Ok(Some((header, payload)))
}
