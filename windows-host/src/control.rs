use std::{net::SocketAddr, sync::Arc};

use anyhow::{anyhow, Result};
use protocol::{
    CameraPosition, ControlMessage, PairCodeRequired, PairConfirm, PairRequest, SessionConfig,
    StartStream, StreamPreset, PROTOCOL_VERSION,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    sync::Mutex,
};
use tracing::{info, warn};
use uuid::Uuid;

use crate::pairing::{PairedDevice, PairingStore};

pub struct ControlServer {
    pairing: Arc<Mutex<PairingStore>>,
}

impl ControlServer {
    pub fn new(pairing: Arc<Mutex<PairingStore>>, _preview: Arc<crate::preview::PreviewSink>) -> Self {
        Self { pairing }
    }

    pub async fn run(&self, addr: SocketAddr) -> Result<()> {
        let listener = TcpListener::bind(addr).await?;
        loop {
            let (stream, peer) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(err) => {
                    warn!("control accept failed (continuing): {err}");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };
            info!("control connection from {}", peer);
            let pairing = self.pairing.clone();
            tokio::spawn(async move {
                if let Err(err) = handle_client(stream, pairing).await {
                    warn!("control connection failed: {err:#}");
                }
            });
        }
    }
}

async fn handle_client(stream: TcpStream, pairing: Arc<Mutex<PairingStore>>) -> Result<()> {
    let pair_code = "482391".to_string();
    let (reader, mut writer) = stream.into_split();
    send_message(
        &mut writer,
        &ControlMessage::PairCodeRequired(PairCodeRequired {
            protocol_version: PROTOCOL_VERSION,
            code: pair_code.clone(),
        }),
    )
    .await?;

    let mut lines = BufReader::new(reader).lines();
    let first = lines
        .next_line()
        .await?
        .ok_or_else(|| anyhow!("client disconnected before pairing"))?;
    let pair_request = match serde_json::from_str::<ControlMessage>(&first)? {
        ControlMessage::PairRequest(request) => request,
        other => return Err(anyhow!("expected pair_request, got {:?}", other)),
    };

    validate_pair_request(&pair_request, &pair_code)?;

    let session_id = Uuid::new_v4();
    {
        let mut store = pairing.lock().await;
        if !store.is_paired(&pair_request.device_id) {
            store.add(PairedDevice {
                device_id: pair_request.device_id,
                device_name: pair_request.device_name.clone(),
            });
            store.save("paired-devices.json").await?;
        }
    }

    send_message(
        &mut writer,
        &ControlMessage::PairConfirm(PairConfirm {
            protocol_version: PROTOCOL_VERSION,
            accepted: true,
            reason: None,
            session_id,
            trusted_device_id: Some(pair_request.device_id),
        }),
    )
    .await?;

    send_message(
        &mut writer,
        &ControlMessage::StartStream(StartStream {
            protocol_version: PROTOCOL_VERSION,
            session_id,
            host_video_port: 41_001,
            config: SessionConfig {
                camera_position: CameraPosition::Back,
                preset: StreamPreset::Hd720p30,
                fps: 30,
                bitrate_target: 3_000_000,
            },
        }),
    )
    .await?;

    while let Some(line) = lines.next_line().await? {
        match serde_json::from_str::<ControlMessage>(&line)? {
            ControlMessage::StatusEvent(event) => info!("status event: {:?}", event.kind),
            ControlMessage::StreamStarted(started) => info!("stream started: {:?}", started.info),
            ControlMessage::StopStream(stop) => {
                info!("stream stopped: {:?}", stop.reason);
                break;
            }
            other => info!("control message: {:?}", other),
        }
    }

    Ok(())
}

fn validate_pair_request(request: &PairRequest, expected_code: &str) -> Result<()> {
    if request.protocol_version != PROTOCOL_VERSION {
        return Err(anyhow!("protocol version mismatch"));
    }
    if request.pair_code != expected_code {
        return Err(anyhow!("invalid pair code"));
    }
    Ok(())
}

async fn send_message(
    writer: &mut tokio::net::tcp::OwnedWriteHalf,
    message: &ControlMessage,
) -> Result<()> {
    let mut raw = serde_json::to_vec(message)?;
    raw.push(b'\n');
    writer.write_all(&raw).await?;
    Ok(())
}
