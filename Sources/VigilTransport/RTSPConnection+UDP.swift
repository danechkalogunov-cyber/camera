//
//  RTSPConnection+UDP.swift
//  VigilTransport
//
//  Network.framework UDP flows used by RTSP unicast sessions.
//

#if os(macOS)

import Foundation
import Network
import VigilProtocols
import VigilRTSP

extension RTSPConnection {

    /// Opens the connected RTP and RTCP datagram flows described by a successful SETUP.
    ///
    /// A connected UDP `NWConnection` gives Network.framework both endpoints, while
    /// `requiredLocalEndpoint` guarantees that the source port is the one advertised as
    /// `client_port`. SETUP responses are processed synchronously, so these are started before the
    /// machine queues PLAY and consequently before the camera is allowed to send media.
    func prepareUDP(for track: RTSPTrack) -> Bool {
        guard let client = track.clientPorts, let server = track.serverPorts,
              let hostText = connectedHostText else {
            deliverFailure(.rtsp(.transportRejected))
            return false
        }
        return openUDP(localPort: client.rtp, remotePort: server.rtp, hostText: hostText)
            && openUDP(localPort: client.rtcp, remotePort: server.rtcp, hostText: hostText)
    }

    private func openUDP(localPort: UInt16, remotePort: UInt16, hostText: String) -> Bool {
        if udpSockets[localPort] != nil { return true }
        guard let local = NWEndpoint.Port(rawValue: localPort),
              let remote = NWEndpoint.Port(rawValue: remotePort) else { return false }

        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("0.0.0.0"), port: local)
        let connection = NWConnection(host: NWEndpoint.Host(hostText), port: remote,
                                      using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                Task { await self?.receiveUDP(on: connection, localPort: localPort) }
            case .failed(let error):
                Task { await self?.udpFailed(error, localPort: localPort) }
            default:
                break
            }
        }
        udpSockets[localPort] = connection
        connection.start(queue: queue)
        return true
    }

    func receiveUDP(on connection: NWConnection, localPort: UInt16) {
        guard lifecycle == .running, udpSockets[localPort] === connection else { return }
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            Task {
                await self.receivedUDP(data, error: error, on: connection,
                                       localPort: localPort)
            }
        }
    }

    private func receivedUDP(_ data: Data?, error: NWError?, on connection: NWConnection,
                             localPort: UInt16) {
        guard lifecycle == .running, udpSockets[localPort] === connection else { return }
        if let error {
            udpFailed(error, localPort: localPort)
            return
        }
        if let data, !data.isEmpty {
            execute(machine.ingestUDP(data, localPort: localPort, now: clock.now()))
        }
        receiveUDP(on: connection, localPort: localPort)
    }

    func sendUDP(_ payload: Data, from localPort: UInt16) {
        guard let connection = udpSockets[localPort] else {
            deliverFailure(.rtsp(.transportRejected))
            return
        }
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { await self?.udpFailed(error, localPort: localPort) }
        })
    }

    func udpFailed(_ error: NWError, localPort: UInt16) {
        guard lifecycle == .running, udpSockets.removeValue(forKey: localPort) != nil else { return }
        logger.error(.transport, "UDP flow failed",
                     ["localPort": String(localPort), "error": String(describing: error)])
        deliverFailure(.rtsp(.transportRejected))
    }
}

#endif
