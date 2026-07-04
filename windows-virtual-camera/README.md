# Windows Virtual Camera Integration

Goal: make the iPhone stream appear in camera pickers as **iPhone Camera**.

## Current status

The smooth WebRTC receiver remains the source of truth at:

`http://127.0.0.1:41003/receiver`

The receiver page now has two optional bridge buttons:

- **Start JPEG bridge** sends compressed diagnostic frames to the old `41002` preview path.
- **Start virtual cam bridge** sends raw RGBA frames to the Windows host via `POST /frame/webrtc.rgba`.

The raw bridge is the frame boundary intended for the Windows virtual camera device layer. It is intentionally opt-in because reading pixels out of a browser video can cost CPU.

## Microsoft virtual camera target

Windows exposes software cameras through Media Foundation virtual cameras. The device is registered with `MFCreateVirtualCamera`, and `IMFVirtualCamera::Start` makes it discoverable to apps. Microsoft documents that the virtual camera plugs into the Media Foundation frame-server pipeline and is discovered as if it were a hardware capture device.

Important implications:

- A virtual camera is a system-facing Media Foundation component, not just an app window.
- The API needs a custom media source CLSID behind the camera.
- The first version should use current-user/session registration while developing.
- The frame source should consume our latest raw RGBA frame and produce the media type apps request.

## Next implementation step

Build a small Windows Media Foundation custom media source named **iPhone Camera Source** that reads the latest raw RGBA frame from the host process and exposes a video stream. Once that source is registered, call `MFCreateVirtualCamera` with its CLSID and friendly name **iPhone Camera**.


## Registrar tool

The `registrar/` folder contains a small C++ tool that calls `MFCreateVirtualCamera` for the friendly name **iPhone Camera** and our reserved source CLSID.

`{7F812B6A-CA0B-4E6E-8E01-7A2D767C1F24}`

Run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\registrar\build.ps1
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\registrar\run-start.ps1
```

Expected current result: Windows may fail to start the virtual camera until the COM Media Foundation source for that CLSID exists. That is the next component to build. If it succeeds in registering, keep the process open while checking camera pickers.


## Source DLL scaffold

The `source/` folder contains the first COM Media Foundation source DLL for the reserved CLSID. It currently exposes a minimal live video source descriptor, but it does not yet produce samples.

Run from PowerShell before the registrar:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\build.ps1
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\register.ps1
```

Then rerun the registrar. The expected next error may move from `Class not registered` to a Media Foundation stream/sample requirement, which is the next implementation seam.


If `MFCreateVirtualCamera` still reports `Class not registered` after `register.ps1`, verify registration with:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\verify-registration.ps1
```

If current-user registration exists but the virtual camera still cannot see the class, run machine-wide registration from an Administrator PowerShell window:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows-virtual-camera\source\register-machine.ps1
```
