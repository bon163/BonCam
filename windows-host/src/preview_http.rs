use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::Result;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::sleep,
};
use tracing::info;

use crate::preview::PreviewSink;

pub struct PreviewHttpServer {
    preview: Arc<PreviewSink>,
}

impl PreviewHttpServer {
    pub fn new(preview: Arc<PreviewSink>) -> Self {
        Self { preview }
    }

    pub async fn run(&self, addr: SocketAddr) -> Result<()> {
        let listener = TcpListener::bind(addr).await?;
        info!("preview page available at http://127.0.0.1:{}", addr.port());
        loop {
            let (mut stream, _) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(err) => {
                    info!("preview accept failed (continuing): {err}");
                    sleep(Duration::from_millis(100)).await;
                    continue;
                }
            };
            let preview = self.preview.clone();
            tokio::spawn(async move {
                let mut buf = [0_u8; 2048];
                let read = match stream.read(&mut buf).await {
                    Ok(n) => n,
                    Err(_) => return,
                };
                if read == 0 {
                    return;
                }

                let request = String::from_utf8_lossy(&buf[..read]);
                let path = request
                    .lines()
                    .next()
                    .and_then(|line| line.split_whitespace().nth(1))
                    .unwrap_or("/");

                if path.starts_with("/latest.jpg") {
                    respond_latest_jpeg(&mut stream, &preview).await;
                    return;
                }

                if path.starts_with("/stream.mjpg") {
                    stream_mjpeg(&mut stream, &preview).await;
                    return;
                }

                let body = r#"<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>iPhone Camera Preview</title>
  <style>
    body { font-family: Segoe UI, system-ui, sans-serif; margin: 0; background: #111; color: #f5f5f5; }
    header { padding: 16px 20px; font-size: 18px; }
    .frame { display: flex; justify-content: center; padding: 0 20px 20px; }
    img { max-width: min(100vw - 40px, 960px); max-height: calc(100vh - 90px); border-radius: 12px; background: #222; object-fit: contain; }
    .hint { padding: 0 20px 20px; color: #bbb; font-size: 14px; }
  </style>
</head>
<body>
  <header>iPhone Camera Preview</header>
  <div class="frame"><img id="preview" alt="preview" src="/stream.mjpg" /></div>
  <div class="hint">This page now uses a continuous MJPEG stream for smoother motion.</div>
</body>
</html>"#;
                let header = format!(
                    "HTTP/1.1 200 OK
Content-Type: text/html; charset=utf-8
Content-Length: {}
Cache-Control: no-store
Connection: close

",
                    body.len()
                );
                let _ = stream.write_all(header.as_bytes()).await;
                let _ = stream.write_all(body.as_bytes()).await;
            });
        }
    }
}

async fn respond_latest_jpeg(stream: &mut tokio::net::TcpStream, preview: &PreviewSink) {
    if let Some(jpeg) = preview.latest_jpeg().await {
        let header = format!(
            "HTTP/1.1 200 OK
Content-Type: image/jpeg
Content-Length: {}
Cache-Control: no-store
Connection: close

",
            jpeg.len()
        );
        let _ = stream.write_all(header.as_bytes()).await;
        let _ = stream.write_all(&jpeg).await;
    } else {
        let body = b"Preview not ready yet";
        let header = format!(
            "HTTP/1.1 503 Service Unavailable
Content-Type: text/plain; charset=utf-8
Content-Length: {}
Cache-Control: no-store
Connection: close

",
            body.len()
        );
        let _ = stream.write_all(header.as_bytes()).await;
        let _ = stream.write_all(body).await;
    }
}

async fn stream_mjpeg(stream: &mut tokio::net::TcpStream, preview: &PreviewSink) {
    let boundary = "frame";
    let header = format!(
        "HTTP/1.1 200 OK
Content-Type: multipart/x-mixed-replace; boundary={}
Cache-Control: no-store
Connection: close

",
        boundary
    );
    if stream.write_all(header.as_bytes()).await.is_err() {
        return;
    }

    let mut last_version = 0_u64;
    loop {
        let version = preview.jpeg_version();
        if version != last_version {
            if let Some(jpeg) = preview.latest_jpeg().await {
                let part_header = format!(
                    "--{}
Content-Type: image/jpeg
Content-Length: {}

",
                    boundary,
                    jpeg.len()
                );
                if stream.write_all(part_header.as_bytes()).await.is_err() {
                    return;
                }
                if stream.write_all(&jpeg).await.is_err() {
                    return;
                }
                if stream.write_all(b"
").await.is_err() {
                    return;
                }
                last_version = version;
            }
        }
        sleep(Duration::from_millis(33)).await;
    }
}
