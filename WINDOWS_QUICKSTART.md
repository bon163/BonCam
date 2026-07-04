# Windows Quick Start

Use this when you want the fastest path from a fresh Windows machine to a running host.

## Before You Start

- Install the Rust toolchain from [rustup.rs](https://rustup.rs/)
- Reopen PowerShell after installation so `cargo` is available
- Make sure you are in this repository folder

```powershell
cd "C:\Users\benje\Documents\Iphone Camera Streaming"
```

## Optional Setup

If you want to pre-create firewall rules before running the host, launch PowerShell as Administrator and run:

```powershell
.\scripts\setup-windows-firewall.ps1
```

If Windows asks whether to allow network access later, allow it on private networks.

## Find The Host IP

Run:

```powershell
.\scripts\show-windows-ip.ps1
```

Use the Wi-Fi IPv4 address in the iPhone app.

## Start The Host

Run:

```powershell
.\scripts\run-windows-host.ps1
```

Leave that PowerShell window open while the phone connects.

## Connect The iPhone

- Open the iPhone app
- Enter the Windows IP address
- Tap the start button
- Confirm the host console shows pairing and stream logs

## Ports In Use

- `41000` - TCP control channel
- `41001` - UDP video channel
- `41003` - WebRTC signaling and receiver HTTP server

## WebRTC Receiver Path

With the host running, open this page on the Windows machine:

```text
http://127.0.0.1:41003/receiver
```

Then on the iPhone app:

- Enter the Windows IP address
- Open the WebRTC sender
- Start the WebRTC stream
- Allow camera access if prompted

## Troubleshooting

- If the app cannot connect, confirm the IP address is correct.
- If Windows Defender blocks access, allow the host on private networks.
- If the receiver page is left open in the background, keep it visible so the browser does not suspend it.
