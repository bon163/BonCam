# iPhone Camera Streaming Handoff

Last updated: 2026-07-06 (added a phone-free synthetic WebRTC sender for testing;
branch `tooling-synthetic-sender`)

## 2026-07-06: synthetic sender — phone-free end-to-end testing (branch `tooling-synthetic-sender`)

New binary `windows-host/src/bin/synthetic_sender.rs`: a real WebRTC peer that
speaks the exact `/signal/*` protocol the iOS app and /phone page speak, so the
whole phone->host->latest.rgba pipeline can be exercised from the command line
with NO phone and NO browser (the Edge fake-camera still needed a GUI + clicking).
Nearly every entry below is "COMPILES but NOT verified live"; this closes that gap.

What it does: builds an offering `RTCPeerConnection` (webrtc-rs, default codecs so
H264 negotiates against the receiver's MediaEngine, no ICE servers = loopback/LAN
host candidates), adds an H264 `TrackLocalStaticSample`, drives the signaling
handshake (`POST /signal/reset` -> offer -> poll `GET /signal/answer` -> trickle
candidates both ways), encodes an animated I420 test pattern with openh264, and
feeds it to the track. It also reads RTCP off the sender and answers the host's
PLI by forcing a keyframe — so the keyframe path that previously needed a phone
dropping packets is now exercisable on demand.

Run it (no admin, no phone):
    cargo run -p windows-host                              # terminal 1: the host
    cargo run --release -p windows-host --bin synthetic_sender   # terminal 2
Options: --host 127.0.0.1 --port 41003 --width 1280 --height 720 --fps 30
         --seconds 0(=forever) --bitrate 4000000.

VERIFIED LIVE 2026-07-06 (host + sender both on this PC, no phone): host.log logged
the full healthy sequence — `answered phone offer as host-native` -> `peer
connection state connected` -> `remote track added (video/H264)` -> initial
`decode error Native:16` on the first access unit (missing param sets at join) ->
host `requested keyframe (PLI)` -> sender forced an IDR -> `raw bridge frames
FLOWING` -> `latest.rgba` LastWriteTime advanced. The PLI round-trip works.

Frame-rate note: bounded by SOFTWARE openh264 encode, not the tool's Rust code
(release barely beat debug — the encoder is a C lib). On this machine 1280x720 ~=
13fps; 640x360 hits a clean 30fps (measured 150 frames in 5s). Generating the
pattern directly in I420 (not RGB) removed the pure-Rust RGB->YUV conversion that
was the second bottleneck. Use 720p/13fps for connectivity/PLI/soak checks; use
`--width 640 --height 360` when you need to stress the host's 30fps latest-wins
decode_loop. Only `windows-host/src/bin/synthetic_sender.rs` was added — no change
to the host, DLL, iOS app, or protocol.

## 2026-07-06: TODO — live end-to-end verification (everything is merged + rebuilt)

State as of this update: `main` (b3ba5dc) contains ALL recent work — the quality/
stability pass (1080p default, pinned bitrate, `maintain-resolution`, DLL buffer
reuse), the in-app 60fps toggle, the stale-frame signal-lost overlay, the RTCP PLI
keyframe request, native in-process WebRTC receive, and start.ps1 DLL auto-reinstall.
Working tree is clean; no unmerged branches remain (the `host-stale-frame-fallback`
and `host-webrtc-keyframe-request` branches landed as commits 3bcc3b4 and def22ea).
The iOS app was REBUILT on the Mac on 2026-07-05, so the phone binary now carries the
1080p default, encoding-parameter/bitrate work, 60fps toggle, landscape orientation,
and wake-lock/reconnect. So nothing is code-blocked anymore — the only thing left is
to confirm the whole stack works live with the rebuilt app. (Deferred: user was
travelling and couldn't test.)

DEPLOY GOTCHA to fix before testing: the machine-wide DLL is STALE. Deployed
`C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.dll` was 226,304 bytes /
17:58, while the current `source\bin` build is 232,960 bytes / 23:00 — real apps load
the ProgramData copy, so they'd run old code (no stale overlay etc.) until redeployed.
Run `.\start.cmd -Rebuild` (self-elevates, reinstalls the DLL, registers all-users/
system, runs the host). If a real app still shows old behaviour, svchost is holding
the old module — admin `Restart-Service FrameServer`.

LAN IP on 2026-07-05 was 192.168.1.227 (Wi-Fi) — RE-CHECK before testing
(`Get-NetIPAddress -AddressFamily IPv4`), it drifts when the PC changes Wi-Fi (this
is the recurring "frozen frame" cause). Phone must be on the SAME Wi-Fi; point the app
at http://<ip>:41003.

Verify in this one run (each item is COMPILED but NOT yet confirmed live with the
rebuilt app):
- Healthy host.log sequence: `answered phone offer as host-native` -> `peer
  connection state connected` -> `remote track added (video/H264)` -> `decode stats:`
  with backlog 0-1.
- Quality: picture stays full-res through a Wi-Fi blip instead of going soft
  (bitrate pin + maintain-resolution) and 1080p is the default stream.
- 60fps: enable Settings > Streaming > 60 fps, confirm the target app actually paces
  at 60 (caveat: nominal MF_MT_FRAME_RATE stays 30, so an app that ignores the
  fps range stays at 30 — see the 60fps note below for the fix if so).
- Stale overlay: let the stream drop, camera should show the red signal-lost overlay
  within ~3s (`stream STALE age=...ms`) then clear on reconnect (`stream RECOVERED`).
- Keyframe PLI: force a network blip, expect `requested keyframe (PLI)` in host.log
  and the decode errors STOPPING instead of freezing forever.

After this passes, the next real projects (no phone dependency) are: persistent
hands-off all-users/System camera registration that survives without a babysat
registrar window (new Teams needs it; also clean up the HKCU reg shadowing HKLM), and
auto-discovery of the host IP (mDNS/Bonjour or in-app host picker) to kill the stale-
saved-IP freeze for good.

## 2026-07-05: in-app 60fps option (branch `stream-60fps-option`)

## 2026-07-05: in-app 60fps option (branch `stream-60fps-option`)

New user-facing setting: Settings > Streaming > "60 fps" toggle. Default is 30fps
(60 is opt-in). At a fixed bitrate 60fps halves the bits/frame, so it trades
sharpness for smoothness — hence opt-in, not default.

iOS app (needs an Xcode rebuild on the Mac to reach the phone):
- `AppModel.highFrameRate` (persisted in UserDefaults, key `highFrameRate`,
  defaults false=30fps) + `targetFps` computed (30/60). `applyWebRTCConfig` gained
  an `fps` arg so the WebView can report it back.
- `WebRTCSenderView` gained `initialFps`; seeds `window.__initialFps`. The
  `onConfig` callback + Coordinator are now `(facing, quality, fps)`.
- Sender JS: `currentFps` drives the getUserMedia `frameRate` constraint AND
  `encodings[0].maxFramerate` in applyEncodingParameters; reported back via the
  config message. No in-page fps button — it's a Settings choice, applied on the
  next stream start.
- SettingsView: a `Toggle` bound to `highFrameRate` + a "Frame rate" info row.

Virtual-camera DLL (`iphone_camera_source.cpp`, built clean):
- Added `MAX_FRAME_RATE = 60` and set `MF_MT_FRAME_RATE_RANGE_MIN = 30` /
  `MF_MT_FRAME_RATE_RANGE_MAX = 60` on every media type. Nominal `MF_MT_FRAME_RATE`
  stays 30 ON PURPOSE, so apps that take the default type are UNCHANGED (Discord is
  verified against 30fps type 0) — but the camera now advertises up-to-60 capability.

VERIFY LIVE (not yet done, no phone this session): with 60fps enabled and the
rebuilt app, confirm the target app actually runs at 60. CAVEAT: because nominal
stays 30, an app that ignores the frame-rate range and just takes the default type
will still pace at 30 (phone sends 60, DLL serves newest-of-two). If a target app
does that and you want true 60 there, the next step is either flipping nominal
`MF_MT_FRAME_RATE` to 60 (small Discord-regression risk) or exposing dedicated
60fps media types alongside the 30fps ones. Deploy needs `install-machine.ps1` +
admin `Restart-Service FrameServer` for real apps (in-process probes pick it up
without a restart).

## 2026-07-05 late: quality + stability pass ("lagging + quality dropped")

Root cause of the quality drop: the sender (WebView JS in ContentView.swift) called
`addTrack` but NEVER set encoding parameters, so WebRTC's default congestion control
ran with degradationPreference `balanced` — which drops RESOLUTION at the first hint
of packet loss (always present on Wi-Fi) and ramps back slowly. On a LAN with
bandwidth to spare that meant needlessly downscaled video. Lag: the host was run as a
DEBUG build under plain `cargo run`, and the DLL `new`/`delete`d a ~3.7MB buffer every
RequestSample (~110MB/s alloc churn at 30fps).

Changes (all compile: DLL `build.ps1` clean, host `cargo check` clean):

- **Sender bitrate pinned + no resolution downscaling** (the big quality win).
  `ios-app/.../ContentView.swift` senderHTML: new `applyEncodingParameters(sender)`
  sets `encodings[0].maxBitrate` (10Mbps@1080p / 5Mbps@720p), `maxFramerate=30`, and
  `degradationPreference='maintain-resolution'`. Called after `addTrack` in start()
  and after `replaceTrack` in applyCameraChange() (the 1080<->720 toggle changes the
  target). The host web `/phone` page (`webrtc_http.rs`) got the same for parity
  (Edge fake-cam testing). REQUIRES AN XCODE REBUILD ON THE MAC to reach the phone.
- **1080p is now the default** (`AppModel.swift` selectedPreset = .hd1080p30). Same
  Mac rebuild caveat.
- **Host runs RELEASE by default** (`start.ps1`): `-Release` switch removed, added
  `-Debug` opt-out. Debug openh264 decode + YUV->RGBA + latest.rgba write couldn't
  always sustain 720p30. `.\start.cmd` now builds/runs optimised automatically.
- **DLL reuses per-frame scratch buffers** (`iphone_camera_source.cpp`): `fileScratch_`
  / `fitScratch_` `std::vector<BYTE>` members replace the per-RequestSample new/delete
  (MF serializes sample requests per stream, so a single buffer per stream is safe).
  Removes the ~110MB/s alloc churn in whatever process hosts the camera. `<vector>`
  added to includes.

DEPLOY to make these live:
- Host: just `.\start.cmd` (release now). No extra step.
- DLL: rebuilt into `source\bin`. To reach REAL apps it needs
  `install-machine.ps1` + an admin `Restart-Service FrameServer` (svchost keeps the
  old module loaded) — `.\start.cmd -Rebuild` does the install; the service restart is
  the usual admin step. In-process probes pick up the new DLL with no restart.
- iOS app: Xcode rebuild on the Mac (sender JS + default preset live in the app bundle).

NOT yet verified live. To verify quality: stream from the (rebuilt) app, confirm the
picture stays at full res through a Wi-Fi blip instead of going soft. To verify lag:
run the host via start.cmd (release) and watch `host.log` `decode stats:` — backlog
should stay 0-1.

## 2026-07-05: `start.ps1` — one command to run everything

New repo-root script `start.ps1` collapses the whole test setup into a single
command. It is launched via a `start.cmd` wrapper (`.\start.cmd`) — running the
.ps1 directly is blocked by the machine's PowerShell execution policy
(`running scripts is disabled on this system`), but a .cmd is not, and it calls
`powershell -NoProfile -ExecutionPolicy Bypass -File start.ps1 %*`. Motivation:
the user should never have to remember the separate install / register / host
steps or the `-ExecutionPolicy Bypass` incantation.

What it does (see the header comment in the file):
- Self-elevates with a single UAC prompt (admin is required to register the camera
  for ALL users, which is what new Teams needs — see the Teams note in the backlog).
  Re-launches itself with `-NoExit` so the elevated window stays up.
- Prints the bare LAN IP to type into the iPhone app (DHCP IPv4, skips 169.254
  link-local, prefers Wi-Fi). Verified it resolves 192.168.1.227 on this machine.
- Ensures the machine-wide DLL is installed (`source\install-machine.ps1`); skips
  the build if `ProgramData\...\iphone_camera_source.dll` already exists unless
  `-Rebuild` is passed.
- Registers the camera all-users/system by launching `register_virtual_camera.exe
  start all-users system` HIDDEN with `-PassThru`, keeping the process handle.
- Runs the host (`cargo run -p windows-host`, `+ --release` with `-Release`) in the
  FOREGROUND so its log is what you watch.
- On Ctrl+C / exit, a `finally` block kills the registrar process and runs
  `register_virtual_camera.exe remove all-users system` to unregister the camera.

Switches: `-Rebuild` (force DLL rebuild+reinstall), `-Release` (optimised host).

Status: syntax-checked (PowerShell parser clean) and the non-elevated parts (IP
detection, admin check, all referenced exe/script paths, cargo on PATH) verified.
NOT yet run end-to-end through the UAC/elevation + registrar + host path — that
needs an interactive run. Known caveats to watch on first real run: (a) the host
now runs ELEVATED (cargo build/run as admin) — fine functionally, but if it ever
fights the target dir with a non-elevated `cargo check` from a dev session, that's
why; (b) `finally` teardown on Ctrl+C is reliable in most cases but not 100% — if
it's skipped, the camera stays registered and the next run (or `registrar\
run-remove.ps1`) cleans it up.

## Backlog / things to look at next

- **Per-frame CPU/allocation overhead in the DLL (efficiency).** Measured live
  while streaming to Discord: our `windows-host` is cheap (~2.5% CPU, 54 MB) — the
  high CPU + ~0.5 GB the user sees is DISCORD's own process (pid was at 52.8% CPU /
  505 MB), i.e. Discord re-encoding the outgoing video, which any webcam would
  incur. BUT our DLL does add real churn to whichever process hosts it: every
  `RequestSample` (30fps) it `new`/`delete`s a ~3.7 MB buffer
  (`iphone_camera_source.cpp` ~line 291, `fileBuffer`) and re-reads + RGBA→NV12
  converts the whole frame. Fix to do: reuse a persistent per-stream buffer instead
  of allocating each frame (~110 MB/s of alloc/free removed); consider caching the
  file read / SIMD-ing the NV12 conversion. Won't change the headline (Discord's
  encoder dominates) but removes the one genuine inefficiency in our code. Also:
  the host under `cargo run` is a DEBUG build — use `run-windows-host.ps1 -Release`
  for streaming.

- **New Teams doesn't see the camera (Zoom does). RESOLVED 2026-07-05.** Root cause
  (confirmed by registry): the MF source CLSID {7F812B6A-...} is registered in BOTH
  HKLM (→ ProgramData DLL) and HKCU (→ dev source\bin DLL), so the frame server loads
  it and Zoom (Win32) enumerates the CurrentUser/Session virtual camera fine. New
  Teams is a PACKAGED (MSIX/AppContainer) app and only enumerates cameras registered
  with `MFVirtualCameraAccess_AllUsers` (+ `System` lifetime). FIX CONFIRMED WORKING:
  register with `registrar\run-start-all-users-system.ps1` from an admin prompt
  (after `source\install-machine.ps1` so the HKLM/ProgramData DLL is current), keep
  that window open, and fully restart Teams (it caches the device list at launch).
  Teams then enumerates "iPhone Camera". So signing the DLL was NOT required — the
  scope was the whole issue. NOTE: the registrar's `start` still waits for Enter and
  Stops the camera on exit, so the camera only persists while that admin process is
  alive; for a hands-off setup we'd want a persistent System registration that
  doesn't tear down on exit. The dev HKCU registration shadowing the machine one for
  the current user is also worth cleaning up (run-remove then a single machine-wide
  install).

## 2026-07-05: RTCP PLI keyframe request — recover from mid-stream decode stalls

Branch: `host-webrtc-keyframe-request` (off `main` @ 65ccf08). Fixes the risk
flagged in the native-receive notes below: after a live session ran fine for ~12s
(`decode stats: decoded 423, written 362`), the openh264 decoder hit a wall of
`h264 decode error: ... Native:18` and wrote NO more frames until the connection
failed. Native:18 = 0x12 = `dsNoParamSets`(0x10) | `dsRefLost`(0x02): packet loss
broke the H264 reference chain, and since P-frames can't recover without a fresh
IDR — and iOS won't send one unprompted — every subsequent frame errored forever.

Fix (`windows-host/src/webrtc_native.rs`; host-only, no phone/DLL/protocol change,
`cargo check` clean apart from the pre-existing `latest_raw_frame` dead-code warn):

- The receiver now sends an RTCP PLI (Picture Loss Indication) to make the phone
  emit a fresh keyframe. `pump_track` gets a `Weak<RTCPeerConnection>` (Weak, not
  Arc — the on_track closure is owned by the pc, so a strong capture would be a
  reference-cycle leak) and spawns `request_keyframes`, which calls
  `pc.write_rtcp(&[PictureLossIndication{ media_ssrc: track.ssrc(), .. }])`.
- The decode thread sets a shared `want_keyframe` AtomicBool on every decode error;
  `request_keyframes` drains it at most once per 500ms (so a sustained stall can't
  flood the sender) and logs `requested keyframe (PLI) to re-sync decoder`.
- `want_keyframe` is seeded `true` and tokio interval's first tick fires
  immediately, so a PLI also goes out at track start — which additionally covers
  joining an already-running stream mid-GOP.

Status: COMPILES. NOT yet verified live — needs a phone stream that actually drops
packets to trigger a ref loss. To verify: stream from the phone, and either let it
run through a network blip or force one; watch host.log for `requested keyframe
(PLI)` followed by the `decode error` lines STOPPING and `decode stats: written`
climbing again (instead of freezing until `peer connection state failed`). The
in-camera symptom of the OLD behaviour was the stream freezing; with the stale-
frame overlay branch it would instead go to the signal-lost overlay after 3s.
## 2026-07-05: stale-frame "signal lost" overlay — stalls are now visible in-camera

Branch: `host-stale-frame-fallback` (off `main` @ 65ccf08, after the native
receiver landed). Motivation: the recurring "frozen frame again" reports were
almost never host bugs — the phone drops (subnet change, stale saved IP, iOS
Local Network permission), the host stops writing `latest.rgba`, and the virtual
camera happily serves the last good frame FOREVER, so it looks frozen. This makes
the stall self-evident in every consuming app.

DLL-only change (`windows-virtual-camera/source/iphone_camera_source.cpp`); NO
host or protocol change, so the host/frame contract cannot regress:

- `LoadSharedRgba` now also returns the shared file's age, computed from
  `GetFileTime`(last write) vs `GetSystemTimeAsFileTime` (same UTC system clock,
  so the delta is valid; a future timestamp clamps to age 0).
- If the last good frame is older than `STALE_FRAME_THRESHOLD_MS` (3000 ms, matches
  the host's own 3s raw-frame stall threshold), `RequestSample` composites
  `ApplyStaleOverlay` onto the frame in place: darken to ~30%, a pulsing red
  border, and a centred red no-signal glyph (ring + diagonal slash). `GetTickCount64`
  drives the pulse so it reads as live-but-stalled, not a frozen picture. The
  overlay writes into our own heap buffer (fileBuffer/fitBuffer) BEFORE NV12/RGB32
  conversion, so both output formats and both orientations get it for free.
- Self-heals: the moment the host writes a fresh frame, age drops below the
  threshold and live video returns. Transitions log once each way
  (`stream STALE age=...ms` / `stream RECOVERED`).

Status: COMPILES (`build.ps1` clean). VERIFIED HEADLESSLY: with the existing stale
`latest.rgba` (~4.8h old), `probe_source_reader.exe 0 <dump>` logged
`stream STALE age=17440784ms, showing signal-lost overlay` and the dumped NV12
frame checks out at the pixel level — the top/bottom/left/right border pixels and
both the glyph ring and the diagonal slash all read chroma U≈109 V≈183 (pure red),
while interior content reads U≈126 V≈129 (near-gray, darkened original). NOTE: the
probe loads the DLL registered under HKCU (source\bin), so its log is
source\bin\iphone_camera_source.log, NOT the ProgramData one (svchost's).
NOT yet verified end-to-end through the frame server in a real app (needs an admin
`Restart-Service FrameServer` so svchost picks up the new DLL, then let a live
stream drop and watch the camera show the overlay, then reconnect and watch it
clear).

## 2026-07-05: native in-process WebRTC receive — kills the browser receiver

Branch: `host-native-webrtc-receive` (off `main` @ c99c793). This is the durable
fix flagged repeatedly below: the host now receives the WebRTC video track
itself, in-process, with NO browser tab. That collapses five recurring failure
categories at once — nobody clicking "Start bridge", Edge suspending/ freezing
background tabs, the renderer OOM-kill near frame ~2000 (getImageData GC
starvation), zombie-tab answer hijacking, and pc-disconnected churn — because
none of them have a browser to happen in anymore.

Design (phone client and virtual-camera DLL are UNCHANGED — same signaling
protocol, same latest.rgba contract):

- New crate dep: `webrtc = "0.17.1"` (already used transitively for the RTP
  types; now used for the full peer connection). Adds a large dependency tree;
  first `cargo build` is slow but `cargo check` is clean (one pre-existing
  dead-code warning only).
- New module `windows-host/src/webrtc_native.rs` (`NativeWebRtcReceiver`): builds
  an `RTCPeerConnection` with default codecs+interceptors, answers the phone's
  offer, trickles ICE, and on the incoming H264 track reassembles access units
  (depacketize via `rtp::codecs::h264::H264Packet`, flush on the RTP marker bit)
  and decodes them on a dedicated std thread (openh264 `Decoder`, mirroring
  preview.rs since the decoder isn't happy across awaits). Decoded YUV → RGB8 →
  RGBA → `preview.submit_raw_rgba_frame(...)`, which writes latest.rgba exactly
  like the old browser bridge POST did. The decode thread uses a captured tokio
  `Handle::block_on` to call the async submit.
- `webrtc_http.rs` now drives the native receiver from the existing signaling
  endpoints, so the phone sees no protocol change:
  - POST /signal/offer → `native.accept_offer()`; the returned answer is stored
    as the winning answer tagged `host-native`, so GET /signal/answer serves it
    to the phone unchanged.
  - POST /signal/candidate/phone → fed straight into the native pc (buffered if
    it races ahead of the offer) AND still buffered for a browser fallback.
  - GET /signal/candidates/receiver → serves the host's gathered local
    candidates when a native session is active; else the old browser path.
  - POST /signal/reset → tears the native pc down.
- Graceful fallback: if the WebRTC stack fails to init, `native` is `None` and
  the server logs a warning and behaves exactly like the old browser-receiver
  host. The /receiver page still exists and its answers are simply ignored while
  a native session owns the `host-native` winner slot (arbitration already
  handled zombie tabs), so an open /receiver tab is now inert, not harmful.

Status: COMPILES (`cargo check -p windows-host` clean). NOT yet verified live —
needs a phone (or Edge fake-camera /phone sender) to POST a real offer so the
native pc negotiates and a track flows. To verify:

1. `cargo run -p windows-host` (no browser /receiver needed anymore).
2. Phone: open http://<windows-ip>:41003/phone in the app, Start WebRTC stream.
3. Watch host.log for: `native webrtc: answered phone offer as host-native`,
   `native webrtc: peer connection state connected`, `native webrtc: remote
   track added (video/H264)`, then the raw-frame watchdog `raw bridge frames
   FLOWING`. Check `latest.rgba` LastWriteTime advances and /virtual-camera/status
   shows raw_frames_ready.

Known risks to check first if no video: (a) H264 codec/fmtp negotiation — iOS
offers a specific profile-level-id; if webrtc-rs's default H264 registration
doesn't match, no track fires (`remote track added` never logs) and we'd need to
register the phone's exact H264 params in the MediaEngine. (b) The decode thread
expects the first access unit to carry SPS/PPS/IDR (iOS does send them inband).
Rate-limited `native webrtc: h264 decode error` lines would show a decode
mismatch. (c) `on_track` only decodes `video/H264`; a VP8 fallback would be
skipped with a warning.

### VERIFIED LIVE 2026-07-05 + lag fix

The native receive worked out of the box on the first live run (phone offer →
host answers → track flows → latest.rgba updates) but drifted 30-60s BEHIND the
camera. Cause: the first decode_loop played the stream faithfully instead of
latest-wins. Every access unit went through an unbounded channel into
decode + RGBA-convert + 3.7MB latest.rgba write; whenever that pipeline runs
slower than the 30fps arrival rate the backlog (and therefore latency) grows
without bound. The old browser bridge never showed this because its inFlight
guard dropped frames when behind — it was accidentally latest-wins.

Two fixes on `host-native-webrtc-receive` (both in place, `cargo check` clean):

1. decode_loop is now latest-wins (webrtc_native.rs): it drains the channel,
   DECODES every access unit (H264 P-frames need the reference chain, so frames
   cannot simply be dropped pre-decode) but converts + writes ONLY the newest
   decoded picture; older ones are counted as "skipped stale". Also switched
   write_rgb8 + manual alpha pass to openh264's SIMD write_rgba8 (one pass).
   A 10s stats line logs decoded/written/skipped/backlog. If backlog GROWS while
   skips are happening, DECODE itself can't keep up — that would need drop-to-
   next-IDR + a PLI request, not yet implemented.
2. Workspace Cargo.toml: `[profile.dev.package."*"] opt-level = 2`. Under plain
   `cargo run` (debug), openh264's C code and the YUV→RGBA conversion compiled
   at -O0 and plausibly couldn't sustain 720p30 decode at all, which no amount
   of write-skipping can fix. Dependencies now build optimized even in dev;
   first rebuild after this change is slow (full dep recompile), workspace-crate
   iteration stays fast.

Retest: restart the host, stream from the phone, and check the
`native webrtc: decode stats:` lines — healthy is backlog 0-1 and skipped
staying near-flat; lag at the camera should be sub-second. If skipped climbs
steadily but backlog stays ~0, the write path is just slower than 30fps (fine —
output fps degrades gracefully, latency stays low).



## 2026-07-05 midday: "frozen frame again" = PC changed subnets, phone never reached the host

Diagnosis (no code change needed; native-receive host was healthy the whole time):
latest.rgba was frozen at 01:20:58 local — the exact moment last night's phone
connection reset (10054, frames STOPPED at seq 634). The virtual camera serves
that last frame forever, hence the frozen image. After today's 12:56 host
restart, host.log showed heartbeats but ZERO phone signaling — the documented
"dropped before the host" signature. Cause: the PC's Wi-Fi is now on
192.168.50.238 (192.168.50.x subnet, gateway 192.168.50.1), while the phone was
last at 192.168.1.212 on the old 192.168.1.x network, which no longer pings.
The app's saved host IP (192.168.1.227) is therefore dead.

Fix checklist when this signature appears (host heartbeats + no phone signaling):
check the PC's current IP (`Get-NetIPAddress -AddressFamily IPv4`), make sure
the phone is on the SAME Wi-Fi network, and point the app at the CURRENT host
IP — today that is http://192.168.50.238:41003/phone. A zombie /receiver tab
from a previous session may still post heartbeats ("posted N frames" never
increasing); it is inert under host-native arbitration and can be closed.

## Standing workflow preference

When moving completed branch work into `main`, ALWAYS use a pull request
workflow: push the feature branch, create a PR into `main`, verify/merge the PR,
then update local `main` from the merged result. Treat user shorthand like
"merge", "commit to main", "land it", "full commit", or similar as a request to
complete that PR workflow, NOT as permission to push directly to `main`. Only
merge/push directly to `main` if the user explicitly says to bypass PRs, skip the
PR, or direct-push.

2026-07-05: `IOS-Redesign` was merged directly into `main` and pushed as
commit `4bb43d6` (`Merge IOS redesign`). Future similar requests should use the
PR workflow above unless told otherwise.

2026-07-05: `host-native-webrtc-receive` was also fast-forwarded directly into
`main` and pushed as commit `65ccf08` (`Receive WebRTC video natively in host`)
after the user said "run a full commit to main etc". This should NOT be repeated:
that phrasing should still trigger the PR workflow above.

## 2026-07-04 afternoon: host-death investigation + black-box logging added

Two "crashes" were reported; they turned out to be different things:

1. ~13:52:28 local: the user's cargo-run host genuinely died right after a 10054
   WARN from the phone. That WARN path is a spawned task and cannot exit the
   process (verified: all four accept loops log-and-continue, all handlers are
   tokio::spawn'ed). No WER/Application Error crash record, no Defender
   detection. CAUSE STILL UNKNOWN — the terminal text below the WARN was never
   captured. This is the one to catch with the new instrumentation.
2. ~14:02:45: a Claude-restarted detached host exited 0xffffffff — that is just
   the Stop-Process/TerminateProcess signature (it was killed so the user's own
   cargo run could bind), not a crash. The user's replacement host (started
   14:02:48, elevated) then STAYED ALIVE while bridge frames froze at seq 2089
   at 14:04:31, ~100s after streaming started — i.e. a phone/receiver-side
   stream drop, consistent with the still-pending iOS rebuild (no wake lock /
   no auto-reconnect in the installed app; keep iOS Auto-Lock on Never).

NEW black-box instrumentation in the host (compiles; NOT yet running — the
elevated host from 14:02:48 held the exe lock, so the user must Ctrl+C their
cargo window and re-run `cargo run -p windows-host`):

- main.rs: tracing now ALSO appends (ansi-free) to
  C:\ProgramData\IPhoneCameraStreaming\host.log regardless of how the host is
  launched; a global panic hook writes message+backtrace to host-crash.log AND
  host.log (panics in tokio::spawn'ed tasks were previously swallowed
  silently); app.run() errors are logged to both before exit. Crash-file
  timestamps are epoch seconds; host.log timestamps are UTC (local is +1).
- app.rs: watch_raw_frames task — logs "raw bridge frames FLOWING/STOPPED"
  transitions (3s stall threshold, exact timestamps for stream drops) and a
  60s "heartbeat" line so a silent process death is bounded to the minute.
- webrtc_http.rs: POST /signal/reset now logs (other signaling POSTs already
  did), so phone session starts are visible in the log trail.

After the next failure, read: host.log tail (heartbeats bound a process death;
FLOWING/STOPPED lines timestamp stream drops; signaling lines show reconnect
attempts) and host-crash.log (panic backtraces). If the host dies with NO
panic in host-crash.log and heartbeats just stop, the killer is external —
check WER/System event logs and what terminal it ran in.

Stale artifacts: host-run.log / host-run.err.log in ProgramData were the
one-off Start-Process redirect from this session; superseded by host.log.

### DIAGNOSED via the new black box: stream drops = receiver tab suspension

First instrumented run (13:16Z) captured a drop end to end: frames flowed at
~28fps for 78s, STOPPED at 13:18:12Z with the host healthy; the phone's
connection reset 24s later, the phone auto-recovered and posted a FRESH offer
at 13:18:53Z — and the receiver page never answered it. The receiver tab had
been suspended by the browser (Edge sleeping tabs/freezing), which kills the
bridge ticker, the signaling polls, and the WebRTC peer all at once. This
matches the known "background Edge windows go to sleep" trap, now confirmed
as THE cause of the recurring "stream just stops" reports.

Fixes (webrtc_http.rs, receiver page + host; compiles, needs host restart AND
a reload of any open /receiver tab to pick up the new page JS):

- POST /client-log endpoint: pages mirror lifecycle events into host.log as
  "client[receiver <id>]: ...". Freeze/pagehide reports use fetch keepalive so
  they escape before the browser suspends the tab — a "TAB FROZEN by browser"
  line in host.log is now the definitive signature.
- Receiver page logs: page load, visibility changes, freeze/resume, pagehide,
  pc connection state changes, track attached/ended, bridge starts, answers.
- keepAwake() on the bridge buttons: a near-silent WebAudio oscillator
  (audible tabs are exempt from Edge tab sleep/freeze) + screen wake lock.
- Self-heal: after resume/foreground, if the pc is dead the page clears
  lastOfferKey and re-answers the outstanding offer (previously it would wait
  forever because the offer key hadn't changed).

Belt-and-braces user setting: edge://settings/system → "Save resources with
sleeping tabs" → add 127.0.0.1 to "Never put these sites to sleep" (or turn
sleeping tabs off) on the machine running the receiver page.

Remaining unexplained: only the very first host death at ~13:52 local. If it
recurs, host-crash.log / heartbeat gap will identify it.

### Phone "Signal request failed with status 599 / timed out" = phone-side drop

Seen 2026-07-04 ~15:00: host healthy and answering locally, receiver page
logging fine, but ZERO phone signaling in host.log and zero TCP connections
from the phone on 41003 — the phone's packets never arrive at the PC.

Ruled OUT on the PC side (in order tried): Windows Firewall profile scoping
(first theory — the Wi-Fi had flipped to Public at 13:10 local after a blip
and the port rules are Private-only — but it turned out Windows Firewall is
DISABLED on Private+Public profiles entirely, so it filters nothing; note
that's also a security finding for later). No program-based allow/block rules
for windows-host.exe exist. Host listens on 0.0.0.0:41003. PC pings the phone
(192.168.1.212) fine, which also rules out router client isolation.

=> The drop is ON THE PHONE: prime suspects are the iOS Local Network
permission for the app (silently times out exactly like this when off —
Settings > Privacy & Security > Local Network), a VPN on the phone, or the
app targeting a stale host IP (PC is 192.168.1.227). Decisive triage: open
http://192.168.1.227:41003/phone in SAFARI on the phone — if it loads, the
network is fine and the native app (permission/saved IP) is the problem.

CONFIRMED 2026-07-04 ~15:20: Safari on the phone DID load /phone, so the
network path is fine and the native app's timeout is app-local. BUT the
Safari page cannot actually send: "undefined is not an object (evaluating
'navigator.mediaDevices.getUserMedia')" — iOS Safari only exposes
getUserMedia in SECURE contexts, and http://<lan-ip> is not one (PC-side
Edge tests never hit this because 127.0.0.1 counts as secure). So the web
sender page is NOT usable from a real phone over plain HTTP — earlier notes
suggesting "test rotation with the web sender page on the phone" are wrong
unless the host gains HTTPS (self-signed cert the phone trusts) or the iOS
Safari feature flag for insecure media capture exists and is enabled. The
native app is unaffected by this (WKWebView is granted capture by the app).

Diagnosis shortcut for next time: host.log heartbeats + no "phone reset
signaling" on a connection attempt = dropped before the host (phone/VPN/
network), not host code. (That incident resolved on the phone side; the app
reconnected at 13:58Z.)

### Second drop signature: receiver tab dies near bridge frame ~2000

With the app reconnected, a fully instrumented drop was captured at 14:00:39Z:
pc state connected, keep-awake audio running, tab visible, NO freeze/pagehide
event — and the page stopped executing JS entirely (the phone re-offered at
14:00:49Z and 14:01:49Z; the receiver, which polls /signal/offer every 500ms,
never answered). Across three drops the bridge died at frame seq 2037, 2089,
2036 — COUNT-correlated, not time-correlated. Working theory: Edge renderer
crash/kill from allocation churn (~3.7MB ImageData per frame at 30fps, plus a
canvas realloc every tick because canvas.width was assigned every frame).

Mitigations added (webrtc_http.rs receiver page + host, needs host restart +
receiver page reload):

- Canvas only resized on real dimension change (assigning width clears and
  reallocates even when unchanged).
- postRawFrame has a 5s AbortController timeout and counts postedFrames — a
  hung fetch can no longer wedge inFlight forever.
- Self-heal: bridge watch ticker reloads the page if posts stalled >8s while
  pc is still connected; sessionStorage autoRawBridge=1 restarts the bridge
  after any reload (keep-awake audio may stay 'suspended' without a gesture —
  the log line now records the AudioContext state).
- Page heartbeat every 30s to /client-log: rawBridge flag, postedFrames, JS
  heap used/total (performance.memory) — will confirm or kill the memory
  theory on the next drop.
- Host: GET /signal/offer updates a receiver-liveness timestamp
  (webrtc_http::last_receiver_poll_age_secs); the frame watchdog's STOPPED
  warning and the 60s heartbeat now report the poll age, separating "tab
  dead/suspended" (stale polls) from "bridge stalled in a live tab" (fresh
  polls). NOTE: a reload/self-heal cannot fix a crashed tab — if the STOPPED
  warning shows a stale poll age, the user must manually reload /receiver.
  The durable fix is moving WebRTC receive into the host natively (no
  browser), which is a larger project.

### SOLVED (evening): frame-~2000 tab death = GC starvation from getImageData

The 20:xx UTC run's page heartbeats nailed the memory theory: js heap went
2MB (frame 812) -> 68MB (1384) -> 423MB (1964), then the tab died at seq 2045
with stale signaling polls — Edge OOM-killed the renderer. Root cause:
ctx.getImageData() allocates a fresh ~3.7MB ImageData EVERY frame (~110MB/s
at 30fps); V8's major GC needs main-thread idle time that the 33ms
capture/post loop never yields, so reclamation falls further behind each
cycle until the heap limit. Count-correlated (~2000 frames = ~7GB cumulative)
because it is cumulative allocation, not elapsed time.

Fix (webrtc_http.rs receiver page; needs host restart + receiver tab reload):

- Raw bridge capture rewritten to WebGL: video -> texImage2D -> fullscreen
  triangle -> gl.readPixels into ONE preallocated Uint8Array (the 2d canvas
  API has no read-into-existing-buffer call; readPixels does). Steady-state
  JS allocation per frame is now zero. The shader's plain y-mapping renders
  the frame upside down in the framebuffer, cancelling readPixels' bottom-up
  row order — verified in headless Edge with a red-top/blue-bottom pattern
  (top-left lands at offset 0, RGBA order, buffer coherent across grabs).
- Reusing one buffer is safe: fetch snapshots BufferSource bodies at call
  time, and the inFlight guard serializes posts anyway.
- Old getImageData path kept as fallback if WebGL is unavailable, and the
  grabber is recreated on webglcontextlost.
- postRawFrame now drains the response body so requests are released eagerly
  instead of waiting for GC finalization.
- Page heartbeat now reports the capture mode: "rawBridge=true (webgl)".
  If a heartbeat ever says "(2d)", the OOM risk is back.

Verify on next run: heartbeats should show js heap staying flat (tens of MB,
not climbing) and the bridge should sail past frame 2100. If the heap still
climbs in webgl mode, the leak is elsewhere and the heartbeat trail will
show it.

## 2026-07-04: rotation-aware landscape streaming (host + DLL, verified headlessly)

New feature: the camera now follows the phone's rotation. The receiver bridge already
posts the track's true dimensions per frame, so orientation is detected from the
incoming aspect ratio — no new signaling.

Shared frame contract CHANGED (host and DLL must be deployed together):

- latest.rgba = 16-byte header + tightly packed RGBA. Header: magic "IPCF", then
  width, height, stride as LE u32. Landscape input -> 1280x720 frame, portrait ->
  720x1280. Both are exactly 3,686,400 pixel bytes, so the file length is constant
  (3,686,416) and the in-place-overwrite fallback still can't leave a short file.
- Host (preview.rs): picks the orientation per frame, aspect-FITS with black bars
  (no more stretching), writes the header. fit_rgba_nearest replaced
  resize_rgba_nearest.
- DLL (iphone_camera_source.cpp): parses the header; headerless 3,686,400-byte files
  still work (legacy portrait). Exposes FOUR media types: NV12 720x1280 (type 0,
  unchanged default — Discord verified against it), NV12 1280x720, RGB32 720x1280,
  RGB32 1280x720. SetMediaType/SetCurrentMediaType honor size + subtype; the stream
  tracks outputWidth_/outputHeight_. FillFrame aspect-fits whatever the file contains
  into whatever the app negotiated, so mid-stream rotation just re-letterboxes — the
  negotiated output type never changes (MF can't renegotiate mid-stream anyway).

probe_source_reader.exe was extended: `probe_source_reader.exe [nativeTypeIndex]
[dumpPath]` selects a native media type and dumps the 5th sample; it also prints
lumaMin/Max/Avg. scratchpad script nv12-to-png.ps1 (this session) rendered dumps for
visual checks.

Verified 2026-07-04 (headless, Edge fake camera -> receiver -> raw bridge):

- Host writes IPCF 1280x720 for the landscape fake stream; a hand-posted 360x640
  frame flipped the header to 720x1280 and the bridge flipped it back — per-frame
  rotation switching works live.
- All four media types produce samples in-process. Landscape output of landscape
  content fills the frame (lumaMin=83, no bars); portrait output letterboxes it
  (lumaMin=16 bars, content centered). Confirmed visually from dumped frames.
- NOT yet verified: end-to-end through the frame server / real apps — blocked on the
  FrameServer service restart below.

iOS app: Info.plist was PORTRAIT-LOCKED (UISupportedInterfaceOrientations), which
freezes the camera track orientation no matter how the phone is held — rotation would
never reach the receiver from the native app. Added LandscapeLeft/Right to the plist
(project uses GENERATE_INFOPLIST_FILE=NO, so the plist is authoritative). REQUIRES an
Xcode rebuild on the Mac, same as the still-pending 2026-07-03 wake-lock/reconnect
rebuild. The web /phone page needs no change (Safari rotates the track when the page
isn't app-locked). Until the rebuild, rotation can be tested with the WEB sender page
on the phone.

### Windows Camera black preview: allocator fix confirmed working, NEW diagnosis

The 2026-07-03 allocator-path DLL was confirmed live in the frame server (svchost PID
23804) and a headless Camera app run captured the failure precisely:

    13:22:02.427 Start -> MENewStream -> InitializeSampleAllocator hr=0x0
    13:22:02.431 RequestSample #1 ... #10 served from the live shared frame (~16ms apart)
    13:22:02.774 SetStreamState state=0 (Camera app STOPS the stream itself)

So allocator, event order, and live frames are all fine — the Camera app consumes 10
samples in 350ms, then deliberately stops the stream and shows black. Remaining
suspects unchanged (in order): remove MF_DEVICESTREAM_FRAMESERVER_SHARED from the
stream descriptor + stream attributes; try RGB32/landscape as the default type;
compare against a physical camera's negotiation sequence in the same log format.
Discord was NOT retested this session (needs the service restart below first).

### Deploy state RIGHT NOW (2026-07-04 end of session)

- New host code: built and RUNNING (cargo run -p windows-host).
- New DLL: deployed to C:\ProgramData\IPhoneCameraStreaming (old file renamed aside
  as iphone_camera_source.old.dll) and in source\bin. HKCU CLSID InprocServer32
  points at source\bin.
- BUT the FrameServer service (svchost) still has the OLD 2026-07-03 module loaded —
  it refused to idle-stop for 3+ minutes with all camera sessions closed, and
  restarting it needs admin. UNTIL AN ADMIN RESTARTS FRAMESERVER, apps get the old
  DLL, which reads the new headered latest.rgba as garbage (shifted pixels). Run as
  admin:

    Restart-Service FrameServer

  or the usual install-machine.ps1 flow. Then retest: Windows Camera (expect either
  video or the same 10-samples-then-stop signature), then Discord (expect landscape
  1280x720 negotiation now that it's offered).
- The session registrar and test Edge windows were stopped/left as-is; re-register
  with register_virtual_camera.exe start (no admin) for headless testing.

Headless test loop used this session (all no-admin): Edge with
--use-fake-device-for-media-stream/--use-fake-ui-for-media-stream on /receiver +
/phone, UIAutomation clicks the page buttons, probe_source_reader exercises the DLL
in-process (fresh process = fresh DLL, no service restart needed), Camera app driven
via SwitchCameraButtonId + CopyFromScreen screenshots. NOTE: background Edge windows
get put to sleep after a few minutes and the bridge freezes — bring the receiver
window to the foreground (or reopen /receiver) before relying on it.

## 2026-07-03 Update 3: host crash under bridge load — fixed; candidate race — fixed

Discord DID show the live stream (pipeline confirmed end to end), then died after ~30s with
receiver "Failed to fetch" and the whole host process gone. Two independent bugs found and
fixed in the host:

1. FATAL ACCEPT PATTERN: all four servers (control 41000, video 41001, preview 41002,
   webrtc 41003) did `listener.accept().await?` inside their loop, and app.rs runs them under
   tokio::try_join! — ONE transient accept error anywhere exited the entire process. With the
   raw bridge opening ~30 connections/sec (every response was Connection: close), a transient
   socket error eventually landed. All four accept loops now log-and-continue, and the WebRTC
   HTTP server speaks keep-alive (connections reused; 60s idle timeout; per-connection reused
   8MB buffer). Verified by soak: hundreds of bridge posts + idle keep-alive sockets, host
   stayed alive and responsive.

2. CANDIDATE WIPE RACE (root cause of "answer sent, waiting for video" flakiness since the
   beginning): the phone's trickle ICE candidates can arrive a millisecond BEFORE its offer
   (separate HTTP requests, ordering not guaranteed — observed in the host log), and the offer
   handler cleared phone_candidates, so the receiver never learned how to reach the phone.
   Candidates are now cleared only on /signal/reset, which phone clients always send before
   creating their peer connection.

Also confirmed this session: the "Discord black screen" was NOT a camera bug — latest.rgba was
a literally black frame (RGB 0,0,0, alpha 255) written by the bridge while the receiver video
was black. The new allocator-path DLL reproduced it faithfully (uniform NV12 luma 16 == black;
probe_device_reader.exe now prints lumaMin/Max/Avg to catch this instantly). The allocator path
is confirmed active in the frame server: SetDefaultAllocator called, InitializeSampleAllocator
hr=0x0, samples flow, no fallback.

Note the virtual camera stays fully alive when the host dies — it just serves the last shared
frame forever. A "host heartbeat → fallback pattern after N seconds of stale latest.rgba"
would make host death visible in-camera; not implemented yet.

## 2026-07-03 Update 2: "receiver stuck waiting for video" — multi-receiver signaling fix

Symptom after the stability changes: phone says "Streaming to Windows over WebRTC", receiver
says waiting, black screen, no frames reach the host. Reproduced locally with an Edge instance
using --use-fake-device-for-media-stream/--use-fake-ui-for-media-stream driving /phone and
/receiver, then inspected /signal/candidates/receiver: the candidate list contained TWO
different ICE ufrags, i.e. two receiver pages were answering the same offer. The signaling
design had a single last-writer-wins answer slot, so a stale receiver tab (still polling from
an earlier session/host run) could hijack the answer while the visible receiver waited forever.
This is very likely what "the stream doesn't run anymore" was.

Fix (webrtc_http.rs; final design after one iteration): the HOST arbitrates receivers, so
phone-side clients keep speaking the old plain protocol. This matters because the iPhone is
using the NATIVE APP (ios-app), which embeds its own copy of the sender JS inside
ContentView.swift (senderHTML) — a first version that broke old clients surfaced in the app as
"Member RTCSessionDescriptionInit.type is required and must be an instance of RTCSdpType".

- Receiver pages generate a random receiverId and post { id, answer } to /signal/answer and
  { id, candidate } to /signal/candidate/receiver. Untagged posts (stale receiver tabs running
  old page code) are IGNORED by the host — zombie tabs can no longer hijack the stream.
- The host picks the FIRST valid tagged answer as the winner (answer_winner), re-accepts
  updates from the same id, ignores others. GET /signal/answer returns the winner's answer as
  a plain { type, sdp, id } object (the extra id key is ignored by setRemoteDescription, so the
  UNCHANGED iOS app consumes it fine). GET /signal/candidates/receiver returns only the
  winner's candidates, flattened to plain candidate objects.
- GET /signal/answer/ack returns { id: winnerId }; receiver pages poll it after answering and
  stand down with a visible message if another receiver won. POST /signal/answer/ack is now a
  legacy no-op.

ios-app/IPhoneCamSender/ContentView.swift was ALSO updated (requires an Xcode rebuild on the
Mac to take effect — the app binary on the phone still runs the old embedded JS until then):

- UIApplication.shared.isIdleTimerDisabled while the WebRTC sender sheet is open (WKWebView has
  no navigator.wakeLock; iOS auto-lock at ~30s was almost certainly the "cuts after 30 seconds"
  report, since the user streams from the APP, not the Safari phone page).
- Embedded sender JS got the same auto-reconnect logic as the web phone page (restart on
  failed/closed, on 4s of disconnected, on track ended, on visibility resume).

UNTIL THE APP IS REBUILT: set iOS Settings > Display & Brightness > Auto-Lock to Never while
streaming, or the stream will still die when the screen locks.

Local Edge fake-camera repro is the fast way to test the WebRTC leg without a phone
(--use-fake-device-for-media-stream --use-fake-ui-for-media-stream, UIAutomation click on
"Start WebRTC stream"). Close the test browser afterwards or its receiver tab lingers.

Verified: cargo check passes. NOT verified live — the running host was started elevated and
could not be restarted from the Claude session. Restart the host (cargo run -p windows-host),
open ONE fresh receiver page, tap Start in the app (no app rebuild needed for signaling), test.
If frames flow, click the virtual cam bridge and proceed to Windows Camera / Discord testing
from Update 1 below.

## 2026-07-03 Update: Discord works; stream stability + Windows Camera fixes

User confirmed Discord now SHOWS VIDEO (the 2026-07-02 frame server contract fixes worked).
Two remaining problems were tackled this session:

### Problem 1: stream cuts out after ~30 seconds

Root cause analysis (high confidence): the phone sender page had no screen wake lock, and
iOS auto-lock (default 30s) suspends Safari and kills the WebRTC stream. There was also no
reconnection logic anywhere, so one drop = dead until manual restart. Fixes, all in
windows-host/src/webrtc_http.rs (rebuild with cargo build -p windows-host):

- Phone page now requests navigator.wakeLock('screen') on Start and re-acquires it on
  visibilitychange. If wake lock is unsupported it tells the user to disable auto-lock.
- Phone page auto-reconnects: on connection failed/closed, on 4s of 'disconnected', on
  camera track 'ended', and on page resume, it restarts the whole offer flow (which the
  receiver page answers automatically because the offer key changes).
- Receiver page bridge timers moved to a Web Worker ticker: hidden/minimized pages clamp
  setInterval to >=1s, which froze the virtual camera whenever the receiver window was
  minimized. Worker timers are exempt.
- Raw bridge cadence went from 100ms (10fps) to 33ms (~30fps) with the in-flight guard
  still pacing it to what the machine can actually do.
- Host preview.rs: the direct-write fallback for latest.rgba no longer truncates (fs::write
  did), so the camera source can never read a short file mid-write; worst case is now a torn
  frame instead of a fallback-pattern flash.

### Problem 2: Windows Camera shows no video (black preview) — REPRODUCED + fixed (untested)

Reproduced headlessly: registered a session-scoped camera (register_virtual_camera.exe start,
no admin needed), launched the Camera app, cycled to iPhone Camera via UIAutomation
(SwitchCameraButtonId) — preview is fully black, not even the fallback checkerboard, while the
log shows Start + hundreds of fulfilled RequestSamples. So samples flow but the Camera app
renders none of them.

Diagnosis: compared against BOTH references (microsoft/Windows-Camera VirtualCameraMediaSource
SimpleMediaStream.cpp and smourier/VCamSample MediaStream.cpp). Both differ from our source in
the same two ways:

1. They return MFSampleAllocatorUsage_UsesProvidedAllocator from GetAllocatorUsage, accept the
   frame server's allocator via SetDefaultAllocator/SetAllocator, call
   InitializeSampleAllocator(10, currentType) in Stream::Start, and allocate every sample from
   it. We returned UsesCustomAllocator and handed out plain MFCreateMemoryBuffer samples. The
   SourceReader path and the DirectShow (Discord) path copy, so they work; the Camera app's
   D3D-accelerated preview path is the one that goes black. This is the top suspect.
2. They expose RGB32 in addition to NV12. We were NV12-only.

Both were fixed in iphone_camera_source.cpp:

- IMFSampleAllocatorControl now reports UsesProvidedAllocator; SetDefaultAllocator forwards the
  allocator (QI IMFVideoSampleAllocator) to the stream; Stream::Start calls
  InitializeSampleAllocator(10, current type); Stop calls UninitializeSampleAllocator.
- RequestSample allocates from the provided allocator, writing pixels through
  IMF2DBuffer2::Lock2DSize with proper pitch handling (NV12 UV plane at scanline0+pitch*height).
  If anything in the allocator path fails at runtime it silently falls back to the old
  MFCreateMemoryBuffer path (logged once), so Discord/probes cannot regress.
- Stream descriptor now exposes NV12 (default) + RGB32; SetMediaType/SetCurrentMediaType are
  honored and RequestSample fills whichever is negotiated (RGB32 = BGRX order, alpha forced 255).
- Log lines now carry "MM-DD HH:MM:SS.mmm [pid process.exe]" so sessions are attributable.

Verified so far: DLL + probes rebuild clean; probe_source_reader (in-process, new DLL) passes,
NV12 default intact. NOT yet verified through the frame server: the FrameServer service
(svchost) keeps the OLD module loaded even after the DLL file is swapped (the loader reuses a
loaded module by path; renaming the file does not help). The service would not idle-stop during
the session and restarting it needs admin.

### IMPORTANT for next test run

The frame server MUST be restarted once to pick up the new DLL. The normal admin flow already
does this (install-machine.ps1 stops FrameServer). So: run the standard test flow below, then
check Windows Camera first, then Discord. The new log lines have timestamps + process names,
so a failing app session can finally be isolated cleanly:

    Get-Content "C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.log" -Tail 200

If Windows Camera is STILL black after this, next suspects (in order): remove
MF_DEVICESTREAM_FRAMESERVER_SHARED; make RGB32 the default type like VCamSample; check whether
the Camera app session log shows the allocator being provided (look for
"SetDefaultAllocator"/"InitializeSampleAllocator hr=0x0") — if the frame server never provides
one, investigate why.

Headless testing tricks learned this session:

- register_virtual_camera.exe start (no args) registers a current-user session camera without
  admin; run it in the background and kill the process to unregister.
- The Camera app can be driven headlessly: start microsoft.windows.camera:, then UIAutomation
  Invoke on AutomationId SwitchCameraButtonId cycles cameras; screenshot via CopyFromScreen.
- The registrar process itself loads the source DLL in-process, so it must be stopped before
  rebuilding the DLL into source\bin.
- A locked DLL can be renamed aside and replaced (rename trick), but any process that already
  has it loaded keeps the old code until that process restarts — for svchost/FrameServer that
  means an admin service restart, not just a file swap.

## 2026-07-02 Update: Virtual Camera Source Compatibility Fixes

The likely cause of "Discord requests samples but shows no video" was found by comparing
against Microsoft's VirtualCamera reference sample (Windows-Camera repo) and the known-good
smourier/VCamSample. The source violated the frame server contract in four ways; all fixed
in windows-virtual-camera/source/iphone_camera_source.cpp:

1. Sample timestamps were 0-based (`sampleTime_ += FRAME_DURATION`). Real cameras and both
   reference implementations use `SetSampleTime(MFGetSystemTime())` (QPC-based clock time).
   Consumers that compare sample time to the real clock treat 0-based frames as stale and
   render nothing. This is the top suspect for the Discord failure.
2. The stream did not implement IMFMediaStream2. The 2026-07-01 log shows the frame server
   QI'ing the stream for {C5BC37D6-75C7-46A1-A132-81B5F723C20F} (IID_IMFMediaStream2) and
   getting E_NOINTERFACE. SetStreamState/GetStreamState are now implemented (running/stopped/
   paused map to MEStreamStarted/MEStreamStopped/MEStreamPaused).
3. Source::Start queued MEUpdatedStream even on first start. Per the frame server custom
   media source docs the stream must be delivered via MENewStream first; MEUpdatedStream is
   only for restarts. Now tracked with a streamDelivered_ flag.
4. Stream attributes lacked MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES = MFFrameSourceTypes_Color
   (set by both reference implementations). Added to the stream descriptor and GetStreamAttributes.
   Also added IMFSampleAllocatorControl on the source (returns UsesCustomAllocator), which the
   frame server queries.

Verification done on 2026-07-02 (no phone connected, stale/fallback frame content, which is fine
for pipeline testing):

- probe_source_reader.exe still passes (direct in-process source reader).
- NEW probe_device_reader.exe: enumerates devices like a real app (MFEnumDeviceSources through
  the frame server), activates "iPhone Camera (Windows Virtual Camera)", reads 20 NV12
  720x1280@30 samples with QPC timestamps. PASSES end to end.
- NEW probe_dshow.exe: enumerates via DirectShow (CLSID_VideoInputDeviceCategory) - this is the
  path Discord's WebRTC engine uses. The camera IS visible and exposes YUY2 + NV12 720x1280
  (frame server adds the YUY2 conversion automatically). PASSES.
- The runtime log confirms the frame server now queues MENewStream and successfully uses
  IMFMediaStream2::SetStreamState.
- build-probe.ps1 now builds all three probes.

Note: apps see the device as "iPhone Camera (Windows Virtual Camera)" - Windows appends the
suffix. The new DLL was already copied to C:\ProgramData\IPhoneCameraStreaming (the Users-Modify
ACL allows this without admin when no camera session holds the DLL).

Still to verify by a human: Windows Camera and Discord with a live phone stream (run the normal
test flow below). If Discord still fails after these fixes, next steps from the earlier plan
remain valid (offer an additional landscape 1280x720 media type; compare Discord vs Windows
Camera log sequences).

This project is building a Windows-first iPhone-as-webcam system. The iPhone sends video over local Wi-Fi to the Windows host, the host exposes preview/signaling/bridge endpoints, and a custom Windows Media Foundation virtual camera source presents the stream to apps such as Discord.

## Current High-Level State

We made real progress today. The pipeline now reaches much further than the previous handoff said.

Confirmed working path:

1. iPhone/app connects over WebRTC to the Windows host.
2. The Windows host receives WebRTC signaling on port 41003.
3. The browser receiver/bridge posts raw RGBA frames to the host.
4. The Rust host writes a shared raw frame file at C:\ProgramData\IPhoneCameraStreaming\latest.rgba.
5. The Media Foundation virtual camera source DLL is loaded by Windows/Discord.
6. The source reaches IPhoneCameraSource::Start.
7. Discord/Windows requests samples from the stream, shown by IPhoneCameraStream::RequestSample #... log lines.
8. The source has successfully read a live shared frame: IPhoneCameraStream::FillFrame using shared frame bytes=3686400.

That last line is important: it proves the virtual camera source can read the actual live RGBA frame file. The previous access denied/file-lock issue is fixed on the source-read side.

Current unresolved issue:

- Discord still appears to fail or not load video, even though the virtual camera source starts and Discord requests samples.
- The next problem is likely Media Foundation virtual camera compatibility/behavior, not WebRTC, not phone connectivity, and not the shared frame file path.

## Repo Shape

- ios-app/ - native iPhone sender app.
- windows-host/ - Rust Windows receiver, WebRTC HTTP/signaling server, preview/bridge code.
- windows-virtual-camera/ - Windows Media Foundation virtual camera registrar and source DLL.
- shared/ - shared protocol docs and older non-WebRTC path.

## Important Ports

- TCP 41000: original control channel.
- TCP/UDP 41001: older video path.
- HTTP 41002: old diagnostic preview page. Do not use this for quality judgment.
- HTTP 41003: WebRTC signaling/receiver/phone pages. This is the current good path.

Useful pages:

    http://127.0.0.1:41003/receiver
    http://<windows-ip>:41003/phone
    http://127.0.0.1:41003/virtual-camera/status

## Commands For Normal Test Run

Use separate PowerShell windows because the registrar script waits for Enter to stop.

### PowerShell 1: Administrator

If the registrar is already running, press Enter in that window first.

    cd "C:\Users\benje\Documents\Iphone Camera Streaming"

    powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\build.ps1

    powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\install-machine.ps1

    powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\registrar\run-start-all-users-system.ps1

Leave the registrar window open while testing.

### PowerShell 2: Normal

    cd "C:\Users\benje\Documents\Iphone Camera Streaming"

    cargo run -p windows-host

### Browser/iPhone Flow

1. Open the receiver page on Windows: http://127.0.0.1:41003/receiver
2. On the iPhone, connect to the phone sender URL shown by the host: http://<windows-ip>:41003/phone
3. Start the WebRTC stream.
4. In the receiver page, start the virtual camera bridge.
5. Test iPhone Camera in Windows Camera first, then Discord.

## Diagnostics To Run

### Check virtual camera source log

Run this after Windows Camera or Discord has tried to turn the camera on. No need to race it instantly; the log keeps recent lines.

    Get-Content "C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.log" -Tail 120

Important good lines:

    IPhoneCameraSource::Start
    IPhoneCameraSource::Start hr=0x00000000
    IPhoneCameraStream::FillFrame using shared frame bytes=3686400
    IPhoneCameraStream::RequestSample #...

FillFrame using shared frame bytes=3686400 means the source is reading the live raw frame file.

Bad lines to watch for:

    IPhoneCameraStream::FillFrame open shared frame failed ...
    IPhoneCameraStream::FillFrame using fallback pattern
    IPhoneCameraStream::FillFrame shared frame read failed ...

Those would mean the source fell back to a test pattern instead of live frames.

### Check host status

    Invoke-RestMethod http://127.0.0.1:41003/virtual-camera/status | ConvertTo-Json -Depth 10

Good current state should be similar to:

    {
      "device_name": "iPhone Camera",
      "frame_source_state": "raw_frames_ready",
      "latest_frame": {
        "format": "rgba8",
        "width": 720,
        "height": 1280,
        "stride": 2880,
        "byte_len": 3686400
      }
    }

Note: at one point the incoming bridge frame was 360x640, byte_len=921600. The host was patched to normalize incoming RGBA frames to fixed 720x1280 before writing latest.rgba, because the virtual camera source expects 3686400 bytes.

### Check shared frame file

    Get-Item "C:\ProgramData\IPhoneCameraStreaming\latest.rgba" | Format-List FullName,Length,LastWriteTime

Good length:

    Length : 3686400

## Code Changes Made Today

### windows-virtual-camera/source/iphone_camera_source.cpp

Major state now:

- Source exposes/implements core Media Foundation virtual camera interfaces.
- Source supports IMFMediaSource2, IMFGetService, IMFExtendedCameraController, IKsControl, IMFRealTimeClient, and IMFRealTimeClientEx.
- Do not casually re-add IMFCollection; earlier empty/stub behavior made enumeration worse.
- Media output was changed to fixed NV12: 720x1280, 30 fps, 1382400 bytes per sample.
- Raw input file remains RGBA: 720x1280, stride 2880, 3686400 bytes, at C:\ProgramData\IPhoneCameraStreaming\latest.rgba.
- FillFrame reads the RGBA file and converts to NV12.
- One-time logging was added to show whether it is using the live shared frame or fallback pattern.
- The file read path was changed from _wfopen_s(..., L"rb") to CreateFileW with FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE.
- This fixed the issue where the source would hold latest.rgba in a way that blocked the host from replacing/updating it.
- Confirmed log after this change: IPhoneCameraStream::FillFrame using shared frame bytes=3686400.

### windows-host/src/preview.rs

- Host writes raw frames to C:\ProgramData\IPhoneCameraStreaming\latest.rgba.
- Added normalization so any incoming RGBA frame is resized to 720x1280 before writing.
- The code first writes a temp file and renames it over latest.rgba.
- If rename fails on Windows, it attempts a direct write fallback.
- Previously the host logged Access is denied and file-is-being-used errors. The source-side CreateFileW sharing change was made to address that file-lock behavior.

### windows-virtual-camera/source/install-machine.ps1

- ACL was updated to give Users Modify rights on C:\ProgramData\IPhoneCameraStreaming.
- Correct manual ACL command in PowerShell, if needed:

    icacls "C:\ProgramData\IPhoneCameraStreaming" /grant "*S-1-5-32-545:(OI)(CI)M" /T

Important: quote the grant expression. Without quotes, PowerShell treats (OI) as syntax/commands.

### Probe Tool

A direct source reader probe exists and has previously succeeded:

    .\windows-virtual-camera\source\bin\probe_source_reader.exe

Known good result after NV12 change:

    CoCreateInstance source hr=0x00000000
    MFCreateSourceReaderFromMediaSource hr=0x00000000
    GetCurrentMediaType hr=0x00000000
    Current media type: subtype={3231564E-0000-0010-8000-00AA00389B71} size=720x1280 fps=30/1
    ReadSample #1 hr=0x00000000 ... sample=yes

{3231564E-0000-0010-8000-00AA00389B71} is NV12.

## Security/Defender Note

Microsoft Defender raised Trojan:Win32/ClickFix.DE!MTB.

The resource was a Codex helper command line:

    C:\Users\benje\AppData\Local\OpenAI\Codex\runtimes\...\codex-computer-use.exe turn-ended ...

Checks showed:

    ActionSuccess : True
    DidThreatExecute : False
    IsActive : False

The detection resources pointed at the Codex helper command line, not this repo, not the camera DLL, not the Rust host, and not C:\ProgramData\IPhoneCameraStreaming. Recommendation was: do not click Allow on device. Treat it as contained unless Defender later reports project files or installed camera binaries.

## Current Best Next Steps

Start tomorrow here.

### Step 1: Establish whether Discord-specific or general camera-source issue

Run the normal test flow, then test in Windows Camera first.

1. Start registrar in Admin PowerShell.
2. Start cargo run -p windows-host in a second PowerShell.
3. Connect phone/WebRTC.
4. Start the virtual camera bridge.
5. Open Windows Camera app and select iPhone Camera.
6. Run:

    Get-Content "C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.log" -Tail 120

Interpretation:

- If Windows Camera shows live video but Discord fails, the source works generally and Discord needs a compatibility tweak.
- If Windows Camera also fails, focus on source sample/event/media-type behavior.

### Step 2: If Windows Camera works but Discord fails

Likely areas:

- Discord may dislike the current virtual camera attributes or stream metadata.
- Discord may dislike NV12-only, portrait 720x1280, or the exact presentation descriptor/stream attributes.
- Try offering an additional landscape media type, such as 1280x720, or a common camera format path, but keep the direct probe passing.
- Capture a fresh log from Discord and compare it to Windows Camera.

Useful command after Discord failure:

    Get-Content "C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.log" -Tail 250

Look for unusual QueryInterface, GetService, IKsControl, or source shutdown sequence.

### Step 3: If Windows Camera also fails

Focus on Media Foundation source behavior, especially:

- Event ordering around Start.
- Whether to queue MENewStream vs MEUpdatedStream for this virtual camera shape.
- Sample timestamps/durations.
- Sample buffer attributes and media type consistency.
- Whether MF_DEVICESTREAM_FRAMESERVER_SHARED is helping or hurting.
- Whether optional interfaces are being exposed but not fully satisfying callers.

Keep validating with:

    .\windows-virtual-camera\source\bin\probe_source_reader.exe

Probe success alone is not enough; it proves direct Media Foundation source reader compatibility, not app compatibility.

### Step 4: If shared frame errors return

Run:

    Get-Content "C:\ProgramData\IPhoneCameraStreaming\iphone_camera_source.log" -Tail 120

and inspect the cargo run -p windows-host window.

If the source log says fallback or open/read failure, revisit ACL/file sharing. If the source log says live frame bytes and host has no write warnings, the frame bridge is fine.

## Known Good Milestones Reached

- Virtual camera registration no longer fails with 0xc00d36e6.
- Direct source reader probe reads samples successfully.
- Media type is now NV12 and probe sees it.
- Discord/Windows reaches Start and requests samples.
- Source reads live latest.rgba frames successfully.
- The old Access is denied and file-in-use problems were identified and patched.

## Caution For Future Edits

The workspace root is C:\Users\benje\Documents\Iphone Camera Streaming.

apply_patch may falsely reject writes as outside the project on this Windows path. If that happens, use the node_repl tool to write files inside the workspace.

Do not revert unrelated user changes. The repo may be dirty.
