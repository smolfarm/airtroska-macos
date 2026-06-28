import Foundation
import Network

/// A tiny HTTP server that serves a single file with byte-range support.
///
/// AirPlay to a third-party receiver (e.g. a Roku TV) needs the receiver to fetch
/// the media from a URL it can reach — a `file://` asset can't be handed off, so the
/// receiver sits on the splash. We serve the converted MP4 on the Mac's LAN IP and
/// give AVPlayer that `http://` URL instead.
final class LocalHTTPServer {
    private var listener: NWListener?
    private let fileURL: URL
    private let size: UInt64
    private(set) var port: UInt16 = 0

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.size = (attrs[.size] as? UInt64) ?? 0
    }

    /// The http:// URL AVPlayer should use. Must be the Mac's LAN IP (not 127.0.0.1)
    /// because the AirPlay receiver fetches this URL itself.
    var url: URL? {
        guard port != 0 else { return nil }
        let host = Self.lanIPv4() ?? "127.0.0.1"
        return URL(string: "http://\(host):\(port)/video.mp4")
    }

    func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
                sem.signal()
            } else if case .failed = state {
                sem.signal()
            }
        }
        listener.start(queue: .global())
        self.listener = listener
        _ = sem.wait(timeout: .now() + 2)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Per-connection

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        receiveRequest(conn) { request in
            self.respond(conn, request: request)
        }
    }

    private func receiveRequest(_ conn: NWConnection, completion: @escaping (String) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, _ in
            if let data, let s = String(data: data, encoding: .utf8) {
                completion(s)
            } else if isComplete {
                completion("")
            } else {
                conn.cancel()
            }
        }
    }

    private func respond(_ conn: NWConnection, request: String) {
        guard request.hasPrefix("GET") else { conn.cancel(); return }
        let range = parseRange(in: request)
        dbg("HTTP \(request.split(separator: "\r\n").first.map(String.init) ?? "?") range=\(range.map { "\($0.0)-\($0.1)" } ?? "none")")

        let (start, end, status) = resolve(range: range)
        let length = end - start + 1

        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: video/mp4\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if status == "206 Partial Content" {
            head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
        }
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"

        conn.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in
            self.streamBody(conn, start: start, length: length)
        })
    }

    private func streamBody(_ conn: NWConnection, start: UInt64, length: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { conn.cancel(); return }
        try? handle.seek(toOffset: start)
        let chunkSize: UInt64 = 1_048_576 // 1 MB

        func sendNext(remaining: UInt64) {
            if remaining == 0 {
                try? handle.close()
                conn.send(content: nil, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            let n = Int(min(chunkSize, remaining))
            let data = handle.readData(ofLength: n)
            if data.isEmpty {
                try? handle.close()
                conn.cancel()
                return
            }
            conn.send(content: data, completion: .contentProcessed { _ in
                sendNext(remaining: remaining - UInt64(data.count))
            })
        }
        sendNext(remaining: length)
    }

    // MARK: - Range parsing

    private func parseRange(in request: String) -> (UInt64, UInt64)? {
        // Split on the HTTP line terminator and isolate the Range header. Do NOT scan
        // Characters for "\r"/"\n": Swift treats a CRLF as a single grapheme cluster, so
        // `ch == "\r"` never matches and the scan swallows every following header into the
        // spec. That made the server return the whole file for `bytes=0-1` probes, which
        // AVFoundation rejects as "server is not correctly configured" (-12939) — the item
        // then fails (slashed-out play button) and there's nothing valid to hand the TV.
        let lines = request.components(separatedBy: "\r\n")
        guard let rangeLine = lines.first(where: { $0.range(of: "range:", options: .caseInsensitive) != nil }),
              let eq = rangeLine.range(of: "bytes=", options: .caseInsensitive) else { return nil }
        let spec = rangeLine[eq.upperBound...].trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let s = parts.first, let start = UInt64(s) else { return nil }
        let endVal: UInt64
        if parts.count > 1, let e = UInt64(parts[1]), e >= start {
            endVal = e
        } else {
            endVal = size > 0 ? size - 1 : 0
        }
        return (start, min(endVal, size > 0 ? size - 1 : 0))
    }

    private func resolve(range: (UInt64, UInt64)?) -> (UInt64, UInt64, String) {
        guard let (s, e) = range else {
            return (0, size > 0 ? size - 1 : 0, "200 OK")
        }
        return (s, e, "206 Partial Content")
    }

    // MARK: - LAN IP

    /// Pick a non-loopback, non-link-local IPv4 on the LAN (the address the AirPlay
    /// receiver can route to). Uses getifaddrs.
    static func lanIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for cursor in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = cursor.pointee
            guard let family = iface.ifa_addr?.pointee.sa_family, family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            if (iface.ifa_flags & UInt32(IFF_LOOPBACK)) != 0 { continue }
            let sin = iface.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var addr4 = sin.sin_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ip = String(cString: inet_ntop(AF_INET, &addr4, &buf, socklen_t(INET_ADDRSTRLEN)))
            if ip.isEmpty || ip.hasPrefix("169.254") { continue }
            if name.hasPrefix("en") || name.hasPrefix("bridge") { return ip }
            best = best ?? ip
        }
        return best
    }
}