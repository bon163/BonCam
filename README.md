# BonCam

BonCam is a Windows-first iPhone camera streaming project.

It is split into a few pieces:

- `ios-app/` - the native iPhone sender app
- `windows-host/` - the Windows receiver, preview, and WebRTC host
- `windows-virtual-camera/` - the DirectShow / virtual camera implementation
- `shared/` - protocol definitions and shared docs
- `scripts/` - setup and launch helpers for Windows

## What It Does

- Streams camera video from an iPhone to a Windows machine
- Uses a shared control protocol for pairing and stream state
- Supports a Windows preview path
- Includes a WebRTC-based receiver path on TCP port `41003`
- Includes the groundwork for a Windows virtual camera device

## Requirements

- Windows 10 or Windows 11 for the host machine
- Rust toolchain via [rustup](https://rustup.rs/)
- Xcode on macOS for building the iPhone app
- An iPhone for running the sender app

## Quick Start

### Windows host

From the workspace root, run:

```powershell
.\scripts\run-windows-host.ps1
```

If Windows asks for firewall access, allow it on private networks.

### Optional firewall setup

Run PowerShell as Administrator and execute:

```powershell
.\scripts\setup-windows-firewall.ps1
```

### Find the host IP

```powershell
.\scripts\show-windows-ip.ps1
```

Use the Wi-Fi IPv4 address in the iPhone app.

### iPhone app

Open `ios-app/IPhoneCamSender.xcodeproj` in Xcode, select your signing team, and run it on an iPhone.

## Ports

- `41000` - TCP control channel
- `41001` - UDP video channel
- `41002` - local preview HTTP server
- `41003` - WebRTC signaling and receiver HTTP server

## Documentation

- [Windows quick start](./WINDOWS_QUICKSTART.md)
- [Root handoff notes](./HANDOFF.md)
- [Shared protocol docs](./shared/docs/protocol.md)
- [Windows host notes](./windows-host/README.md)
- [iPhone app notes](./ios-app/README.md)

## Notes

- `paired-devices.json` is generated at runtime and ignored by Git.
- Build output lives under `target/` and should not be committed.
- The repository currently includes the Windows host, iPhone sender, and virtual camera scaffolding, but the pieces still need to be built and tested together on their target platforms.
