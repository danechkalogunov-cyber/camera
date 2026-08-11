//
//  RTSPConnection+UDP.swift
//  VigilTransport
//
//  Network.framework UDP flows used by RTSP unicast and multicast sessions.
//

#if os(macOS)

import Foundation
import Network
import VigilProtocols
import VigilRTSP

extension RTSPConnection {

    /// Joins the server-selected multicast destination on both RTP and RTCP ports.
    /// Entitlement inspection provides an early named failure; group state is still authoritative.
    func prepareMulticast(trackID: Int, endpoint: RTSPMulticastEndpoint) -> Bool {
        guard EntitlementInspector.multicastEntitlementPresent() else {
            logger.error(.transport, "multicast entitlement missing",
                         ["track": String(trackID)])
            deliverFailure(.transport(.multicastBlocked))
            return false
        }
        return openMulticast(destination: endpoint.destination, port: endpoint.ports.rtp,
                             ttl: endpoint.timeToLive)
            && openMulticast(destination: endpoint.destination, port: endpoint.ports.rtcp,
                             ttl: endpoint.timeToLive)
    }

    private func openMulticast(destination: String, port: UInt16, ttl: UInt8) -> Bool {
        if multicastGroups[port] != nil { return true }
        guard let address = Network.IPv4Address(destination),
              let groupPort = NWEndpoint.Port(rawValue: port) else {
            deliverFailure(.rtsp(.transportRejected))
            return false
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(address), port: groupPort)
        guard let descriptor = try? NWMulticastGroup(for: [endpoint], disableUnicast: true) else {
            deliverFailure(.rtsp(.transportRejected))
            return false
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        // Follow the route selected by the already-established RTSP control connection. This is
        // essential on a Mac connected to both Ethernet and Wi-Fi: an unpinned multicast join may
        // otherwise land on the interface that cannot reach the camera's VLAN.
        if let path = socket?.currentPath,
           let interface = path.availableInterfaces.first(where: {
               path.usesInterfaceType($0.type)
           }) {
            parameters.requiredInterface = interface
        }
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
            ip.hopLimit = ttl
        }
        let group = NWConnectionGroup(with: descriptor, using: parameters)
        group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: false) {
            [weak self, weak group] _, content, _ in
            guard let self, let group, let content, !content.isEmpty else { return }
            Task { await self.receivedMulticast(content, on: group, localPort: port) }
        }
        group.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case let .failed(error) = state {
                Task { await self.multicastFailed(error, localPort: port) }
            }
        }
        multicastGroups[port] = group
        multicastDestinations[port] = endpoint
        group.start(queue: queue)
        return true
    }

    private func receivedMulticast(_ data: Data, on group: NWConnectionGroup,
                                   localPort: UInt16) {
        guard lifecycle == .running, multicastGroups[localPort] === group else { return }
        execute(machine.ingestUDP(data, localPort: localPort, now: clock.now()))
    }

    private func multicastFailed(_ error: NWError, localPort: UInt16) {
        guard lifecycle == .running, let group = multicastGroups[localPort] else { return }
        multicastGroups.removeValue(forKey: localPort)
        multicastDestinations.removeValue(forKey: localPort)
        group.cancel()
        logger.error(.transport, "multicast group failed",
                     ["port": String(localPort), "error": String(describing: error)])
        deliverFailure(.transport(.multicastBlocked))
    }

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
        if let group = multicastGroups[localPort],
           let destination = multicastDestinations[localPort] {
            group.send(content: payload, to: destination) { [weak self] error in
                guard let self, let error else { return }
                Task { await self.multicastFailed(error, localPort: localPort) }
            }
            return
        }
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
