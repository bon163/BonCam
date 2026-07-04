# Windows Host Setup

This is the Windows receiver for the iPhone camera stream.

## What it does today

- Accepts a TCP control connection on port `41000`
- Accepts UDP video packets on port `41001`
- Stores paired device info in `paired-devices.json`
- Logs pairing and stream lifecycle events

## Before you run it

1. Install Rust using rustup: https://rustup.rs/
2. Open a new PowerShell window after installation.
3. Allow private-network firewall access when Windows prompts you.

## Quick start

From the workspace root, run:

```powershell
.\scripts\run-windows-host.ps1
```

If you want to pre-open firewall ports first, run PowerShell as Administrator and run:

```powershell
.\scripts\setup-windows-firewall.ps1
```

## What success looks like

When the host starts correctly, you should see logs indicating that it is listening on TCP `41000` and UDP `41001`.
When the iPhone app connects, you should see control connection, pairing, and stream-start logs.

## Current limitation

The Windows host currently receives video frames but does not display them in a real preview window yet. This milestone is focused on receiving and validating the stream.


## WebRTC receiver

The host also serves a WebRTC receiver and signaling endpoints on TCP 41003:

- Receiver page: `http://127.0.0.1:41003/receiver`
- iPhone sender page: `http://<windows-ip>:41003/phone`

This path is intended to replace the custom H.264 socket preview once the iPhone sender is stable.
