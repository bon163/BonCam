# BonCam

BonCam is a Windows-first iPhone camera streaming project.

The repository is organized around a simple path:

- The iPhone captures and sends camera video.
- The Windows host receives, previews, and bridges the stream.
- Shared Rust types keep the control protocol consistent.
- Windows virtual camera work lives alongside the host so the pipeline can grow into a system-wide camera source.

## At A Glance

- iPhone sender app in SwiftUI
- Windows host in Rust
- Shared control protocol in Rust
- WebRTC signaling and receiver path on TCP `41003`
- Windows preview and virtual camera scaffolding

## Repository Layout

- `ios-app/` - native iPhone sender app and Xcode project
- `windows-host/` - Windows receiver, preview, and WebRTC host
- `windows-virtual-camera/` - DirectShow and virtual camera source code
- `shared/` - protocol definitions and supporting documentation
- `scripts/` - PowerShell helpers for Windows setup and launch

## Requirements

- Windows 10 or Windows 11 for the host machine
- Rust toolchain installed through [rustup](https://rustup.rs/)
- Xcode on macOS for building and signing the iPhone app
- An iPhone for running the sender app

## Quick Start

### 1. Start the Windows host

From the workspace root:

```powershell
.\scripts\run-windows-host.ps1
```

If Windows prompts for network access, allow it on private networks.

### 2. Optional firewall setup

If you want to pre-open the host ports, run PowerShell as Administrator and execute:

```powershell
.\scripts\setup-windows-firewall.ps1
```

### 3. Find the Windows IP address

```powershell
.\scripts\show-windows-ip.ps1
```

Use the Wi-Fi IPv4 address in the iPhone app.

### 4. Build and run the iPhone app

Open `ios-app/IPhoneCamSender.xcodeproj` in Xcode, choose your signing team, and run it on a connected iPhone.

## Ports

- `41000` - TCP control channel
- `41001` - UDP video channel
- `41002` - local preview HTTP server
- `41003` - WebRTC signaling and receiver HTTP server

## Documentation

- [Windows quick start](./WINDOWS_QUICKSTART.md)
- [Windows host notes](./windows-host/README.md)
- [iPhone app notes](./ios-app/README.md)
- [Shared protocol docs](./shared/docs/protocol.md)
- [Project handoff notes](./HANDOFF.md)

## Current Status

- The control protocol and shared types are in place.
- The Windows host can receive the stream and expose a WebRTC receiver path.
- The iPhone app includes capture, encoding, and transport code.
- The virtual camera layer is scaffolded and ready for continued implementation.

## Housekeeping

- `paired-devices.json` is generated at runtime and ignored by Git.
- Build output under `target/` is ignored.
- Local helper tools under `.tools/` are ignored.
- Generated `.obj` files are ignored so the repository stays source-only.

## Suggested Next Steps

1. Run the Windows host and confirm it starts cleanly.
2. Open the iPhone app in Xcode and verify signing and camera permissions.
3. Confirm the protocol handshake between phone and host.
4. Continue the virtual camera and preview work once the stream path is stable.
