# Windows Host

This crate is the Windows side of BonCam.

It currently handles:

- TCP control messages on port `41000`
- UDP video packets on port `41001`
- Pairing state persisted to `paired-devices.json`
- Preview and lifecycle logging
- WebRTC receiver and signaling on port `41003`

## How To Run It

From the workspace root:

```powershell
.\scripts\run-windows-host.ps1
```

If you prefer to open the ports ahead of time, run:

```powershell
.\scripts\setup-windows-firewall.ps1
```

## What A Healthy Start Looks Like

- The host reports that it is listening on `41000` and `41001`
- Pairing events appear when the iPhone app connects
- Stream-start and frame-receive logs appear after the handshake

## WebRTC Receiver

The host also exposes a WebRTC receiver and signaling endpoint on `41003`:

- Receiver page: `http://127.0.0.1:41003/receiver`
- Sender page: `http://<windows-ip>:41003/phone`

This path is meant to evolve into the lower-latency replacement for the custom socket-based preview path.

## Current Scope

- The host is focused on receiving, validating, and bridging the stream.
- The full virtual camera surface is still being built out.
- The preview pipeline exists, but the final Windows-facing experience is still in progress.
