use std::{
    collections::VecDeque,
    net::SocketAddr,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use bytes::Bytes;
use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Mutex,
};
use tracing::{info, warn};

use crate::{preview::PreviewSink, virtual_camera::VirtualCameraManager, webrtc_native::NativeWebRtcReceiver};

// The receiver page polls GET /signal/offer every 500ms for as long as its JS is
// actually running, which makes that poll a liveness signal for the tab itself.
// The frame watchdog reads the age to tell "receiver tab dead" (polls stopped)
// apart from "bridge stalled inside a live tab" (polls continuing).
static LAST_RECEIVER_POLL_MS: AtomicU64 = AtomicU64::new(0);

fn now_epoch_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn note_receiver_poll() {
    LAST_RECEIVER_POLL_MS.store(now_epoch_ms(), Ordering::Relaxed);
}

pub fn last_receiver_poll_age_secs() -> Option<u64> {
    match LAST_RECEIVER_POLL_MS.load(Ordering::Relaxed) {
        0 => None,
        t => Some(now_epoch_ms().saturating_sub(t) / 1000),
    }
}

#[derive(Default)]
struct SignalState {
    offer: Option<Value>,
    // Multiple receiver pages can answer the same offer (e.g. a stale tab that is
    // still polling). The host arbitrates: the first receiver that posts a valid
    // tagged answer wins the session, later ones are ignored, and losing pages can
    // see who won via /signal/answer/ack. Arbitrating here (instead of in the phone
    // client) keeps already-shipped phone clients like the iOS app working: they
    // still just GET /signal/answer and receive one plain answer object.
    answer_winner: Option<(String, Value)>,
    phone_candidates: VecDeque<Value>,
    // Entries of shape { id, candidate }; only the winner's are served to the phone.
    receiver_candidates: VecDeque<Value>,
}

#[derive(Clone)]
pub struct WebRtcHttpServer {
    state: Arc<Mutex<SignalState>>,
    preview: Arc<PreviewSink>,
    virtual_camera: Arc<VirtualCameraManager>,
    // The host now answers offers itself (no browser). None only if the WebRTC
    // stack failed to initialize, in which case we fall back to the legacy
    // browser-receiver signaling so the /receiver page still works.
    native: Option<Arc<NativeWebRtcReceiver>>,
}

impl WebRtcHttpServer {
    pub fn new(preview: Arc<PreviewSink>) -> Self {
        let native = match NativeWebRtcReceiver::new(preview.clone()) {
            Ok(receiver) => Some(Arc::new(receiver)),
            Err(err) => {
                warn!("native WebRTC receiver unavailable, falling back to browser receiver: {err:#}");
                None
            }
        };
        Self {
            state: Arc::new(Mutex::new(SignalState::default())),
            virtual_camera: Arc::new(VirtualCameraManager::new(preview.clone())),
            preview,
            native,
        }
    }

    pub async fn run(&self, addr: SocketAddr) -> Result<()> {
        let listener = TcpListener::bind(addr).await?;
        info!("WebRTC receiver available at http://127.0.0.1:{}/receiver", addr.port());
        info!("WebRTC iPhone sender URL is http://<windows-ip>:{}/phone", addr.port());

        loop {
            // A transient accept error (aborted connection in the backlog, buffer
            // pressure) must not take down the server: this loop feeds try_join! in
            // the app, so returning Err here would exit the whole host process —
            // observed live under the ~30 conn/s churn of the raw frame bridge.
            let (stream, peer) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(err) => {
                    warn!("WebRTC HTTP accept failed (continuing): {err}");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };
            let state = self.state.clone();
            let preview = self.preview.clone();
            let virtual_camera = self.virtual_camera.clone();
            let native = self.native.clone();
            tokio::spawn(async move {
                if let Err(err) = handle_connection(stream, state, preview, virtual_camera, native).await {
                    warn!("WebRTC HTTP request from {peer} failed: {err:#}");
                }
            });
        }
    }
}

async fn handle_connection(mut stream: TcpStream, state: Arc<Mutex<SignalState>>, preview: Arc<PreviewSink>, virtual_camera: Arc<VirtualCameraManager>, native: Option<Arc<NativeWebRtcReceiver>>) -> Result<()> {
    // Connections are kept alive and reused for many requests. The raw frame
    // bridge posts ~30 requests/second; closing after every response produced
    // enough connection churn to destabilize the listener.
    let mut buffer = vec![0_u8; 8 * 1024 * 1024];
    let mut read = 0_usize;

    loop {
        let header_end = loop {
            if let Some(pos) = find_header_end(&buffer[..read]) {
                break pos;
            }
            if read == buffer.len() {
                return respond(&mut stream, 413, "text/plain", b"request too large").await;
            }
            let n = match tokio::time::timeout(std::time::Duration::from_secs(60), stream.read(&mut buffer[read..])).await {
                Ok(result) => result?,
                // Idle keep-alive connection: close it quietly.
                Err(_) => return Ok(()),
            };
            if n == 0 {
                return Ok(());
            }
            read += n;
        };

        let (method, path, headers, content_length, close_requested) = {
            let header_text = String::from_utf8_lossy(&buffer[..header_end]);
            let mut lines = header_text.lines();
            let request_line = lines.next().unwrap_or_default();
            let mut request_parts = request_line.split_whitespace();
            let method = request_parts.next().unwrap_or_default().to_string();
            let path = request_parts.next().unwrap_or("/").to_string();
            let headers: Vec<(String, String)> = lines
                .filter_map(|line| line.split_once(':'))
                .map(|(name, value)| (name.trim().to_ascii_lowercase(), value.trim().to_string()))
                .collect();
            let content_length = header_value(&headers, "content-length")
                .and_then(|value| value.parse::<usize>().ok())
                .unwrap_or(0);
            let close_requested = header_value(&headers, "connection")
                .map(|value| value.eq_ignore_ascii_case("close"))
                .unwrap_or(false);
            (method, path, headers, content_length, close_requested)
        };

        let body_start = header_end + 4;
        if body_start + content_length > buffer.len() {
            return respond(&mut stream, 413, "text/plain", b"request too large").await;
        }
        while read < body_start + content_length {
            let n = stream.read(&mut buffer[read..]).await?;
            if n == 0 {
                break;
            }
            read += n;
        }
        let body_end = body_start + content_length.min(read.saturating_sub(body_start));
        let body = &buffer[body_start..body_end];

        if method == "OPTIONS" {
            respond(&mut stream, 204, "text/plain", b"").await?;
            if close_requested {
                return Ok(());
            }
            buffer.copy_within(body_end..read, 0);
            read -= body_end;
            continue;
        }

        let outcome: Result<()> = match (method.as_str(), clean_path(&path)) {
        ("GET", "/") | ("GET", "/receiver") => respond_html(&mut stream, receiver_page()).await,
        ("GET", "/phone") => respond_html(&mut stream, phone_page()).await,
        ("GET", "/virtual-camera/status") => {
            respond_json(&mut stream, serde_json::to_value(virtual_camera.status().await)?).await
        }
        ("POST", "/frame/webrtc.jpg") => {
            preview.submit_jpeg_preview(Bytes::copy_from_slice(body)).await;
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("POST", "/frame/webrtc.rgba") => {
            let width = header_value(&headers, "x-frame-width").and_then(|value| value.parse::<u32>().ok()).unwrap_or(0);
            let height = header_value(&headers, "x-frame-height").and_then(|value| value.parse::<u32>().ok()).unwrap_or(0);
            let stride = header_value(&headers, "x-frame-stride").and_then(|value| value.parse::<u32>().ok()).unwrap_or(width.saturating_mul(4));
            if width == 0 || height == 0 || body.is_empty() {
                return respond(&mut stream, 400, "text/plain", b"invalid raw frame").await;
            }
            preview.submit_raw_rgba_frame(width, height, stride, Bytes::copy_from_slice(body)).await;
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("POST", "/client-log") => {
            // Browser-side black box: the receiver page mirrors its lifecycle
            // events (tab freeze/resume, pc state, bridge start) here so they
            // land in the same log as host events. A bad body is ignored rather
            // than erroring — this endpoint must never disturb a session.
            if let Ok(value) = serde_json::from_slice::<Value>(body) {
                let source = value.get("source").and_then(Value::as_str).unwrap_or("client");
                let id = value.get("id").and_then(Value::as_str).unwrap_or("-");
                let message: String = value.get("message").and_then(Value::as_str).unwrap_or("").chars().take(300).collect();
                info!("client[{source} {id}]: {message}");
            }
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("POST", "/signal/reset") => {
            info!("WebRTC signal: phone reset signaling (new session starting)");
            *state.lock().await = SignalState::default();
            if let Some(native) = &native {
                native.reset().await;
            }
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("POST", "/signal/offer") => {
            let value: Value = serde_json::from_slice(body)?;
            info!("WebRTC signal: phone posted offer");
            // The host answers the offer itself (native receiver), so no browser is
            // required. We still record the offer so a browser /receiver can serve as
            // a fallback if the native stack failed to initialize.
            let native_answer = match &native {
                Some(native) => match native.accept_offer(&value).await {
                    Ok(answer) => Some(answer),
                    Err(err) => {
                        warn!("WebRTC signal: native receiver failed to answer offer (browser fallback active): {err:#}");
                        None
                    }
                },
                None => None,
            };
            let mut state = state.lock().await;
            state.offer = Some(value);
            // Do NOT clear phone_candidates here: the phone's trickle candidates can
            // race ahead of the offer POST and would be wiped (observed live, breaks
            // ICE entirely). Phone clients always POST /signal/reset before creating
            // their peer connection, so reset is the safe clearing point.
            state.receiver_candidates.clear();
            match native_answer {
                // The host is the winning "receiver": publish its answer so the phone
                // consumes it at GET /signal/answer exactly as before.
                Some(answer) => state.answer_winner = Some((crate::webrtc_native::HOST_RECEIVER_ID.to_string(), answer)),
                None => state.answer_winner = None,
            }
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("GET", "/signal/offer") => {
            note_receiver_poll();
            let offer = state.lock().await.offer.clone();
            match offer {
                Some(value) => respond_json(&mut stream, value).await,
                None => respond(&mut stream, 204, "text/plain", b"").await,
            }
        }
        ("POST", "/signal/answer") => {
            let value: Value = serde_json::from_slice(body)?;
            let id = value.get("id").and_then(|id| id.as_str()).map(str::to_string);
            let answer = value.get("answer").filter(|answer| answer.get("type").is_some()).cloned();
            let mut state = state.lock().await;
            match (id, answer) {
                (Some(id), Some(answer)) => match &state.answer_winner {
                    None => {
                        info!("WebRTC signal: receiver {id} posted answer and was selected");
                        state.answer_winner = Some((id, answer));
                    }
                    Some((winner, _)) if *winner == id => {
                        state.answer_winner = Some((id, answer));
                    }
                    Some((winner, _)) => {
                        info!("WebRTC signal: receiver {id} posted answer but {winner} already won");
                    }
                },
                _ => warn!("WebRTC signal: ignored answer without receiver id (stale receiver page?)"),
            }
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("GET", "/signal/answer") => {
            let winner = state.lock().await.answer_winner.clone();
            match winner {
                Some((id, mut answer)) => {
                    // The extra "id" key is ignored by setRemoteDescription, so old
                    // phone clients can consume this object as-is.
                    if let Some(map) = answer.as_object_mut() {
                        map.insert("id".to_string(), json!(id));
                    }
                    respond_json(&mut stream, answer).await
                }
                None => respond(&mut stream, 204, "text/plain", b"").await,
            }
        }
        ("POST", "/signal/answer/ack") => {
            // Legacy no-op: the host now selects the winner itself.
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("GET", "/signal/answer/ack") => {
            let winner = state.lock().await.answer_winner.clone();
            match winner {
                Some((id, _)) => respond_json(&mut stream, json!({ "id": id })).await,
                None => respond(&mut stream, 204, "text/plain", b"").await,
            }
        }
        ("POST", "/signal/candidate/phone") => {
            let value: Value = serde_json::from_slice(body)?;
            // Feed the native peer connection directly; also buffer for a browser
            // fallback receiver (which reads GET /signal/candidates/phone).
            if let Some(native) = &native {
                native.add_phone_candidate(&value).await;
            }
            state.lock().await.phone_candidates.push_back(value);
            info!("WebRTC signal: phone posted ICE candidate");
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("GET", "/signal/candidates/phone") => {
            let candidates: Vec<Value> = state.lock().await.phone_candidates.iter().cloned().collect();
            respond_json(&mut stream, json!({ "candidates": candidates })).await
        }
        ("POST", "/signal/candidate/receiver") => {
            let value: Value = serde_json::from_slice(body)?;
            let tagged = value.get("id").and_then(|id| id.as_str()).is_some() && value.get("candidate").is_some();
            if tagged {
                state.lock().await.receiver_candidates.push_back(value);
                info!("WebRTC signal: receiver posted ICE candidate");
            } else {
                warn!("WebRTC signal: ignored untagged receiver candidate (stale receiver page?)");
            }
            respond_json(&mut stream, json!({ "ok": true })).await
        }
        ("GET", "/signal/candidates/receiver") => {
            // When the host is answering natively, serve its gathered local
            // candidates. Otherwise (browser fallback) serve only the winning
            // browser receiver's candidates, flattened to the plain shape the phone
            // expects. Both already produce plain `{ candidate, sdpMid, ... }` objects.
            let native_candidates = match &native {
                Some(native) if native.is_active().await => Some(native.host_candidates().await),
                _ => None,
            };
            let candidates: Vec<Value> = match native_candidates {
                Some(candidates) => candidates,
                None => {
                    let state = state.lock().await;
                    let winner_id = state.answer_winner.as_ref().map(|(id, _)| id.clone());
                    state
                        .receiver_candidates
                        .iter()
                        .filter(|entry| entry.get("id").and_then(|id| id.as_str()) == winner_id.as_deref())
                        .filter_map(|entry| entry.get("candidate").cloned())
                        .collect()
                }
            };
            respond_json(&mut stream, json!({ "candidates": candidates })).await
        }
        _ => respond(&mut stream, 404, "text/plain", b"not found").await,
        };
        outcome?;

        if close_requested {
            return Ok(());
        }
        buffer.copy_within(body_end..read, 0);
        read -= body_end;
    }
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn clean_path(path: &str) -> &str {
    path.split('?').next().unwrap_or(path)
}

fn header_value<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    let name = name.to_ascii_lowercase();
    headers
        .iter()
        .find(|(candidate, _)| candidate == &name)
        .map(|(_, value)| value.as_str())
}

async fn respond_html(stream: &mut TcpStream, body: String) -> Result<()> {
    respond(stream, 200, "text/html; charset=utf-8", body.as_bytes()).await
}

async fn respond_json(stream: &mut TcpStream, value: Value) -> Result<()> {
    let body = serde_json::to_vec(&value)?;
    respond(stream, 200, "application/json", &body).await
}

async fn respond(stream: &mut TcpStream, status: u16, content_type: &str, body: &[u8]) -> Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        404 => "Not Found",
        413 => "Payload Too Large",
        _ => "OK",
    };
    let header = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).await?;
    stream.write_all(body).await?;
    Ok(())
}

fn receiver_page() -> String {
    page_shell(
        "Windows Receiver",
        r#"
        <video id="remote" autoplay playsinline muted></video>
        <div class="panel">
          <h1>WebRTC Receiver</h1>
          <p id="status">Waiting for iPhone sender...</p>
          <button id="popout">Open popout</button>
          <button id="bridge">Start JPEG bridge</button>
          <button id="rawBridge">Start virtual cam bridge</button>
          <button id="reset">Reset session</button>
        </div>
        <script>
          const statusEl = document.querySelector('#status');
          const remote = document.querySelector('#remote');
          // Identifies this receiver page so the phone can pick exactly one when
          // several tabs answer the same offer (stale tabs are the classic case).
          const receiverId = Math.random().toString(36).slice(2) + Date.now().toString(36);
          const seenPhoneCandidates = new Set();
          let pc;
          let popoutWindow;
          let remoteStream;
          let frameBridgeStarted = false;
          let rawBridgeStarted = false;

          const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
          const post = (url, body = {}) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
          const getJson = async url => {
            const response = await fetch(url, { cache: 'no-store' });
            if (response.status === 204) return null;
            if (!response.ok) throw new Error(url + ' returned ' + response.status);
            return response.json();
          };
          const setStatus = text => { statusEl.textContent = text; console.log(text); };
          // Black-box: mirror receiver-side lifecycle events into the host log so
          // browser-side failures (tab sleep/freeze) show up next to host events.
          // keepalive lets last-gasp reports (freeze/pagehide) escape before the
          // browser suspends script execution.
          const logToHost = (message, keepalive = false) => {
            try {
              fetch('/client-log', { method: 'POST', keepalive, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ source: 'receiver', id: receiverId, message }) }).catch(() => {});
            } catch (error) { console.warn('logToHost failed', error); }
          };

          async function postFrameBlob(blob) {
            try {
              await fetch('/frame/webrtc.jpg', { method: 'POST', headers: { 'Content-Type': 'image/jpeg' }, body: blob });
            } catch (error) {
              console.warn('Frame bridge post failed', error);
            }
          }

          // Timers on a hidden page are clamped to >=1s, which froze the virtual
          // camera whenever this window was minimized. Worker timers are exempt.
          function startTicker(intervalMs, onTick) {
            const source = 'setInterval(function () { postMessage(0); }, ' + intervalMs + ');';
            const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'application/javascript' })));
            worker.onmessage = onTick;
            return worker;
          }

          function startFrameBridge() {
            if (frameBridgeStarted) return;
            frameBridgeStarted = true;
            setStatus('Frame bridge started. Smooth WebRTC preview may remain better than 41002.');
            const canvas = document.createElement('canvas');
            const ctx = canvas.getContext('2d', { alpha: false });
            let inFlight = false;
            startTicker(100, () => {
              if (!remote.videoWidth || !remote.videoHeight || inFlight) return;
              if (canvas.width !== remote.videoWidth || canvas.height !== remote.videoHeight) {
                canvas.width = remote.videoWidth;
                canvas.height = remote.videoHeight;
              }
              ctx.drawImage(remote, 0, 0, canvas.width, canvas.height);
              inFlight = true;
              canvas.toBlob(blob => {
                if (blob) postFrameBlob(blob).finally(() => inFlight = false);
                else inFlight = false;
              }, 'image/jpeg', 0.82);
            });
          }

          let lastPostOkAt = 0;
          let postedFrames = 0;
          let bridgeMode = 'none';

          async function postRawFrame(width, height, bytes) {
            // A fetch with no timeout that never settles would leave inFlight stuck
            // true forever and silently freeze the bridge — abort instead.
            const abort = new AbortController();
            const timer = setTimeout(() => abort.abort(), 5000);
            try {
              const response = await fetch('/frame/webrtc.rgba', {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/octet-stream',
                  'X-Frame-Width': String(width),
                  'X-Frame-Height': String(height),
                  'X-Frame-Stride': String(width * 4)
                },
                body: bytes,
                signal: abort.signal
              });
              // Drain the (tiny) response so the browser releases the request
              // eagerly instead of keeping it alive until GC finalizes it.
              await response.arrayBuffer();
              lastPostOkAt = Date.now();
              postedFrames += 1;
            } catch (error) {
              console.warn('Raw frame bridge post failed', error);
            } finally {
              clearTimeout(timer);
            }
          }

          // getImageData allocates a fresh ~3.7MB ImageData every frame; at 30fps
          // the GC falls behind on the saturated main thread and the tab is
          // OOM-killed near frame ~2000 (heartbeats: heap 2MB -> 68MB -> 423MB).
          // WebGL readPixels can write into ONE reused buffer instead — the 2d
          // canvas API has no such option — so steady-state allocation is zero.
          function createGlFrameGrabber() {
            const canvas = document.createElement('canvas');
            const gl = canvas.getContext('webgl', { alpha: false, depth: false, stencil: false, antialias: false, preserveDrawingBuffer: false });
            if (!gl) return null;
            const compile = (type, source) => {
              const shader = gl.createShader(type);
              gl.shaderSource(shader, source);
              gl.compileShader(shader);
              return shader;
            };
            const program = gl.createProgram();
            // The plain y mapping renders the image upside down in the framebuffer,
            // which cancels readPixels' bottom-up row order: the output buffer
            // comes out top-down, the layout the host expects.
            gl.attachShader(program, compile(gl.VERTEX_SHADER, 'attribute vec2 p; varying vec2 t; void main() { t = p * 0.5 + 0.5; gl_Position = vec4(p, 0.0, 1.0); }'));
            gl.attachShader(program, compile(gl.FRAGMENT_SHADER, 'precision mediump float; varying vec2 t; uniform sampler2D s; void main() { gl_FragColor = texture2D(s, t); }'));
            gl.linkProgram(program);
            if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
            gl.useProgram(program);
            const quad = gl.createBuffer();
            gl.bindBuffer(gl.ARRAY_BUFFER, quad);
            gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
            const location = gl.getAttribLocation(program, 'p');
            gl.enableVertexAttribArray(location);
            gl.vertexAttribPointer(location, 2, gl.FLOAT, false, 0, 0);
            const texture = gl.createTexture();
            gl.bindTexture(gl.TEXTURE_2D, texture);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            let buffer = null;
            let lost = false;
            canvas.addEventListener('webglcontextlost', event => { event.preventDefault(); lost = true; });
            return {
              isLost: () => lost,
              grab() {
                const width = remote.videoWidth;
                const height = remote.videoHeight;
                if (canvas.width !== width || canvas.height !== height) {
                  canvas.width = width;
                  canvas.height = height;
                  gl.viewport(0, 0, width, height);
                  buffer = new Uint8Array(width * height * 4);
                }
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, remote);
                gl.drawArrays(gl.TRIANGLES, 0, 3);
                gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, buffer);
                return { width, height, bytes: buffer };
              }
            };
          }

          function startRawFrameBridge() {
            if (rawBridgeStarted) return;
            rawBridgeStarted = true;
            sessionStorage.setItem('autoRawBridge', '1');
            setStatus('Virtual camera raw bridge started. This is the feed the device layer will consume.');
            let grabber = createGlFrameGrabber();
            if (!grabber) logToHost('WebGL unavailable — raw bridge falling back to 2d canvas (heavy GC pressure, tab may OOM near frame ~2000)');
            let canvas = null;
            let ctx = null;
            const grab2d = () => {
              if (!canvas) {
                canvas = document.createElement('canvas');
                ctx = canvas.getContext('2d', { alpha: false, willReadFrequently: true });
              }
              // Assigning width/height clears and reallocates the canvas even when
              // the value is unchanged — only resize on a real dimension change.
              if (canvas.width !== remote.videoWidth || canvas.height !== remote.videoHeight) {
                canvas.width = remote.videoWidth;
                canvas.height = remote.videoHeight;
              }
              ctx.drawImage(remote, 0, 0, canvas.width, canvas.height);
              const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
              return { width: canvas.width, height: canvas.height, bytes: image.data };
            };
            let inFlight = false;
            startTicker(33, () => {
              if (!remote.videoWidth || !remote.videoHeight || inFlight) return;
              if (grabber && grabber.isLost()) {
                logToHost('WebGL context lost — recreating frame grabber');
                grabber = createGlFrameGrabber();
              }
              // Reusing the grabber's buffer across ticks is safe: fetch snapshots
              // a BufferSource body at call time, and inFlight serializes posts.
              const frame = grabber ? grabber.grab() : grab2d();
              bridgeMode = grabber ? 'webgl' : '2d';
              inFlight = true;
              postRawFrame(frame.width, frame.height, frame.bytes).finally(() => inFlight = false);
            });
            // Self-heal: if posts stop while the WebRTC leg is still connected, the
            // bridge machinery is wedged — reload the page; autoRawBridge restarts
            // the bridge and the outstanding offer gets re-answered on load.
            startTicker(2000, () => {
              if (!lastPostOkAt || !pc || pc.connectionState !== 'connected') return;
              const stalledMs = Date.now() - lastPostOkAt;
              if (stalledMs > 8000) {
                logToHost('bridge stalled ' + Math.round(stalledMs / 1000) + 's with pc connected; reloading receiver page', true);
                location.reload();
              }
            });
          }

          function attachPopoutStream() {
            if (!popoutWindow || popoutWindow.closed || !remoteStream) return;
            const video = popoutWindow.document.querySelector('video');
            if (video && video.srcObject !== remoteStream) {
              video.srcObject = remoteStream;
            }
          }

          function openPopout() {
            popoutWindow = window.open('', 'iphone-camera-webrtc-popout', 'popup=yes,width=1000,height=620');
            if (!popoutWindow) {
              setStatus('Popout was blocked by the browser. Allow popups for this page.');
              return;
            }
            popoutWindow.document.open();
            popoutWindow.document.write(`<!doctype html><html><head><title>iPhone Camera Popout</title><style>html,body{margin:0;width:100%;height:100%;background:#050708;overflow:hidden}video{width:100%;height:100%;object-fit:contain;background:#050708}</style></head><body><video autoplay playsinline muted></video></body></html>`);
            popoutWindow.document.close();
            attachPopoutStream();
          }

          function closePeerConnection() {
            if (pc) {
              pc.ontrack = null;
              pc.onicecandidate = null;
              pc.onconnectionstatechange = null;
              pc.close();
            }
            pc = null;
            remote.srcObject = null;
            remoteStream = null;
            seenPhoneCandidates.clear();
          }

          function createPeerConnection() {
            pc = new RTCPeerConnection({ iceServers: [] });
            pc.ontrack = event => {
              remoteStream = event.streams[0];
              remote.srcObject = remoteStream;
              attachPopoutStream();
              setStatus('Receiving video. This is the WebRTC path.');
              logToHost('remote track attached');
              event.track.addEventListener('ended', () => logToHost('remote track ended'));
            };
            pc.onconnectionstatechange = () => { setStatus('Connection: ' + pc.connectionState); logToHost('pc state: ' + pc.connectionState); };
            pc.onicecandidate = event => {
              if (event.candidate) post('/signal/candidate/receiver', { id: receiverId, candidate: event.candidate.toJSON() }).catch(console.error);
            };
          }

          async function answerOffer(offer) {
            closePeerConnection();
            createPeerConnection();
            setStatus('Offer received. Creating answer...');
            await pc.setRemoteDescription(offer);
            const answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            await post('/signal/answer', { id: receiverId, answer: pc.localDescription.toJSON() });
            setStatus('Answer sent. Waiting for video...');
            logToHost('answer posted for current offer');
            pollPhoneCandidates(pc);
            watchAnswerAck(pc);
          }

          async function watchAnswerAck(activePc) {
            while (pc === activePc) {
              try {
                const ack = await getJson('/signal/answer/ack');
                if (ack && ack.id && ack.id !== receiverId) {
                  closePeerConnection();
                  setStatus('Another receiver window took this stream. Close duplicate receiver tabs, then reset the session here if you want this one to receive.');
                  return;
                }
              } catch (error) {
                console.error(error);
              }
              await sleep(1000);
            }
          }

          let lastOfferKey = '';
          // After a tab freeze the peer connection is usually dead but the offer
          // key is unchanged, so watchOffers would never re-answer. Clearing the
          // key forces a fresh answer to whatever offer is outstanding.
          function reanswerIfDead(why) {
            if (!pc || ['failed', 'closed', 'disconnected'].includes(pc.connectionState)) {
              lastOfferKey = '';
              logToHost('connection dead after ' + why + '; will re-answer next offer');
            }
          }

          async function watchOffers() {
            while (true) {
              try {
                const offer = await getJson('/signal/offer');
                if (offer) {
                  const offerKey = JSON.stringify(offer);
                  if (offerKey !== lastOfferKey) {
                    lastOfferKey = offerKey;
                    await answerOffer(offer);
                  }
                }
              } catch (error) {
                console.error(error);
                setStatus('Receiver offer watch failed: ' + error.message);
              }
              await sleep(500);
            }
          }

          async function pollPhoneCandidates(activePc) {
            while (pc === activePc) {
              try {
                const payload = await getJson('/signal/candidates/phone');
                for (const candidate of payload?.candidates ?? []) {
                  const key = JSON.stringify(candidate);
                  if (!seenPhoneCandidates.has(key)) {
                    seenPhoneCandidates.add(key);
                    await activePc.addIceCandidate(candidate);
                  }
                }
              } catch (error) {
                console.error(error);
              }
              await sleep(500);
            }
          }

          // Edge/Chrome exempt tabs that are playing audio from sleeping tabs and
          // tab freezing — exactly what suspended this page in the background and
          // froze the bridge (seen live 2026-07-04). Must be called from a user
          // gesture (the bridge buttons) or the AudioContext starts suspended.
          let keepAwakeStarted = false;
          function keepAwake() {
            if (keepAwakeStarted) return;
            keepAwakeStarted = true;
            try {
              const audio = new AudioContext();
              const oscillator = audio.createOscillator();
              const gain = audio.createGain();
              gain.gain.value = 0.001;
              oscillator.connect(gain).connect(audio.destination);
              oscillator.start();
              // Without a user gesture (auto-restart after a self-heal reload) the
              // context stays 'suspended' and does NOT exempt the tab from sleep.
              logToHost('keep-awake audio started (state ' + audio.state + ')');
            } catch (error) {
              logToHost('keep-awake audio failed: ' + error.message);
            }
            const requestWakeLock = () => navigator.wakeLock?.request('screen').catch(() => {});
            requestWakeLock();
            document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') requestWakeLock(); });
          }

          document.querySelector('#popout').addEventListener('click', openPopout);
          document.querySelector('#bridge').addEventListener('click', () => { keepAwake(); startFrameBridge(); logToHost('jpeg bridge started'); });
          document.querySelector('#rawBridge').addEventListener('click', () => { keepAwake(); startRawFrameBridge(); logToHost('raw bridge started'); });

          document.querySelector('#reset').addEventListener('click', async () => {
            await post('/signal/reset');
            location.reload();
          });

          document.addEventListener('visibilitychange', () => {
            logToHost('visibility: ' + document.visibilityState);
            if (document.visibilityState === 'visible') reanswerIfDead('background');
          });
          document.addEventListener('freeze', () => logToHost('TAB FROZEN by browser (bridge and signaling suspended)', true));
          document.addEventListener('resume', () => { logToHost('tab resumed'); reanswerIfDead('freeze'); });
          window.addEventListener('pagehide', () => logToHost('pagehide (tab closing or navigating away)', true));

          logToHost('receiver page loaded');
          // Telemetry heartbeat: postedFrames + JS heap, to confirm/refute the
          // renderer-memory theory behind the tab dying near frame ~2000.
          startTicker(30000, () => {
            const memory = performance.memory
              ? Math.round(performance.memory.usedJSHeapSize / 1048576) + '/' + Math.round(performance.memory.totalJSHeapSize / 1048576) + 'MB'
              : 'n/a';
            logToHost('page heartbeat: rawBridge=' + rawBridgeStarted + ' (' + bridgeMode + '), posted ' + postedFrames + ' frames, js heap ' + memory);
          });
          if (sessionStorage.getItem('autoRawBridge') === '1') {
            logToHost('auto-restarting raw bridge after reload');
            keepAwake();
            startRawFrameBridge();
          }
          watchOffers().catch(error => { console.error(error); setStatus('Receiver failed: ' + error.message); });
        </script>
        "#,
    )
}

fn phone_page() -> String {
    page_shell(
        "iPhone Sender",
        r#"
        <video id="local" autoplay playsinline muted></video>
        <div class="panel">
          <h1>iPhone Sender</h1>
          <p id="status">Preparing camera...</p>
          <button id="start">Start WebRTC stream</button>
        </div>
        <script>
          const statusEl = document.querySelector('#status');
          const local = document.querySelector('#local');
          let seenReceiverCandidates = new Set();
          let pc;
          let stream;
          let wakeLock = null;
          let restartTimer = null;

          const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
          const post = (url, body = {}) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
          const getJson = async url => {
            const response = await fetch(url, { cache: 'no-store' });
            if (response.status === 204) return null;
            if (!response.ok) throw new Error(url + ' returned ' + response.status);
            return response.json();
          };
          const setStatus = text => statusEl.textContent = text;

          // Without a wake lock the iPhone auto-locks (default 30s), Safari suspends
          // the page, and the WebRTC stream dies. Wake locks are released on every
          // page hide, so re-acquire whenever the page becomes visible again.
          async function acquireWakeLock() {
            if (!('wakeLock' in navigator)) {
              setStatus('No wake lock support: disable auto-lock in iOS Settings while streaming.');
              return;
            }
            try {
              wakeLock = await navigator.wakeLock.request('screen');
              wakeLock.addEventListener('release', () => { wakeLock = null; });
            } catch (error) {
              console.warn('Wake lock failed', error);
            }
          }

          function scheduleRestart(reason) {
            if (restartTimer) return;
            setStatus('Stream interrupted (' + reason + '). Reconnecting...');
            restartTimer = setTimeout(() => {
              restartTimer = null;
              start().catch(error => {
                setStatus('Reconnect failed: ' + error.message);
                scheduleRestart('retrying');
              });
            }, 2000);
          }

          async function start() {
            document.querySelector('#start').disabled = true;
            await acquireWakeLock();
            if (pc) {
              pc.onconnectionstatechange = null;
              pc.onicecandidate = null;
              pc.close();
              pc = null;
            }
            if (stream) {
              for (const track of stream.getTracks()) track.stop();
              stream = null;
            }
            seenReceiverCandidates = new Set();
            await post('/signal/reset');
            pc = new RTCPeerConnection({ iceServers: [] });
            const activePc = pc;
            activePc.onconnectionstatechange = () => {
              if (pc !== activePc) return;
              setStatus('Connection: ' + activePc.connectionState);
              if (activePc.connectionState === 'failed' || activePc.connectionState === 'closed') {
                scheduleRestart(activePc.connectionState);
              } else if (activePc.connectionState === 'disconnected') {
                setTimeout(() => {
                  if (pc === activePc && activePc.connectionState === 'disconnected') scheduleRestart('disconnected');
                }, 4000);
              }
            };
            activePc.onicecandidate = event => {
              if (event.candidate) post('/signal/candidate/phone', event.candidate.toJSON()).catch(console.error);
            };

            stream = await navigator.mediaDevices.getUserMedia({
              audio: false,
              video: {
                facingMode: { ideal: 'environment' },
                width: { ideal: 1280 },
                height: { ideal: 720 },
                frameRate: { ideal: 30, max: 30 }
              }
            });
            local.srcObject = stream;
            for (const track of stream.getTracks()) {
              track.addEventListener('ended', () => scheduleRestart('camera stopped'));
              activePc.addTrack(track, stream);
            }
            // Pin the encoding so WebRTC does not downscale resolution on packet
            // loss (default 'balanced' degradation). LAN link => cap bitrate high.
            try {
              const videoSender = activePc.getSenders().find(s => s.track && s.track.kind === 'video');
              if (videoSender) {
                const params = videoSender.getParameters();
                if (!params.encodings || params.encodings.length === 0) params.encodings = [{}];
                params.encodings[0].maxBitrate = 5000000;
                params.encodings[0].maxFramerate = 30;
                params.degradationPreference = 'maintain-resolution';
                await videoSender.setParameters(params);
              }
            } catch (error) { console.error('setParameters failed', error); }

            const offer = await activePc.createOffer({ offerToReceiveVideo: false });
            await activePc.setLocalDescription(offer);
            await post('/signal/offer', activePc.localDescription.toJSON());
            setStatus('Offer sent. Waiting for Windows answer...');

            while (!activePc.currentRemoteDescription) {
              if (pc !== activePc) return;
              const answer = await getJson('/signal/answer');
              if (answer && answer.type) await activePc.setRemoteDescription(answer);
              await sleep(500);
            }
            setStatus('Streaming to Windows over WebRTC.');
            pollReceiverCandidates(activePc);
          }

          async function pollReceiverCandidates(activePc) {
            while (pc === activePc) {
              try {
                const payload = await getJson('/signal/candidates/receiver');
                for (const candidate of payload?.candidates ?? []) {
                  const key = JSON.stringify(candidate);
                  if (!seenReceiverCandidates.has(key)) {
                    seenReceiverCandidates.add(key);
                    await activePc.addIceCandidate(candidate);
                  }
                }
              } catch (error) {
                console.error(error);
              }
              await sleep(500);
            }
          }

          document.addEventListener('visibilitychange', () => {
            if (document.visibilityState !== 'visible') return;
            acquireWakeLock();
            if (pc && ['failed', 'disconnected', 'closed'].includes(pc.connectionState)) scheduleRestart('page resumed');
          });

          document.querySelector('#start').addEventListener('click', () => start().catch(error => {
            document.querySelector('#start').disabled = false;
            setStatus('Failed: ' + error.message);
          }));
        </script>
        "#,
    )
}

fn page_shell(title: &str, body: &str) -> String {
    format!(
        r#"<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title}</title>
  <style>
    :root {{ color-scheme: dark; --ink: #f5efe2; --muted: #c9bfae; --panel: rgba(22, 28, 30, .78); --line: rgba(255,255,255,.14); }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; min-height: 100vh; font-family: Avenir Next, ui-rounded, system-ui, sans-serif; color: var(--ink); background: radial-gradient(circle at top left, #2d4d48, transparent 34rem), linear-gradient(135deg, #101719, #202319 55%, #3b2f1f); overflow: hidden; }}
    video {{ position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; background: #050708; }}
    .panel {{ position: fixed; left: 18px; right: 18px; bottom: 18px; max-width: 620px; padding: 18px; border: 1px solid var(--line); border-radius: 22px; background: var(--panel); backdrop-filter: blur(18px); box-shadow: 0 20px 70px rgba(0,0,0,.35); }}
    h1 {{ margin: 0 0 8px; font-size: clamp(24px, 5vw, 42px); letter-spacing: -.04em; }}
    p {{ margin: 0 0 14px; color: var(--muted); line-height: 1.45; }}
    button {{ border: 0; border-radius: 999px; padding: 12px 16px; color: #14201d; background: #f2c46d; font: inherit; font-weight: 700; }}
    button:disabled {{ opacity: .5; }}
  </style>
</head>
<body>
{body}
</body>
</html>"#
    )
}
