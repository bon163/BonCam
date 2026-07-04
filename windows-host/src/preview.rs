use std::{
    fs,
    path::Path,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{channel, Receiver, Sender},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

use anyhow::Result;
use bytes::Bytes;
use minifb::{Scale, Window, WindowOptions};
use openh264::{decoder::Decoder, formats::YUVSource};
use serde::Serialize;
use tokio::sync::RwLock;
use tracing::{info, warn};

const SHARED_FRAME_DIR: &str = "C:\\ProgramData\\IPhoneCameraStreaming";
const SHARED_FRAME_PATH: &str = "C:\\ProgramData\\IPhoneCameraStreaming\\latest.rgba";
// latest.rgba = 16-byte header (magic, width, height, stride, all LE u32) + tightly
// packed RGBA pixels. The camera source DLL parses the header, so the host can flip
// between portrait and landscape per frame as the phone rotates. Both orientations
// hold exactly 720*1280*4 pixel bytes, keeping the file length constant — required
// so the in-place overwrite fallback can never leave a short file.
const SHARED_FRAME_MAGIC: &[u8; 4] = b"IPCF";
const SHARED_PORTRAIT: (u32, u32) = (720, 1280);
const SHARED_LANDSCAPE: (u32, u32) = (1280, 720);

pub struct PreviewSink {
    last_h264: Arc<RwLock<Option<Bytes>>>,
    last_jpeg: Arc<RwLock<Option<Bytes>>>,
    last_raw_frame: Arc<RwLock<Option<RawVideoFrame>>>,
    jpeg_version: AtomicU64,
    raw_frame_version: AtomicU64,
    native_preview_tx: Sender<PreviewFrame>,
}

#[derive(Clone)]
struct PreviewFrame {
    data: Bytes,
    is_keyframe: bool,
}

#[derive(Clone)]
pub struct RawVideoFrame {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: &'static str,
    pub data: Bytes,
    pub sequence: u64,
}

#[derive(Clone, Serialize)]
pub struct RawVideoFrameInfo {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub format: &'static str,
    pub byte_len: usize,
    pub sequence: u64,
}

impl PreviewSink {
    pub fn new() -> Self {
        let native_preview_tx = spawn_native_preview_worker();
        Self {
            last_h264: Arc::new(RwLock::new(None)),
            last_jpeg: Arc::new(RwLock::new(None)),
            last_raw_frame: Arc::new(RwLock::new(None)),
            jpeg_version: AtomicU64::new(0),
            raw_frame_version: AtomicU64::new(0),
            native_preview_tx,
        }
    }

    pub async fn submit_h264_annex_b(&self, frame: Bytes, is_keyframe: bool) {
        *self.last_h264.write().await = Some(frame.clone());
        match self.native_preview_tx.send(PreviewFrame { data: frame, is_keyframe }) {
            Ok(()) => {}
            Err(_) => {
                warn!("native preview worker is no longer running");
            }
        }
        if is_keyframe {
            info!("preview sink accepted keyframe");
        }
    }

    pub async fn submit_jpeg_preview(&self, frame: Bytes) {
        *self.last_jpeg.write().await = Some(frame);
        self.jpeg_version.fetch_add(1, Ordering::Relaxed);
    }

    pub async fn submit_raw_rgba_frame(&self, width: u32, height: u32, stride: u32, frame: Bytes) {
        let sequence = self.raw_frame_version.fetch_add(1, Ordering::Relaxed) + 1;
        if let Err(err) = write_shared_raw_frame(width, height, stride, &frame) {
            warn!("failed to write shared raw frame: {err}");
        }
        *self.last_raw_frame.write().await = Some(RawVideoFrame {
            width,
            height,
            stride,
            format: "rgba8",
            data: frame,
            sequence,
        });
    }

    pub async fn latest_jpeg(&self) -> Option<Bytes> {
        self.last_jpeg.read().await.clone()
    }

    pub async fn latest_raw_frame(&self) -> Option<RawVideoFrame> {
        self.last_raw_frame.read().await.clone()
    }

    pub async fn latest_raw_frame_info(&self) -> Option<RawVideoFrameInfo> {
        self.last_raw_frame.read().await.as_ref().map(|frame| RawVideoFrameInfo {
            width: frame.width,
            height: frame.height,
            stride: frame.stride,
            format: frame.format,
            byte_len: frame.data.len(),
            sequence: frame.sequence,
        })
    }

    pub fn jpeg_version(&self) -> u64 {
        self.jpeg_version.load(Ordering::Relaxed)
    }

    pub fn raw_frame_version(&self) -> u64 {
        self.raw_frame_version.load(Ordering::Relaxed)
    }
}

fn write_shared_raw_frame(width: u32, height: u32, stride: u32, frame: &[u8]) -> std::io::Result<()> {
    fs::create_dir_all(SHARED_FRAME_DIR).map_err(|err| {
        std::io::Error::new(err.kind(), format!("create shared frame dir {SHARED_FRAME_DIR}: {err}"))
    })?;

    // Landscape input (phone held sideways) gets a landscape shared frame; portrait
    // input stays portrait. The virtual camera fits either into whatever the app
    // negotiated, so rotation mid-stream needs no renegotiation anywhere.
    let (target_width, target_height) = if width > height { SHARED_LANDSCAPE } else { SHARED_PORTRAIT };
    let target_stride = target_width * 4;

    let mut contents = Vec::with_capacity(16 + (target_stride * target_height) as usize);
    contents.extend_from_slice(SHARED_FRAME_MAGIC);
    contents.extend_from_slice(&target_width.to_le_bytes());
    contents.extend_from_slice(&target_height.to_le_bytes());
    contents.extend_from_slice(&target_stride.to_le_bytes());
    if width == target_width && height == target_height && stride == target_stride {
        let needed = (target_stride * target_height) as usize;
        if frame.len() < needed {
            return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, format!("raw frame has {} bytes but needs {needed}", frame.len())));
        }
        contents.extend_from_slice(&frame[..needed]);
    } else {
        contents.extend_from_slice(&fit_rgba_nearest(width, height, stride, frame, target_width, target_height)?);
    }

    let temp_path = Path::new(SHARED_FRAME_DIR).join("latest.rgba.tmp");
    fs::write(&temp_path, &contents).map_err(|err| {
        std::io::Error::new(err.kind(), format!("write temp frame {}: {err}", temp_path.display()))
    })?;

    match fs::rename(&temp_path, SHARED_FRAME_PATH) {
        Ok(()) => Ok(()),
        Err(rename_err) => {
            // Windows can deny replacing a file while the camera source is reading it.
            // Fall back to an in-place overwrite so the virtual camera still receives
            // fresh frames. Every frame is the same fixed size, so writing without
            // truncation keeps the file length constant and a concurrent read never
            // sees a short file (worst case is a torn frame instead of a fallback flash).
            overwrite_in_place(SHARED_FRAME_PATH, &contents).map_err(|write_err| {
                std::io::Error::new(
                    write_err.kind(),
                    format!(
                        "replace frame via rename failed: {rename_err}; direct write {SHARED_FRAME_PATH} failed: {write_err}"
                    ),
                )
            })?;
            let _ = fs::remove_file(&temp_path);
            Ok(())
        }
    }
}

fn overwrite_in_place(path: &str, contents: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new().write(true).create(true).open(path)?;
    file.write_all(contents)?;
    Ok(())
}

// Aspect-fit `frame` into a target_width x target_height RGBA buffer (nearest
// neighbour, opaque black bars) so mismatched aspect ratios letterbox instead of
// stretching.
fn fit_rgba_nearest(width: u32, height: u32, stride: u32, frame: &[u8], target_width: u32, target_height: u32) -> std::io::Result<Vec<u8>> {
    if width == 0 || height == 0 || stride < width.saturating_mul(4) {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, format!("invalid raw frame dimensions {width}x{height} stride {stride}")));
    }
    let needed = stride as usize * height as usize;
    if frame.len() < needed {
        return Err(std::io::Error::new(std::io::ErrorKind::UnexpectedEof, format!("raw frame has {} bytes but needs at least {needed}", frame.len())));
    }

    let target_stride = target_width * 4;
    let mut out = vec![0_u8; (target_stride * target_height) as usize];
    for pixel in out.chunks_exact_mut(4) {
        pixel[3] = 255;
    }

    let (fit_width, fit_height) = if width as u64 * target_height as u64 >= height as u64 * target_width as u64 {
        (target_width, ((height as u64 * target_width as u64 / width as u64) as u32).max(1))
    } else {
        (((width as u64 * target_height as u64 / height as u64) as u32).max(1), target_height)
    };
    let x_offset = (target_width - fit_width) / 2;
    let y_offset = (target_height - fit_height) / 2;

    for y in 0..fit_height {
        let src_y = (y as u64 * height as u64 / fit_height as u64) as usize;
        let dst_row = ((y + y_offset) * target_stride) as usize;
        let src_row = src_y * stride as usize;
        for x in 0..fit_width {
            let src_x = (x as u64 * width as u64 / fit_width as u64) as usize;
            let src = src_row + src_x * 4;
            let dst = dst_row + ((x + x_offset) * 4) as usize;
            out[dst..dst + 4].copy_from_slice(&frame[src..src + 4]);
        }
    }
    Ok(out)
}

fn spawn_native_preview_worker() -> Sender<PreviewFrame> {
    let (tx, rx) = channel::<PreviewFrame>();
    thread::spawn(move || {
        if let Err(err) = run_native_preview(rx) {
            warn!("native preview worker stopped: {err:#}");
        }
    });
    tx
}

fn run_native_preview(rx: Receiver<PreviewFrame>) -> Result<()> {
    let mut decoder = Decoder::new()?;
    let mut waiting_for_keyframe = true;
    let mut window: Option<Window> = None;
    let mut window_size = (0_usize, 0_usize);
    let mut rgb = Vec::<u8>::new();
    let mut buffer = Vec::<u32>::new();
    let mut displayed_frames = 0_u32;
    let mut fps_started_at = Instant::now();
    let mut last_error_log = Instant::now() - Duration::from_secs(5);

    loop {
        let preview_frame = match rx.recv() {
            Ok(frame) => frame,
            Err(_) => break,
        };

        if waiting_for_keyframe {
            if !preview_frame.is_keyframe {
                continue;
            }
            decoder = Decoder::new()?;
            waiting_for_keyframe = false;
        }

        let decoded = match decoder.decode(preview_frame.data.as_ref()) {
            Ok(Some(decoded)) => decoded,
            Ok(None) => continue,
            Err(err) => {
                if last_error_log.elapsed() >= Duration::from_millis(500) {
                    warn!("h264 decode error, waiting for next keyframe: {err:#}");
                    last_error_log = Instant::now();
                }
                waiting_for_keyframe = true;
                continue;
            }
        };

        let (width, height) = decoded.dimensions();
        if width == 0 || height == 0 {
            continue;
        }

        if window.is_none() || window_size != (width, height) {
            window = Some(create_window(width, height)?);
            window_size = (width, height);
            rgb.clear();
            buffer.clear();
        }

        rgb.resize(width * height * 3, 0);
        decoded.write_rgb8(&mut rgb);
        rgb_to_u32(&rgb, &mut buffer);

        let Some(window) = window.as_mut() else {
            continue;
        };
        if !window.is_open() {
            warn!("native preview window was closed by the user");
            break;
        }

        displayed_frames += 1;
        let elapsed = fps_started_at.elapsed();
        if elapsed >= Duration::from_secs(1) {
            let fps = displayed_frames as f64 / elapsed.as_secs_f64();
            window.set_title(&format!("iPhone Camera Preview - {:.1} fps", fps));
            displayed_frames = 0;
            fps_started_at = Instant::now();
        }

        if let Err(err) = window.update_with_buffer(&buffer, width, height) {
            warn!("failed to update preview window: {err}");
            break;
        }
    }

    Ok(())
}

fn create_window(width: usize, height: usize) -> Result<Window> {
    let mut window = Window::new(
        "iPhone Camera Preview",
        width,
        height,
        WindowOptions {
            resize: true,
            scale: Scale::X1,
            ..WindowOptions::default()
        },
    )?;
    window.set_target_fps(60);
    Ok(window)
}

fn rgb_to_u32(rgb: &[u8], out: &mut Vec<u32>) {
    out.resize(rgb.len() / 3, 0);
    for (index, pixel) in rgb.chunks_exact(3).enumerate() {
        out[index] = ((pixel[0] as u32) << 16) | ((pixel[1] as u32) << 8) | (pixel[2] as u32);
    }
}

impl Default for PreviewSink {
    fn default() -> Self {
        Self::new()
    }
}
