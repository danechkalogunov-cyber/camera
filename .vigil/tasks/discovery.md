# ASSIGNMENT: discovery

AGENT_LABEL for your log lines is: spec:discovery
Write the file: /home/user/camera/docs/spec-discovery.md

Author the camera discovery specification (module VigilDiscovery plus macOS transport notes).
Cover three mechanisms in the order we run them, with exact wire formats:
1) **Hikvision SADP**: UDP multicast to 239.255.255.250 port 37020 from a local port (37020
   preferred), the Probe payload carrying a Uuid and Types=inquiry, and the ProbeMatch response
   fields (Types, DeviceType, DeviceDescription, DeviceSN, CommandPort, HttpPort, MAC,
   IPv4Address, IPv4SubnetMask, IPv4Gateway, IPv6Address, DSPVersion, BootTime, Activated,
   PasswordResetAbility, SupportHCPlatform). Give a realistic sample response XML. Note that
   Activated=false means the camera needs activation and we must surface that in the UI. Note the
   newer obfuscated SADP variants and how we degrade gracefully.
2) **ONVIF WS-Discovery**: UDP multicast to 239.255.255.250 port 3702, the exact SOAP 1.2 Probe
   envelope including a NetworkVideoTransmitter type and a uuid MessageID, and parsing
   ProbeMatches for XAddrs and Scopes (extract the onvif.org name, hardware and location scopes).
   Specify the retry policy (3 probes 500 ms apart) and note that responses arrive from arbitrary
   source ports so we must listen on the sending socket.
3) **Targeted subnet sweep**: enumerate local IPv4 interfaces and netmasks (getifaddrs in the
   macOS layer, pure CIDR maths in the module, with a guard that refuses to sweep prefixes wider
   than /16), then concurrent TCP connect probes to ports 554, 80, 8000, 443, 8080 with a tight
   350 ms timeout and bounded concurrency of about 128 in flight, then an RTSP OPTIONS plus an
   HTTP GET /ISAPI/System/deviceInfo fingerprint to classify Hikvision versus other (also detect
   Dahua and Axis so we can tell the user "found, but not Hikvision"). Include reading the ARP
   cache as a shortcut, and an NWBrowser Bonjour browse of _rtsp._tcp and _http._tcp.
Then specify: the **merge and dedupe model** (identity = MAC, else serial, else ip:port; how
records from multiple sources merge; how we detect a camera whose IP changed), the
DiscoveredDevice value type, progress reporting for the UI (found count, swept count, ETA),
cancellation, and the required macOS entitlements and Info.plist keys for multicast
(com.apple.developer.networking.multicast plus NSLocalNetworkUsageDescription) and exactly what
happens if the multicast entitlement is absent (fall back to the unicast sweep) - spell out the
user-facing consequence and the local-network permission prompt flow, this matters a lot.
Give the full public Swift API and a set of unit tests driven by recorded packet bytes.

Create parent directories if needed. Be exhaustive and concrete.
