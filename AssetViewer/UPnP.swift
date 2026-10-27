import Foundation
import Darwin

struct ViewerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
extension XMLElement {
    func elements(_ local: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == local }
    }
    func value(_ local: String) -> String { elements(local).first?.stringValue ?? "" }
}
struct Server: Identifiable, Hashable {
    let id: String
    let name: String
    let location: URL
    let control: URL?
    let serviceType: String
    let xml: String
}
struct Field: Identifiable {
    let id = UUID()
    let name: String
    let value: String
}
struct Asset: Identifiable {
    let id: String
    let title: String
    let container: Bool
    let fields: [Field]
    let xml: String
}
struct Page {
    let assets: [Asset]
    let total: Int
    let returned: Int
}
enum UPnP {
    static func document(_ data: Data) throws -> XMLDocument {
        try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }
    static func nodes(_ doc: XMLDocument, _ name: String) throws -> [XMLElement] {
        try doc.nodes(forXPath: "//*[local-name()='\(name)']").compactMap { $0 as? XMLElement }
    }
    static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ViewerError(message: "Invalid HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? nodes(document(data), "errorDescription").first?.stringValue) ?? ""
            throw ViewerError(message: "HTTP \(http.statusCode) \(detail)")
        }
        return data
    }
    static func describe(_ url: URL, timeout: TimeInterval = 15) async throws -> Server {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ViewerError(message: "Enter an HTTP or HTTPS device-description URL.") }
        let data = try await fetch(URLRequest(url: url, timeoutInterval: timeout))
        let doc = try document(data)
        guard let root = doc.rootElement(), root.localName == "root",
              !(try nodes(doc, "device")).isEmpty else {
            throw ViewerError(message: "The address did not return a UPnP device description.")
        }
        let services = try nodes(doc, "service")
        let service = services.first { $0.value("serviceType").contains(":ContentDirectory:") }
        let base = (try nodes(doc, "URLBase").first?.stringValue).flatMap { URL(string: $0) } ?? url
        let control = service.flatMap { URL(string: $0.value("controlURL"), relativeTo: base)?.absoluteURL }
        let name = try nodes(doc, "friendlyName").first?.stringValue ?? url.host ?? "UPnP device"
        let udn = try nodes(doc, "UDN").first?.stringValue ?? url.absoluteString
        return Server(id: udn, name: name, location: url, control: control, serviceType: service?.value("serviceType") ?? "", xml: doc.xmlString(options: [.nodePrettyPrint]))
    }
    // Hostnames are DNS / Bonjour hostnames, not arbitrary UPnP friendly names.
    static func resolve(_ input: String) async throws -> Server {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text.contains("://") ? text : "http://" + text),
              let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil else {
            throw ViewerError(message: "Enter a hostname, IP address, host:port, or HTTP(S) description URL.")
        }
        if !components.path.isEmpty && components.path != "/" {
            guard let url = components.url else { throw ViewerError(message: "Invalid URL") }
            return try await describe(url)
        }
        let ports: [Int?]
        if let port = components.port { ports = [port] }
        else if components.scheme == "https" { ports = [nil] }
        else { ports = [26125, nil, 8200, 49152] }
        let paths = ["/DeviceDescription.xml", "/description.xml", "/rootDesc.xml"]
        var candidates: [URL] = []
        components.query = nil; components.fragment = nil
        for port in ports {
            for path in paths {
                var candidate = components
                candidate.port = port; candidate.path = path
                if let url = candidate.url { candidates.append(url) }
            }
        }
        let found = await withTaskGroup(of: Server?.self, returning: Server?.self) { group in
            for url in candidates {
                group.addTask { try? await describe(url, timeout: 4) }
            }
            // Prefer browsable media servers; retain other UPnP devices as a fallback.
            var fallback: Server?
            for await result in group {
                if let server = result {
                    if server.control != nil { group.cancelAll(); return server }
                    fallback = fallback ?? server
                }
            }
            return fallback
        }
        guard let found else {
            throw ViewerError(message: "No UPnP description found at common locations on \(host). Check the hostname/IP and network access, specify host:port, or enter the full description URL if this server uses a custom location.")
        }
        return found
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func browse(_ server: Server, object: String, start: Int) async throws -> Page {
        guard let url = server.control else { throw ViewerError(message: "This device does not expose ContentDirectory browsing.") }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Browse xmlns:u="\(escape(server.serviceType))"><ObjectID>\(escape(object))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(start)</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(server.serviceType)#Browse\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)
        let response = try document(await fetch(request))
        guard let result = try nodes(response, "Result").first?.stringValue else { throw ViewerError(message: "Missing Browse result") }
        let didl = try document(Data(result.utf8))
        let assets = (didl.rootElement()?.children ?? []).compactMap { node -> Asset? in
            guard let e = node as? XMLElement, ["container", "item"].contains(e.localName ?? ""), let id = e.attribute(forName: "id")?.stringValue else { return nil }
            var fields = (e.attributes ?? []).map { Field(name: "@\($0.name ?? "")", value: $0.stringValue ?? "") }
            for child in (e.children ?? []).compactMap({ $0 as? XMLElement }) {
                let attributes = (child.attributes ?? []).map { "\($0.name ?? "")=\"\($0.stringValue ?? "")\"" }.joined(separator: " ")
                fields.append(Field(name: (child.name ?? "") + (attributes.isEmpty ? "" : " [\(attributes)]"), value: child.stringValue ?? ""))
            }
            // Serialize with the DIDL wrapper so inherited namespace declarations remain available.
            let wrapper = didl.rootElement()?.copy() as? XMLElement
            wrapper?.setChildren([e.copy() as! XMLElement])
            return Asset(id: id, title: e.value("title"), container: e.localName == "container", fields: fields, xml: wrapper?.xmlString(options: [.nodePrettyPrint]) ?? e.xmlString)
        }
        let returned = Int(try nodes(response, "NumberReturned").first?.stringValue ?? "") ?? assets.count
        let total = Int(try nodes(response, "TotalMatches").first?.stringValue ?? "") ?? (start + returned)
        return Page(assets: assets, total: total, returned: returned)
    }
    struct DiscoveryResult {
        let locations: [URL]
        let diagnostics: [String]
    }
    // SSDP replies are unicast to the source port of M-SEARCH. Keep one
    // explicitly bound socket per interface open throughout the receive window.
    static func discover() async throws -> DiscoveryResult {
        try await Task.detached(priority: .userInitiated) {
            var logs: [String] = []
            var interfaces: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&interfaces) == 0 else {
                throw ViewerError(message: "Cannot enumerate network interfaces: \(String(cString: strerror(errno)))")
            }
            defer { freeifaddrs(interfaces) }
            var sockets: [(fd: Int32, label: String)] = []
            defer { for entry in sockets { close(entry.fd) } }
            var cursor = interfaces
            var seen = Set<String>()
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                let interface = entry.pointee
                guard let addr = interface.ifa_addr,
                      Int32(addr.pointee.sa_family) == AF_INET,
                      interface.ifa_flags & UInt32(IFF_UP) != 0,
                      interface.ifa_flags & UInt32(IFF_MULTICAST) != 0,
                      interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
                let name = String(cString: interface.ifa_name)
                var local = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee
                var ip = local.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &ip, &text, socklen_t(INET_ADDRSTRLEN))
                let label = "\(name) · \(String(cString: text))"
                guard seen.insert(label).inserted else { continue }
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { logs.append("\(label): socket failed: \(String(cString: strerror(errno)))"); continue }
                local.sin_port = 0
                local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bound == 0 else {
                    logs.append("\(label): bind failed: \(String(cString: strerror(errno)))")
                    close(fd); continue
                }
                var outgoing = local.sin_addr
                guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outgoing, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                    logs.append("\(label): multicast interface failed: \(String(cString: strerror(errno)))")
                    close(fd); continue
                }
                let flags = fcntl(fd, F_GETFL, 0)
                guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    logs.append("\(label): nonblocking socket failed")
                    close(fd); continue
                }
                var ttl: UInt8 = 2
                if setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) != 0 {
                    logs.append("\(label): could not set multicast TTL")
                }
                sockets.append((fd, label))
                logs.append("Searching \(label)")
            }
            guard !sockets.isEmpty else {
                return DiscoveryResult(locations: [], diagnostics: logs + ["No usable IPv4 multicast interfaces. Check Wi-Fi/Ethernet and local network permission."])
            }
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(1900).bigEndian
            inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
            var reported = Set<String>()
            func sendSearches() {
                for entry in sockets {
                    for target in ["ssdp:all", "urn:schemas-upnp-org:device:MediaServer:1", "urn:schemas-upnp-org:service:ContentDirectory:1"] {
                        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
                        let sent = message.withCString { ptr in
                            withUnsafePointer(to: &destination) {
                                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                    sendto(entry.fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                }
                            }
                        }
                        if sent < 0 {
                            let failure = "\(entry.label): send failed: \(String(cString: strerror(errno)))"
                            if reported.insert(failure).inserted { logs.append(failure) }
                        }
                    }
                }
            }
            var locations = Set<URL>()
            var responseCounts: [Int32: Int] = [:]
            var buffer = [UInt8](repeating: 0, count: 65536)
            let start = Date()
            var nextSend = start
            let end = start.addingTimeInterval(10)
            while Date() < end {
                try Task.checkCancellation()
                if Date() >= nextSend && Date().timeIntervalSince(start) < 7 {
                    sendSearches()
                    nextSend = Date().addingTimeInterval(3)
                }
                var polls = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
                let ready = polls.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 200) }
                if ready < 0 {
                    if errno == EINTR { continue }
                    logs.append("Receive poll failed: \(String(cString: strerror(errno)))"); break
                }
                for descriptor in polls where descriptor.revents & Int16(POLLIN) != 0 {
                    // Limit each drain so a chatty device cannot starve other sockets.
                    for _ in 0..<100 {
                        let count = buffer.withUnsafeMutableBytes { recv(descriptor.fd, $0.baseAddress, $0.count, 0) }
                        if count < 0 {
                            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                                logs.append("Receive failed: \(String(cString: strerror(errno)))")
                            }
                            break
                        }
                        responseCounts[descriptor.fd, default: 0] += 1
                        let response = String(decoding: buffer.prefix(count), as: UTF8.self)
                        for line in response.components(separatedBy: .newlines) {
                            let pair = line.split(separator: ":", maxSplits: 1)
                            if pair.count == 2,
                               pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "location",
                               let url = URL(string: pair[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                locations.insert(url)
                            }
                        }
                    }
                }
            }
            for entry in sockets { logs.append("\(entry.label): \(responseCounts[entry.fd, default: 0]) SSDP replies") }
            logs.append("\(locations.count) unique device-description URLs")
            if locations.isEmpty {
                logs.append("No replies with a usable LOCATION. Check Local Network permission, firewall, VPN and VLAN/multicast filtering. Allow permission, then click Discover again.")
            }
            return DiscoveryResult(locations: locations.sorted { $0.absoluteString < $1.absoluteString }, diagnostics: logs)
        }.value
    }
}
