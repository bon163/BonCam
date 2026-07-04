# Windows Quick Start

## 1. Install Rust
- Go to [rustup.rs](https://rustup.rs/)
- Install the default toolchain
- Close and reopen PowerShell

## 2. Open the project folder in PowerShell
- Change into this folder:
- `C:\Users\benje\Documents\Iphone Camera Streaming`

## 3. Optional: open the firewall ports
- Right-click PowerShell and choose **Run as administrator**
- Run:
- `.\scripts\setup-windows-firewall.ps1`

## 4. Find your Windows laptop IP
- Run:
- `.\scripts\show-windows-ip.ps1`
- Use the Wi-Fi IPv4 address in the iPhone app

## 5. Start the Windows host
- Run:
- `.\scripts\run-windows-host.ps1`

## 6. Leave that PowerShell window open
- The iPhone app will connect to this process
- Current ports:
- TCP `41000`
- TCP `41001`
- TCP `41003`

## 7. On the iPhone app
- Enter the Windows IP address
- Tap **Start**
- Confirm the Windows console shows pairing and stream logs

## Notes
- The legacy socket path still exists for comparison, and the new WebRTC path is available on TCP 41003.
- If Windows Defender asks about network access, allow it on **Private networks**.


## WebRTC test path

This is the newer low-latency path. Keep the Windows host running, then open this page on the Windows machine:

`http://127.0.0.1:41003/receiver`

On the iPhone app, enter the Windows machine IP address as before, then tap **Open WebRTC Sender**. In the sender sheet, tap **Start WebRTC stream** and allow camera access if prompted.

If the sender page opens but camera access is refused, the next development step is to switch the dev sender page from local HTTP to either an embedded app page or local HTTPS. The signaling and Windows receiver are already separated so that change is small.
