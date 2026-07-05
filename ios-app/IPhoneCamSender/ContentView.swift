import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WebKit

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showingSettings = false
    @State private var showingWebRTC = false

    var body: some View {
        GeometryReader { geometry in
            let metrics = LayoutMetrics(geometry: geometry)

            ZStack {
                AppBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: metrics.sectionSpacing) {
                        topBar(metrics: metrics)
                        heroPanel(metrics: metrics)
                        statusStrip(metrics: metrics)
                        connectionPanel(metrics: metrics)
                        controlsPanel(metrics: metrics)
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.bottomPadding)
                }
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingWebRTC) {
                WebRTCSenderView(
                    hostAddress: appModel.hostAddress,
                    initialFacing: appModel.cameraPosition == .back ? "environment" : "user",
                    initialQuality: appModel.selectedPreset == .hd720p30 ? 720 : 1080,
                    onStatus: { appModel.webRTCStatusChanged($0) },
                    onConfig: { facing, quality in appModel.applyWebRTCConfig(facing: facing, quality: quality) }
                )
                .ignoresSafeArea()
                .onDisappear { appModel.webRTCStatusChanged("Idle") }
            }
            .onAppear { appModel.startPreview() }
            .onChange(of: showingWebRTC) { _, presented in
                if presented {
                    appModel.stopPreview()
                } else {
                    appModel.startPreview()
                }
            }
        }
    }

    private func topBar(metrics: LayoutMetrics) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("BonCam")
                    .font(.system(size: metrics.brandSize, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("Turn your iPhone into a clean live camera feed for Windows.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: metrics.iconButtonSize, height: metrics.iconButtonSize)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }
            }
            .accessibilityLabel("Settings")
        }
    }

    private func heroPanel(metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                CameraPreviewView(session: appModel.captureManager.session)
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.previewCornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: metrics.previewCornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 1)
                    }

                LinearGradient(
                    colors: [.black.opacity(0.42), .clear, .black.opacity(0.56)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: metrics.previewCornerRadius, style: .continuous))

                HStack {
                    Label(appModel.isStreaming ? "Broadcasting" : "Ready to stream", systemImage: appModel.isStreaming ? "dot.radiowaves.left.and.right" : "sparkles")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(appModel.isStreaming ? Color.green : Color.cyan)
                        .background(.black.opacity(0.32), in: Capsule())

                    Spacer()

                    Label(appModel.cameraPosition == .back ? "Back" : "Front", systemImage: appModel.cameraPosition == .back ? "camera.fill" : "person.crop.square.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.32), in: Capsule())
                }
                .padding(16)

                VStack(alignment: .leading, spacing: 8) {
                    Spacer()

                    Text("Framed for every iPhone")
                        .font(.system(size: metrics.heroTitleSize, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(appModel.hostAddress.isEmpty ? "Add your Windows host in settings to start streaming." : "Streaming target: \(appModel.hostAddress)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            HStack(spacing: 12) {
                MetricChip(title: "Quality", value: appModel.selectedPreset.displayName, accent: .cyan)
                MetricChip(title: "Status", value: appModel.connectionState, accent: connectionColor(for: appModel.connectionState))
            }
        }
        .shadow(color: .black.opacity(0.30), radius: 30, x: 0, y: 18)
    }

    private func statusStrip(metrics: LayoutMetrics) -> some View {
        HStack(spacing: 12) {
            StatusPill(
                title: "Connection",
                value: appModel.connectionState,
                systemImage: "antenna.radiowaves.left.and.right",
                accent: connectionColor(for: appModel.connectionState)
            )

            StatusPill(
                title: "Pair code",
                value: appModel.pairCode.isEmpty ? "Waiting" : appModel.pairCode,
                systemImage: "key.fill",
                accent: appModel.pairCode.isEmpty ? .white.opacity(0.72) : .yellow
            )
        }
    }

    private func connectionPanel(metrics: LayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Session")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)

                Spacer()

                ConnectionBadge(state: appModel.connectionState)
            }

            GlassPanel {
                HStack(spacing: 14) {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "desktopcomputer")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.cyan)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Windows host")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.58))

                        Text(appModel.hostAddress.isEmpty ? "Add an IP address in settings" : appModel.hostAddress)
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    Spacer(minLength: 0)
                }
            }

            Text("Landscape is supported for cleaner framing, and the preview now scales edge-to-edge while still respecting the Dynamic Island and home indicator.")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlsPanel(metrics: LayoutMetrics) -> some View {
        VStack(spacing: 14) {
            Button {
                showingWebRTC = true
            } label: {
                Label("Start Stream", systemImage: "play.fill")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.primaryButtonHeight)
            }
            .buttonStyle(PrimaryControlButtonStyle())

            HStack(spacing: 12) {
                Button {
                    appModel.switchCamera()
                } label: {
                    Label("Switch camera", systemImage: "arrow.triangle.2.circlepath.camera.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.secondaryButtonHeight)
                }
                .buttonStyle(SecondaryControlButtonStyle())

                Button {
                    appModel.togglePreset()
                } label: {
                    Label(appModel.selectedPreset == .hd720p30 ? "Use 1080p" : "Use 720p", systemImage: "rectangle.inset.filled")
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.secondaryButtonHeight)
                }
                .buttonStyle(SecondaryControlButtonStyle(accent: .mint))
            }
        }
    }

    private func connectionColor(for state: String) -> Color {
        let normalized = state.lowercased()
        if normalized.contains("stream") || normalized.contains("connected") {
            return .green
        }
        if normalized.contains("pair") {
            return .yellow
        }
        if normalized.contains("fail") {
            return .red
        }
        return .white.opacity(0.72)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Host setup")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Windows host IP")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.62))

                            TextField("192.168.1.10", text: $appModel.hostAddress)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(.white.opacity(0.08), lineWidth: 1)
                                }

                            Text("Use the IP address of the Windows machine receiving the camera stream.")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("Current setup")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    VStack(spacing: 12) {
                        SettingsInfoRow(title: "Camera", value: appModel.cameraPosition == .back ? "Back" : "Front", systemImage: "camera.fill")
                        SettingsInfoRow(title: "Quality", value: appModel.selectedPreset.displayName, systemImage: "rectangle.inset.filled")
                        SettingsInfoRow(title: "Status", value: appModel.connectionState, systemImage: "waveform.path.ecg")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") {
                    dismiss()
                }
                .font(.headline.weight(.semibold))
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }
}

struct SettingsInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        GlassPanel {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 24)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
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

struct StatusPill: View {
    let title: String
    let value: String
    let systemImage: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.62))

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct MetricChip: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.black))
                .foregroundStyle(.white.opacity(0.54))

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.04, blue: 0.06),
                    Color(red: 0.05, green: 0.10, blue: 0.13),
                    Color(red: 0.12, green: 0.10, blue: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 80)
                .offset(x: -120, y: -240)

            Circle()
                .fill(Color.orange.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: 160, y: 260)
        }
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
                    colors: isDestructive ? [Color(red: 0.92, green: 0.24, blue: 0.35), Color(red: 0.98, green: 0.48, blue: 0.54)] : [Color(red: 0.39, green: 0.96, blue: 0.88), Color(red: 0.82, green: 0.94, blue: 0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: (isDestructive ? Color.red : Color.cyan).opacity(0.22), radius: 18, x: 0, y: 12)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.80), value: configuration.isPressed)
    }
}

struct SecondaryControlButtonStyle: ButtonStyle {
    var accent: Color = .cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accent.opacity(0.26), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.80), value: configuration.isPressed)
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

private struct LayoutMetrics {
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let sectionSpacing: CGFloat
    let previewHeight: CGFloat
    let previewCornerRadius: CGFloat
    let primaryButtonHeight: CGFloat
    let secondaryButtonHeight: CGFloat
    let iconButtonSize: CGFloat
    let brandSize: CGFloat
    let heroTitleSize: CGFloat

    init(geometry: GeometryProxy) {
        let width = geometry.size.width
        let height = geometry.size.height
        let safeTop = geometry.safeAreaInsets.top
        let safeBottom = geometry.safeAreaInsets.bottom
        let compactHeight = height < 760
        let compactWidth = width < 390

        horizontalPadding = compactWidth ? 16 : 20
        topPadding = max(safeTop, 12) + 10
        bottomPadding = max(safeBottom, 18) + 14
        sectionSpacing = compactHeight ? 14 : 18
        previewHeight = min(max(height * (compactHeight ? 0.38 : 0.42), 300), compactHeight ? 360 : 430)
        previewCornerRadius = compactWidth ? 26 : 32
        primaryButtonHeight = compactHeight ? 52 : 58
        secondaryButtonHeight = compactHeight ? 46 : 50
        iconButtonSize = compactWidth ? 48 : 52
        brandSize = compactWidth ? 28 : 34
        heroTitleSize = compactWidth ? 26 : 32
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
    let initialFacing: String
    let initialQuality: Int
    let onStatus: (String) -> Void
    let onConfig: (String, Int) -> Void

    init(
        hostAddress: String,
        initialFacing: String,
        initialQuality: Int,
        onStatus: @escaping (String) -> Void,
        onConfig: @escaping (String, Int) -> Void
    ) {
        self.hostAddress = hostAddress
        self.initialFacing = initialFacing
        self.initialQuality = initialQuality
        self.onStatus = onStatus
        self.onConfig = onConfig
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostAddress: hostAddress, onStatus: onStatus, onConfig: onConfig)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "signal")
        contentController.add(context.coordinator, name: "status")
        contentController.add(context.coordinator, name: "config")

        let facingLiteral = initialFacing == "user" ? "user" : "environment"
        let quality = initialQuality == 1080 ? 1080 : 720
        let seedScript = "window.__initialFacing = '\(facingLiteral)'; window.__initialQuality = \(quality);"
        contentController.addUserScript(WKUserScript(source: seedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.webView = webView
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
        let onStatus: (String) -> Void
        let onConfig: (String, Int) -> Void
        weak var webView: WKWebView?

        init(hostAddress: String, onStatus: @escaping (String) -> Void, onConfig: @escaping (String, Int) -> Void) {
            self.hostAddress = hostAddress
            self.onStatus = onStatus
            self.onConfig = onConfig
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "status" {
                if let text = message.body as? String {
                    Task { @MainActor in self.onStatus(text) }
                }
                return
            }

            if message.name == "config" {
                if let payload = message.body as? [String: Any],
                   let facing = payload["facing"] as? String,
                   let quality = payload["quality"] as? Int {
                    Task { @MainActor in self.onConfig(facing, quality) }
                }
                return
            }

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
    :root {
      color-scheme: dark;
      --ink: #f5efe2;
      --muted: #c9bfae;
      --panel: rgba(22, 28, 30, .78);
      --line: rgba(255,255,255,.14);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: Avenir Next, ui-rounded, system-ui, sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at top left, #2d4d48, transparent 34rem), linear-gradient(135deg, #101719, #202319 55%, #3b2f1f);
      overflow: hidden;
    }
    video {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      object-fit: contain;
      background: #050708;
    }
    .panel {
      position: fixed;
      left: 18px;
      right: 18px;
      bottom: 18px;
      max-width: 620px;
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 22px;
      background: var(--panel);
      backdrop-filter: blur(18px);
      box-shadow: 0 20px 70px rgba(0,0,0,.35);
    }
    h1 { margin: 0 0 8px; font-size: clamp(24px, 5vw, 42px); letter-spacing: -.04em; }
    p { margin: 0 0 14px; color: var(--muted); line-height: 1.45; }
    button {
      border: 0;
      border-radius: 999px;
      padding: 12px 16px;
      color: #14201d;
      background: #f2c46d;
      font: inherit;
      font-weight: 700;
    }
    button:disabled { opacity: .5; }
    .row { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
    .row #start { flex: 1 1 auto; }
    button.ghost {
      color: var(--ink);
      background: rgba(255,255,255,.10);
      border: 1px solid var(--line);
    }
  </style>
</head>
<body>
  <video id="local" autoplay playsinline muted></video>
  <div class="panel">
    <h1>iPhone Sender</h1>
    <p id="status">Ready to start the WebRTC camera stream to the configured host.</p>
    <div class="row">
      <button id="start">Start WebRTC stream</button>
      <button id="flip" class="ghost">Flip camera</button>
      <button id="quality" class="ghost">720p</button>
    </div>
  </div>
  <script>
    const statusEl = document.querySelector('#status');
    const local = document.querySelector('#local');
    const startButton = document.querySelector('#start');
    const flipButton = document.querySelector('#flip');
    const qualityButton = document.querySelector('#quality');
    const pendingSignals = new Map();
    let seenReceiverCandidates = new Set();
    let pc;
    let stream;
    let restartTimer = null;
    let currentFacing = window.__initialFacing === 'user' ? 'user' : 'environment';
    let currentQuality = window.__initialQuality === 1080 ? 1080 : 720;

    function setStatus(message) {
      statusEl.textContent = message;
      try { window.webkit.messageHandlers.status.postMessage(message); } catch (e) {}
    }

    function reportConfig() {
      try {
        window.webkit.messageHandlers.config.postMessage({ facing: currentFacing, quality: currentQuality });
      } catch (e) {}
    }

    function updateControlLabels() {
      qualityButton.textContent = currentQuality + 'p';
      flipButton.textContent = currentFacing === 'user' ? 'Front camera' : 'Back camera';
    }

    function videoConstraints() {
      const dims = currentQuality === 1080 ? { w: 1920, h: 1080 } : { w: 1280, h: 720 };
      return {
        facingMode: { ideal: currentFacing },
        width: { ideal: dims.w },
        height: { ideal: dims.h },
        frameRate: { ideal: 30, max: 30 }
      };
    }

    // Pin the outgoing encoding so WebRTC does not silently downscale on this LAN.
    // Without this the default congestion controller uses degradationPreference
    // 'balanced', which drops RESOLUTION at the first hint of packet loss (always
    // present on Wi-Fi) and is slow to ramp back — the "quality dropped" symptom.
    // We are on a local link with bandwidth to spare, so cap the bitrate high and
    // tell the encoder to keep resolution and shed framerate instead if it must.
    async function applyEncodingParameters(sender) {
      if (!sender) return;
      try {
        const params = sender.getParameters();
        if (!params.encodings || params.encodings.length === 0) params.encodings = [{}];
        params.encodings[0].maxBitrate = currentQuality === 1080 ? 10000000 : 5000000;
        params.encodings[0].maxFramerate = 30;
        // Honored where supported (harmless where not); keeps sharpness on drops.
        params.degradationPreference = 'maintain-resolution';
        await sender.setParameters(params);
      } catch (error) {
        console.error('setParameters failed', error);
      }
    }

    // Live camera/quality change: re-capture and hot-swap the outgoing track without
    // renegotiating. If we are not streaming yet, the new settings apply on the next start().
    async function applyCameraChange() {
      updateControlLabels();
      reportConfig();
      if (!pc || !stream) return;
      flipButton.disabled = true;
      qualityButton.disabled = true;
      try {
        const newStream = await navigator.mediaDevices.getUserMedia({ audio: false, video: videoConstraints() });
        const newTrack = newStream.getVideoTracks()[0];
        const sender = pc.getSenders().find(s => s.track && s.track.kind === 'video');
        if (sender) {
          await sender.replaceTrack(newTrack);
          // Re-apply: the 1080<->720 toggle changes the target bitrate.
          await applyEncodingParameters(sender);
        }
        for (const track of stream.getTracks()) track.stop();
        stream = newStream;
        local.srcObject = stream;
        await local.play().catch(() => {});
        newTrack.addEventListener('ended', () => scheduleRestart('camera stopped'));
        setStatus('Streaming to Windows over WebRTC.');
      } catch (error) {
        setStatus('Camera switch failed: ' + (error && error.message ? error.message : error));
      } finally {
        flipButton.disabled = false;
        qualityButton.disabled = false;
      }
    }

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
      startButton.disabled = true;
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

      stream = await navigator.mediaDevices.getUserMedia({ audio: false, video: videoConstraints() });
      local.srcObject = stream;
      await local.play().catch(() => {});
      for (const track of stream.getTracks()) {
        track.addEventListener('ended', () => scheduleRestart('camera stopped'));
        activePc.addTrack(track, stream);
      }
      await applyEncodingParameters(activePc.getSenders().find(s => s.track && s.track.kind === 'video'));

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
      reportConfig();
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

    startButton.addEventListener('click', () => start().catch(error => {
      startButton.disabled = false;
      setStatus(error && error.message ? error.message : 'Unable to access the camera.');
    }));

    flipButton.addEventListener('click', () => {
      currentFacing = currentFacing === 'user' ? 'environment' : 'user';
      applyCameraChange();
    });

    qualityButton.addEventListener('click', () => {
      currentQuality = currentQuality === 720 ? 1080 : 720;
      applyCameraChange();
    });

    updateControlLabels();
    reportConfig();
  </script>
</body>
</html>
"""#
}
