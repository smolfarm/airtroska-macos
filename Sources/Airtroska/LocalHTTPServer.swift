import Foundation
import Network

/// A tiny HTTP/1.1 server that serves a single file with byte-range support.
///
/// AirPlay to a third-party receiver (e.g. a Roku or Vizio TV) needs the receiver to fetch
/// the media from a URL it can reach — a `file://` asset can't be handed off, so the
/// receiver sits on the splash. We serve the converted MP4 on the Mac's LAN IP and
/// give AVPlayer that `http://` URL instead.
///
/// A TV's media player is less forgiving than AVFoundation: it may probe with `HEAD`, ask
/// for suffix ranges (`bytes=-N`), and reuse one connection for many range requests. Those
/// mistakes tend to surface as endless re-buffering on the TV rather than a clean error, so
/// the server handles all of them the way a real file server would.
final class LocalHTTPServer {
    private var listener: NWListener?
    private let fileURL: URL
    private let size: UInt64
    private(set) var port: UInt16 = 0

    /// All socket I/O runs on this serial queue, so per-connection state needs no locking.
    private let queue = DispatchQueue(label: "airtroska.http")
    /// Open connections (queue-confined), so `stop()` can close keep-alive sockets the
    /// receiver left idle instead of leaking them.
    private var clients: [ObjectIdentifier: Client] = [:]
    /// Numbers connections in the log so a receiver's requests can be told apart.
    private var nextClientID = 0

    /// One connection's state (queue-confined). Exactly one `receive` is outstanding for the
    /// connection's whole life — including while a response body is going out — so a
    /// request the client pipelines, or the client hanging up, is seen as it happens rather
    /// than sitting unread in the socket until the body is done.
    private final class Client {
        let id: Int
        let conn: NWConnection
        /// Received bytes not yet parsed into a request.
        var inbox = Data()
        /// A response is being sent.
        var busy = false
        /// The client finished sending (FIN) or the receive failed.
        var peerClosed = false
        init(id: Int, conn: NWConnection) { self.id = id; self.conn = conn }
    }

    private static let chunkSize = 1_048_576 // 1 MB
    /// Log a body's progress every this many bytes.
    private static let reportEvery: UInt64 = 16 * 1_048_576
    private static let maxHeadBytes = 64 * 1024
    private static let headTerminator = Data("\r\n\r\n".utf8)

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
        let listener = try NWListener(using: .tcp, on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = listener.port?.rawValue ?? 0
                sem.signal()
            } else if case .failed = state {
                sem.signal()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = sem.wait(timeout: .now() + 2)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [self] in
            for client in clients.values { client.conn.cancel() }
            clients.removeAll()
        }
    }

    // MARK: - Per-connection

    private func accept(_ conn: NWConnection) {
        nextClientID += 1
        let client = Client(id: nextClientID, conn: conn)
        let key = ObjectIdentifier(conn)
        let id = client.id
        clients[key] = client
        dbg("http #\(id) open from \(conn.endpoint)")
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                dbg("http #\(id) failed: \(error)")
                self?.clients[key] = nil
            case .cancelled:
                dbg("http #\(id) closed")
                self?.clients[key] = nil
            default: break
            }
        }
        conn.start(queue: queue)
        receive(client)
    }

    /// The connection's single outstanding receive; re-arms itself until the client stops
    /// sending. A request head can span several TCP segments, so bytes accumulate in the
    /// inbox until `serveNext` finds a whole one.
    private func receive(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                if client.busy {
                    let firstLine = String(decoding: data.prefix(120), as: UTF8.self)
                        .components(separatedBy: "\r\n").first ?? ""
                    dbg("http #\(client.id) sent \(data.count) bytes before the current response finished: \(firstLine)")
                }
                client.inbox += data
            }
            if isComplete || error != nil {
                client.peerClosed = true
                let how = error.map { "receive failed: \($0)" } ?? "client finished sending"
                dbg("http #\(client.id) \(how)\(client.busy ? " (mid-response)" : "")")
                // A request that arrived along with the FIN still gets its answer; otherwise
                // there's nothing left to do. A response in flight finishes or fails on its own.
                self.serveNext(client)
                if !client.busy { client.conn.cancel() }
                return
            }
            guard client.inbox.count < Self.maxHeadBytes else { client.conn.cancel(); return }
            self.serveNext(client)
            self.receive(client)
        }
    }

    /// If no response is in flight and a whole request head (`\r\n\r\n`) is buffered, answer
    /// it. On a keep-alive connection, look for the next request once it's done.
    private func serveNext(_ client: Client) {
        guard !client.busy, let end = client.inbox.range(of: Self.headTerminator) else { return }
        let head = String(decoding: client.inbox[..<end.lowerBound], as: UTF8.self)
        client.inbox.removeSubrange(..<end.upperBound)
        client.busy = true
        respond(client, head: head) { keepAlive in
            client.busy = false
            if keepAlive && !client.peerClosed {
                self.serveNext(client)
            } else {
                // Flush, send FIN, then tear down.
                client.conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in client.conn.cancel() })
            }
        }
    }

    /// Send the response for one request, then call `done` with whether the connection
    /// should stay open for another request.
    private func respond(_ client: Client, head: String,
                         done: @escaping (_ keepAlive: Bool) -> Void) {
        let conn = client.conn
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let method = requestLine.split(separator: " ").first.map(String.init) ?? ""
        func header(_ name: String) -> String? {
            let prefix = name.lowercased() + ":"
            return lines.dropFirst()
                .first { $0.lowercased().hasPrefix(prefix) }
                .map { $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) }
        }
        // HTTP/1.1 is persistent unless the client opts out; 1.0 only if it opts in.
        let connectionHeader = header("connection")?.lowercased() ?? ""
        let keepAlive = requestLine.hasSuffix("HTTP/1.1")
            ? !connectionHeader.contains("close")
            : connectionHeader.contains("keep-alive")

        let status: String
        var extra: [String] = []
        var start: UInt64 = 0
        var length: UInt64 = 0

        if method != "GET" && method != "HEAD" {
            status = "405 Method Not Allowed"
            extra.append("Allow: GET, HEAD")
        } else {
            switch parseRange(header("range")) {
            case .full:
                status = "200 OK"
                length = size
            case .partial(let s, let e):
                status = "206 Partial Content"
                extra.append("Content-Range: bytes \(s)-\(e)/\(size)")
                start = s
                length = e - s + 1
            case .unsatisfiable:
                status = "416 Range Not Satisfiable"
                extra.append("Content-Range: bytes */\(size)")
            }
        }
        dbg("http #\(client.id) \(requestLine) range=\(header("range") ?? "none") -> \(status), \(length) bytes"
            + extra.map { " | \($0)" }.joined())
        dbg("http #\(client.id)   headers: \(lines.dropFirst().joined(separator: " | "))")

        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: video/mp4\r\n"
        response += "Accept-Ranges: bytes\r\n"
        for line in extra { response += line + "\r\n" }
        response += "Content-Length: \(length)\r\n"
        response += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        response += "\r\n"

        conn.send(content: Data(response.utf8), completion: .contentProcessed { error in
            guard error == nil else { conn.cancel(); return }
            guard method == "GET", length > 0 else { done(keepAlive); return }
            self.streamBody(client, start: start, length: length) { finished in
                if finished { done(keepAlive) } else { conn.cancel() }
            }
        })
    }

    /// Stream `length` bytes of the file from `start`. `done(false)` means the body didn't go
    /// out in full and the connection must be dropped.
    private func streamBody(_ client: Client, start: UInt64, length: UInt64,
                            done: @escaping (_ finished: Bool) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { done(false); return }
        do { try handle.seek(toOffset: start) } catch { try? handle.close(); done(false); return }
        let began = Date()
        func progress(_ sent: UInt64) -> String {
            String(format: "%.1f of %.1f MB in %.1fs", Double(sent) / 1e6, Double(length) / 1e6,
                   Date().timeIntervalSince(began))
        }
        var nextReport = Self.reportEvery

        func sendNext(sent: UInt64) {
            if sent == length {
                try? handle.close()
                if length >= Self.reportEvery { dbg("http #\(client.id) body done: \(progress(sent))") }
                done(true)
                return
            }
            let n = Int(min(UInt64(Self.chunkSize), length - sent))
            guard let data = try? handle.read(upToCount: n), !data.isEmpty else {
                try? handle.close()
                dbg("http #\(client.id) file read failed after \(progress(sent))")
                done(false)
                return
            }
            client.conn.send(content: data, completion: .contentProcessed { error in
                // Receivers hang up mid-range all the time (seeking, buffer full). Stop there
                // rather than reading the rest of the file into a dead socket.
                if let error {
                    try? handle.close()
                    dbg("http #\(client.id) send stopped after \(progress(sent)): \(error)")
                    done(false)
                    return
                }
                let total = sent + UInt64(data.count)
                if total >= nextReport, total < length {
                    dbg("http #\(client.id) sending: \(progress(total))")
                    nextReport += Self.reportEvery
                }
                sendNext(sent: total)
            })
        }
        sendNext(sent: 0)
    }

    // MARK: - Range parsing

    private enum ByteRange: Equatable {
        case full
        case partial(UInt64, UInt64)   // inclusive start...end
        case unsatisfiable
    }

    /// Parse a `Range` header value (RFC 9110 §14.1.2) against the file size.
    ///
    /// Header lines are isolated by splitting on CRLF in `respond`. Do NOT scan Characters
    /// for "\r"/"\n": Swift treats a CRLF as a single grapheme cluster, so `ch == "\r"` never
    /// matches. That bug made the server return the whole file for `bytes=0-1` probes, which
    /// AVFoundation rejects as "server is not correctly configured" (-12939).
    private func parseRange(_ value: String?) -> ByteRange {
        guard let value,
              let eq = value.range(of: "bytes=", options: [.caseInsensitive, .anchored]) else { return .full }
        let spec = value[eq.upperBound...].trimmingCharacters(in: .whitespaces)
        // Multi-range requests would need a multipart/byteranges body; ignoring the header
        // and sending the whole file is the RFC-sanctioned alternative.
        guard !spec.contains(",") else { return .full }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .full }

        if parts[0].isEmpty {
            // Suffix range: the last N bytes.
            guard let n = UInt64(parts[1]) else { return .full }
            guard n > 0, size > 0 else { return .unsatisfiable }
            return .partial(size - min(n, size), size - 1)
        }
        guard let start = UInt64(parts[0]) else { return .full }
        guard start < size else { return .unsatisfiable }
        // Open-ended ranges must run to the end of the file: a Vizio TV treats the end of a
        // shorter 206 as the end of the video and stops there.
        if parts[1].isEmpty { return .partial(start, size - 1) }
        guard let end = UInt64(parts[1]), end >= start else { return .full }
        return .partial(start, min(end, size - 1))
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
