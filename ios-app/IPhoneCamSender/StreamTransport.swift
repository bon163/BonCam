import Foundation
import Network
import UIKit

protocol StreamTransportDelegate: AnyObject {
    func transportDidReceivePairCode(_ code: String)
    func transportDidStartStream(sessionID: UUID, config: SessionConfig)
    func transportDidStopStream(reason: String?)
}

actor StreamTransport {
    private weak var delegate: StreamTransportDelegate?
    private let controlPort: UInt16 = 41000
    private var connection: NWConnection?
    private var videoConnection: NWConnection?
    private var host: NWEndpoint.Host?
    private var sessionID = UUID()

    func setDelegate(_ delegate: StreamTransportDelegate) {
        self.delegate = delegate
    }

    func connect(host: String) async throws {
        let host = NWEndpoint.Host(host)
        self.host = host
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: controlPort)!, using: .tcp)
        self.connection = connection
        connection.start(queue: .global())
        receiveMessages(on: connection)
    }

    func sendPairRequest(code: String, deviceName: String) async {
        let message = ControlMessage.pairRequest(PairRequest(
            protocolVersion: 1,
            deviceID: UIDevice.current.identifierForVendor ?? UUID(),
            deviceName: deviceName,
            pairCode: code
        ))
        await send(message)
    }

    func sendSwitchCamera(position: CameraPosition) async {
        let message = ControlMessage.switchCamera(SwitchCamera(protocolVersion: 1, sessionID: sessionID, cameraPosition: position))
        await send(message)
    }

    func sendPreset(_ preset: StreamPreset) async {
        let message = ControlMessage.setPreset(SetPreset(protocolVersion: 1, sessionID: sessionID, preset: preset))
        await send(message)
    }

    func sendStatus(_ kind: StatusEventKind, detail: String?) async {
        let message = ControlMessage.statusEvent(StatusEvent(protocolVersion: 1, sessionID: sessionID, kind: kind, detail: detail))
        await send(message)
    }

    func stopStreaming(reason: String) async {
        let message = ControlMessage.stopStream(StopStream(protocolVersion: 1, sessionID: sessionID, reason: reason))
        await send(message)
        connection?.cancel()
        videoConnection?.cancel()
    }

    func sendVideo(frame: EncodedFrame) async {
        guard let host else { return }
        if videoConnection == nil {
            let tcpConnection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: 41001)!, using: .tcp)
            tcpConnection.start(queue: .global())
            videoConnection = tcpConnection
        }

        sessionID = frame.sessionID
        let mtu = frame.streamKind == .jpegPreview ? 4096 : 1200
        let packetCount = UInt16((frame.data.count + mtu - 1) / mtu)

        for packetIndex in 0..<packetCount {
            let start = Int(packetIndex) * mtu
            let end = min(start + mtu, frame.data.count)
            let payload = frame.data.subdata(in: start..<end)
            let header = VideoPacketHeader(
                sessionID: frame.sessionID,
                streamKind: frame.streamKind,
                frameID: frame.frameID,
                packetIndex: packetIndex,
                packetCount: packetCount,
                timestampUS: frame.timestampUS,
                isKeyframe: frame.isKeyframe
            )
            guard let headerData = try? makeEncoder().encode(header) else { continue }
            var packet = Data()
            var headerLength = UInt32(headerData.count).bigEndian
            packet.append(Data(bytes: &headerLength, count: 4))
            packet.append(headerData)
            packet.append(payload)

            var packetLength = UInt32(packet.count).bigEndian
            var framedPacket = Data(bytes: &packetLength, count: 4)
            framedPacket.append(packet)
            videoConnection?.send(content: framedPacket, completion: .contentProcessed { _ in })
        }
    }

    private func send(_ message: ControlMessage) async {
        guard let connection, let data = try? makeEncoder().encode(message) else { return }
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func receiveMessages(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task {
                    await self.handleInbound(data)
                }
            }
            if error == nil && !isComplete {
                Task {
                    await self.receiveMessages(on: connection)
                }
            }
        }
    }

    private func handleInbound(_ raw: Data) {
        let messages = raw.split(separator: 0x0A)
        for rawMessage in messages {
            guard let message = try? makeDecoder().decode(ControlMessage.self, from: Data(rawMessage)) else { continue }
            switch message {
            case .pairCodeRequired(let payload):
                delegate?.transportDidReceivePairCode(payload.code)
            case .pairConfirm(let payload):
                sessionID = payload.sessionID
            case .startStream(let payload):
                sessionID = payload.sessionID
                delegate?.transportDidStartStream(sessionID: payload.sessionID, config: payload.config)
                let streamInfo = StreamInfo(
                    codec: "h264",
                    width: payload.config.preset == .hd720p30 ? 1280 : 1920,
                    height: payload.config.preset == .hd720p30 ? 720 : 1080,
                    fps: payload.config.fps,
                    orientationDegrees: 0,
                    deviceName: UIDevice.current.name
                )
                Task {
                    await send(.streamStarted(StreamStarted(protocolVersion: 1, sessionID: payload.sessionID, info: streamInfo)))
                }
            case .stopStream(let payload):
                delegate?.transportDidStopStream(reason: payload.reason)
            default:
                break
            }
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
