import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showingWebRTC = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        previewPanel
                        connectionPanel
                        controlsPanel
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("BonCam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingWebRTC) {
                WebRTCSenderView(hostAddress: appModel.hostAddress)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(appModel.isStreaming ? "Live" : "Ready", systemImage: appModel.isStreaming ? "dot.radiowaves.left.and.right" : "sparkles")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(appModel.isStreaming ? Color.green : Color.cyan)
                    .background(.white.opacity(0.10), in: Capsule())

                Spacer()

                Text(appModel.selectedPreset.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text("iPhone camera for Windows")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Host \(appModel.hostAddress.isEmpty ? "not set" : appModel.hostAddress)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewPanel: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewView(session: appModel.captureManager.session)
                .frame(maxWidth: .infinity)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }

            HStack(spacing: 9) {
                Image(systemName: appModel.cameraPosition == .back ? "camera.fill" : "person.crop.square.fill")
                    .font(.caption.weight(.bold))
                Text(appModel.cameraPosition == .back ? "Back Camera" : "Front Camera")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.42), in: Capsule())
            .padding(16)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 18)
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Connection", systemImage: "network")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                ConnectionBadge(state: appModel.connectionState)
            }

            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Windows host")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.56))
                    Text(appModel.hostAddress.isEmpty ? "Add an IP in Settings" : appModel.hostAddress)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            if !appModel.pairCode.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.12))

                HStack {
                    Label("Pair code", systemImage: "key.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                    Text(appModel.pairCode)
                        .font(.system(.headline, design: .monospaced).weight(.bold))
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(18)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var controlsPanel: some View {
        VStack(spacing: 12) {
            Button {
                appModel.isStreaming ? appModel.stop() : appModel.start()
            } label: {
                Label(appModel.isStreaming ? "Stop stream" : "Start stream", systemImage: appModel.isStreaming ? "stop.fill" : "play.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(PrimaryControlButtonStyle(isDestructive: appModel.isStreaming))

            HStack(spacing: 12) {
                Button {
                    appModel.switchCamera()
                } label: {
                    Label("Switch", systemImage: "arrow.triangle.2.circlepath.camera.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(SecondaryControlButtonStyle())

                Button {
                    appModel.togglePreset()
                } label: {
                    Label(appModel.selectedPreset == .hd720p30 ? "1080p" : "720p", systemImage: "rectangle.inset.filled")
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(SecondaryControlButtonStyle())
            }

            Button {
                showingWebRTC = true
            } label: {
                Label("Open WebRTC Sender", systemImage: "globe")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(SecondaryControlButtonStyle(accent: .yellow))
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ZStack {
            AppBackground()

            Form {
                Section {
                    TextField("192.168.1.10", text: $appModel.hostAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Windows host IP")
                }

                Section("Current setup") {
                    SettingsInfoRow(title: "Camera", value: appModel.cameraPosition == .back ? "Back" : "Front", systemImage: "camera.fill")
                    SettingsInfoRow(title: "Quality", value: appModel.selectedPreset.displayName, systemImage: "rectangle.inset.filled")
                    SettingsInfoRow(title: "Status", value: appModel.connectionState, systemImage: "waveform.path.ecg")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }
}

struct SettingsInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.cyan)
                .frame(width: 24)
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

struct ConnectionBadge: View {
    let state: String

    private var color: Color {
        let lowercased = state.lowercased()
        if lowercased.contains("stream") || lowercased.contains("connected") {
            return .green
        }
        if lowercased.contains("fail") {
            return .red
        }
        if lowercased.contains("pair") {
            return .yellow
        }
        return .white.opacity(0.66)
    }

    var body: some View {
        Text(state)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.07),
                Color(red: 0.06, green: 0.12, blue: 0.15),
                Color(red: 0.12, green: 0.10, blue: 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct PrimaryControlButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isDestructive ? .white : Color(red: 0.02, green: 0.07, blue: 0.08))
            .background(
                LinearGradient(
                    colors: isDestructive ? [.red, .pink] : [.cyan, .green],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

struct SecondaryControlButtonStyle: ButtonStyle {
    var accent: Color = .cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accent.opacity(0.26), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private extension StreamPreset {
    var displayName: String {
        switch self {
        case .hd720p30:
            return "720p"
        case .hd1080p30:
            return "1080p"
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}


struct WebRTCSenderView: UIViewRepresentable {
    let hostAddress: String

    func makeCoordinator() -> Coordinator {
        Coordinator(hostAddress: hostAddress)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "signal")

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
        // iOS auto-lock (default 30s) suspends the web view and kills the stream;
        // keep the screen awake while the sender sheet is open.
        UIApplication.shared.isIdleTimerDisabled = true
        loadSenderPage(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.hostAddress = hostAddress
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func loadSenderPage(in webView: WKWebView) {
        webView.loadHTMLString(Self.senderHTML, baseURL: URL(string: "https://iphone-cam.local")!)
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var hostAddress: String
        weak var webView: WKWebView?

        init(hostAddress: String) {
            self.hostAddress = hostAddress
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "signal",
                  let payload = message.body as? [String: Any],
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  let path = payload["path"] as? String,
                  let url = URL(string: "http://\(hostAddress):41003\(path)") else {
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.cachePolicy = .reloadIgnoringLocalCacheData

            if let body = payload["body"], !(body is NSNull) {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let httpStatus = (response as? HTTPURLResponse)?.statusCode
                let status = httpStatus ?? (error == nil ? 200 : 599)
                let responseText = data.flatMap { String(data: $0, encoding: .utf8) }
                    ?? error?.localizedDescription
                    ?? ""
                let script = "window.__signalResponse(\(Self.javascriptLiteral(id)), \(status), \(Self.javascriptLiteral(responseText)))"
                DispatchQueue.main.async {
                    self?.webView?.evaluateJavaScript(script)
                }
            }.resume()
        }

        @available(iOS 15.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }

        private static func javascriptLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let encoded = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return encoded
        }
    }

    private static let senderHTML = #"""
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>iPhone WebRTC Sender</title>
  <style>
    :root { color-scheme: dark; --ink: #f5efe2; --muted: #c9bfae; --panel: rgba(22, 28, 30, .78); --line: rgba(255,255,255,.14); }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; font-family: Avenir Next, ui-rounded, system-ui, sans-serif; color: var(--ink); background: radial-gradient(circle at top left, #2d4d48, transparent 34rem), linear-gradient(135deg, #101719, #202319 55%, #3b2f1f); overflow: hidden; }
    video { position: fixed; inset: 0; width: 100%; height: 100%; object-fit: contain; background: #050708; }
    .panel { position: fixed; left: 18px; right: 18px; bottom: 18px; max-width: 620px; padding: 18px; border: 1px solid var(--line); border-radius: 22px; background: var(--panel); backdrop-filter: blur(18px); box-shadow: 0 20px 70px rgba(0,0,0,.35); }
    h1 { margin: 0 0 8px; font-size: clamp(24px, 5vw, 42px); letter-spacing: -.04em; }
    p { margin: 0 0 14px; color: var(--muted); line-height: 1.45; }
    button { border: 0; border-radius: 999px; padding: 12px 16px; color: #14201d; background: #f2c46d; font: inherit; font-weight: 700; }
    button:disabled { opacity: .5; }
  </style>
</head>
<body>
  <video id="local" autoplay playsinline muted></video>
  <div class="panel">
    <h1>iPhone Sender</h1>
    <p id="status">Ready to start the WebRTC camera stream.</p>
    <button id="start">Start WebRTC stream</button>
  </div>
  <script>
    const statusEl = document.querySelector('#status');
    const local = document.querySelector('#local');
    const pendingSignals = new Map();
    let seenReceiverCandidates = new Set();
    let pc;
    let stream;
    let restartTimer = null;

    window.__signalResponse = (id, status, text) => {
      const pending = pendingSignals.get(id);
      if (!pending) return;
      pendingSignals.delete(id);
      if (status >= 200 && status < 300) {
        pending.resolve({ status, text });
      } else {
        const detail = text ? ': ' + text : '';
        pending.reject(new Error('Signal request failed with status ' + status + detail));
      }
    };

    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const setStatus = text => statusEl.textContent = text;
    const signal = (method, path, body = null) => new Promise((resolve, reject) => {
      const id = String(Date.now()) + '-' + String(Math.random());
      pendingSignals.set(id, { resolve, reject });
      window.webkit.messageHandlers.signal.postMessage({ id, method, path, body });
    });
    const signalJson = async (method, path, body = null) => {
      const response = await signal(method, path, body);
      if (response.status === 204 || response.text.length === 0) return null;
      return JSON.parse(response.text);
    };

    function scheduleRestart(reason) {
      if (restartTimer) return;
      setStatus('Stream interrupted (' + reason + '). Reconnecting...');
      restartTimer = setTimeout(() => {
        restartTimer = null;
        start().catch(error => {
          setStatus('Reconnect failed: ' + error.message);
          scheduleRestart('retrying');
        });
      }, 2000);
    }

    async function start() {
      document.querySelector('#start').disabled = true;
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error('This iPhone WebView still does not expose camera capture to WebRTC.');
      }

      if (pc) {
        pc.onconnectionstatechange = null;
        pc.onicecandidate = null;
        pc.close();
        pc = null;
      }
      if (stream) {
        for (const track of stream.getTracks()) track.stop();
        stream = null;
      }
      seenReceiverCandidates = new Set();

      await signalJson('POST', '/signal/reset', {});
      pc = new RTCPeerConnection({ iceServers: [] });
      const activePc = pc;
      activePc.onconnectionstatechange = () => {
        if (pc !== activePc) return;
        setStatus('Connection: ' + activePc.connectionState);
        if (activePc.connectionState === 'failed' || activePc.connectionState === 'closed') {
          scheduleRestart(activePc.connectionState);
        } else if (activePc.connectionState === 'disconnected') {
          setTimeout(() => {
            if (pc === activePc && activePc.connectionState === 'disconnected') scheduleRestart('disconnected');
          }, 4000);
        }
      };
      activePc.onicecandidate = event => {
        if (event.candidate) signalJson('POST', '/signal/candidate/phone', event.candidate.toJSON()).catch(console.error);
      };

      stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          facingMode: { ideal: 'environment' },
          width: { ideal: 1280 },
          height: { ideal: 720 },
          frameRate: { ideal: 30, max: 30 }
        }
      });
      local.srcObject = stream;
      for (const track of stream.getTracks()) {
        track.addEventListener('ended', () => scheduleRestart('camera stopped'));
        activePc.addTrack(track, stream);
      }

      const offer = await activePc.createOffer({ offerToReceiveVideo: false });
      await activePc.setLocalDescription(offer);
      await signalJson('POST', '/signal/offer', activePc.localDescription.toJSON());
      setStatus('Offer sent. Waiting for Windows answer...');

      while (!activePc.currentRemoteDescription) {
        if (pc !== activePc) return;
        const answer = await signalJson('GET', '/signal/answer');
        if (answer && answer.type) await activePc.setRemoteDescription(answer);
        await sleep(500);
      }
      setStatus('Streaming to Windows over WebRTC.');
      pollReceiverCandidates(activePc);
    }

    async function pollReceiverCandidates(activePc) {
      while (pc === activePc) {
        try {
          const payload = await signalJson('GET', '/signal/candidates/receiver');
          for (const candidate of payload?.candidates ?? []) {
            const key = JSON.stringify(candidate);
            if (!seenReceiverCandidates.has(key)) {
              seenReceiverCandidates.add(key);
              await activePc.addIceCandidate(candidate);
            }
          }
        } catch (error) {
          console.error(error);
        }
        await sleep(500);
      }
    }

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible') return;
      if (pc && ['failed', 'disconnected', 'closed'].includes(pc.connectionState)) scheduleRestart('app resumed');
    });

    document.querySelector('#start').addEventListener('click', () => start().catch(error => {
      document.querySelector('#start').disabled = false;
      setStatus('Failed: ' + error.message);
    }));
  </script>
</body>
</html>
"""#
}
