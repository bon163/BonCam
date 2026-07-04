mod app;
mod control;
mod pairing;
mod preview;
mod preview_http;
mod video;
mod virtual_camera;
mod webrtc_http;

use std::{
    fs,
    io::Write,
    panic,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::Result;
use tracing::{error, info};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

const LOG_DIR: &str = "C:\\ProgramData\\IPhoneCameraStreaming";
const HOST_LOG_PATH: &str = "C:\\ProgramData\\IPhoneCameraStreaming\\host.log";
const CRASH_LOG_PATH: &str = "C:\\ProgramData\\IPhoneCameraStreaming\\host-crash.log";

// Black-box crash file, separate from host.log so it survives even if the tracing
// pipeline itself is what broke. Timestamps are epoch seconds (UTC); host.log has
// the human-readable UTC timestamp for the same moment.
fn append_crash_log(entry: &str) {
    let _ = fs::create_dir_all(LOG_DIR);
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(CRASH_LOG_PATH) {
        let epoch = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(file, "[epoch {epoch} pid {}] {entry}", std::process::id());
    }
}

// Panics in tokio::spawn'ed tasks are otherwise swallowed silently when their
// JoinHandle is dropped — this hook is the only place they become visible.
fn install_panic_hook() {
    let default_hook = panic::take_hook();
    panic::set_hook(Box::new(move |panic_info| {
        let backtrace = std::backtrace::Backtrace::force_capture();
        let thread = std::thread::current();
        let entry = format!(
            "panic on thread '{}': {panic_info}\nbacktrace:\n{backtrace}",
            thread.name().unwrap_or("<unnamed>")
        );
        // Crash file first: error! below re-enters tracing, which could itself
        // fail if the panic happened while holding the log writer.
        append_crash_log(&entry);
        error!("{entry}");
        default_hook(panic_info);
    }));
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = fs::create_dir_all(LOG_DIR);
    let log_file = fs::OpenOptions::new().create(true).append(true).open(HOST_LOG_PATH)?;
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env().add_directive("windows_host=info".parse()?))
        .with(tracing_subscriber::fmt::layer())
        .with(tracing_subscriber::fmt::layer().with_ansi(false).with_writer(Mutex::new(log_file)))
        .init();
    install_panic_hook();
    info!("windows host starting (pid {})", std::process::id());

    let result = app::HostApp.run().await;
    match &result {
        Ok(()) => info!("windows host exiting cleanly"),
        Err(err) => {
            let entry = format!("host exiting with error: {err:#}");
            append_crash_log(&entry);
            error!("{entry}");
        }
    }
    result
}
