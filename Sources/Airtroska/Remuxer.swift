import Foundation

/// Locates an `ffmpeg`/`ffprobe` binary that a GUI-launched app can actually run.
///
/// Apps opened from Finder/Spotlight get a minimal PATH (`/usr/bin:/bin:...`) and
/// won't see Homebrew or conda installs, so we search known locations and fall
/// back to a login shell to recover the user's real PATH.
enum FFTool {
    static func resolve(_ name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last resort: ask a login shell where it would find the tool.
        let shell = Process()
        shell.launchPath = "/bin/zsh"
        shell.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try shell.run()
            shell.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, FileManager.default.isExecutableFile(atPath: s) {
                return URL(fileURLWithPath: s)
            }
        } catch {
            return nil
        }
        return nil
    }
}

/// What kind of conversion a file needs to become AirPlay-friendly MP4.
enum ConversionKind {
    case copyVideo      // copy video, transcode audio to stereo AAC
    case transcodeAll   // transcode video to H.264 + audio to stereo AAC
}

struct ProbeResult {
    let videoCodec: String?
    let audioCodec: String?
    let duration: Double // seconds, 0 if unknown
}

enum ConversionError: LocalizedError {
    case noFFmpeg
    case noFFprobe
    case probeFailed(String)
    case ffmpegFailed(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .noFFmpeg: return "Couldn't find ffmpeg. Install it (e.g. `brew install ffmpeg`) and relaunch."
        case .noFFprobe: return "Couldn't find ffprobe (it ships with ffmpeg)."
        case .probeFailed(let m): return "Couldn't read the file: \(m)"
        case .ffmpegFailed(let m): return "Conversion failed: \(m)"
        case .noOutput: return "Conversion produced no playable file."
        }
    }
}

/// Runs ffprobe/ffmpeg in the background and reports progress.
final class Remuxer: ObservableObject {

    @Published var progress: Double = 0      // 0...1
    @Published var status: String = ""
    @Published var isWorking: Bool = false

    private var process: Process?

    static let ffmpeg: URL? = FFTool.resolve("ffmpeg")
    static let ffprobe: URL? = FFTool.resolve("ffprobe")

    /// Probe the file and decide how to convert it.
    func probe(_ url: URL) async throws -> ProbeResult {
        guard let ffprobe = Self.ffprobe else { throw ConversionError.noFFprobe }
        let p = Process()
        p.launchPath = ffprobe.path
        p.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let vPipe = Pipe(); p.standardOutput = vPipe
        try p.run(); p.waitUntilExit()
        let videoCodec = String(data: vPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let a = Process()
        a.launchPath = ffprobe.path
        a.arguments = [
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let aPipe = Pipe(); a.standardOutput = aPipe
        try a.run(); a.waitUntilExit()
        let audioCodec = String(data: aPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let d = Process()
        d.launchPath = ffprobe.path
        d.arguments = ["-v", "error", "-show_entries", "format=duration",
                       "-of", "default=noprint_wrappers=1:nokey=1", url.path]
        let dPipe = Pipe(); d.standardOutput = dPipe
        try d.run(); d.waitUntilExit()
        let durStr = String(data: dPipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(durStr ?? "") ?? 0

        return ProbeResult(videoCodec: videoCodec?.isEmpty == false ? videoCodec : nil,
                           audioCodec: audioCodec?.isEmpty == false ? audioCodec : nil,
                           duration: duration)
    }

    private func kind(for probe: ProbeResult) -> ConversionKind {
        // Video: copy if it's already in a QuickTime/Apple-TV-friendly codec, else transcode.
        let appleVideo: Set<String> = ["h264", "hevc", "h265", "mpeg4"]
        let videoOK = probe.videoCodec.map { appleVideo.contains($0) } ?? false
        // Audio is ALWAYS transcoded to stereo AAC. AVFoundation reliably decodes
        // stereo AAC locally AND Apple TV AirPlays it — multichannel AAC, E-AC-3/Atmos,
        // DTS, Vorbis, etc. all stall AVPlayer, so we don't risk copying them.
        return videoOK ? .copyVideo : .transcodeAll
    }

    /// Convert `input` to an AirPlay-friendly MP4 in a temp dir. Returns the new URL.
    func convert(_ input: URL) async throws -> URL {
        guard let ffmpeg = Self.ffmpeg else { throw ConversionError.noFFmpeg }

        // Reuse a previous conversion of this exact file instead of running ffmpeg again.
        if let cached = ConversionCache.cachedURL(for: input) {
            ConversionCache.markUsed(cached)
            dbg("cache hit -> \(cached.lastPathComponent)")
            await MainActor.run {
                self.status = "Loaded from cache"
                self.progress = 1
                self.isWorking = false
            }
            return cached
        }

        let probe = try await self.probe(input)
        let kind = self.kind(for: probe)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtroska-\(UUID().uuidString).mp4")

        var args = ["-hide_banner", "-nostdin", "-i", input.path,
                    "-map", "0:v:0", "-map", "0:a:0?",
                    "-map_metadata", "-1", "-map_chapters", "-1"]
        switch kind {
        case .copyVideo:
            status = "Copying video, converting audio to AAC…"
            args += ["-c:v", "copy",
                     "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
            // HEVC copied from MKV gets the `hev1` tag by default, which Apple
            // (AVFoundation/QuickTime/Apple TV) refuses to decode — the file plays
            // audio-only. Force `hvc1` so Apple treats it as a real video stream.
            if let v = probe.videoCodec, ["hevc", "h265"].contains(v) {
                args += ["-tag:v", "hvc1"]
            }
        case .transcodeAll:
            status = "Transcoding to H.264 + AAC (this takes a while)…"
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                     "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
        args += ["-movflags", "+faststart", "-y", outURL.path]

        await MainActor.run {
            self.isWorking = true
            self.progress = 0
        }

        let p = Process()
        p.launchPath = ffmpeg.path
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        process = p

        // Stream stderr to parse `time=` and report progress.
        let duration = max(probe.duration, 0.001)
        let handle = errPipe.fileHandleForReading
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<nl)
                    buffer.removeSubrange(0...nl)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    if let time = Self.parseTime(line) {
                        let frac = min(time / duration, 1.0)
                        await MainActor.run { self?.progress = frac }
                    }
                }
            }
        }

        try p.run()
        p.waitUntilExit()

        await MainActor.run { self.isWorking = false }

        if p.terminationStatus != 0 {
            let tail = String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConversionError.ffmpegFailed(tail.suffix(400).description)
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else { throw ConversionError.noOutput }
        // Promote the finished temp file into the cache (atomic move). Fall back to the temp
        // file if it couldn't be stored, so playback still works.
        let finalURL = ConversionCache.store(outURL, for: input) ?? outURL
        await MainActor.run { self.progress = 1 }
        dbg("convert ok (cached=\(ConversionCache.contains(finalURL))) -> \(finalURL.lastPathComponent)")
        return finalURL
    }

    func cancel() {
        process?.terminate()
        process = nil
        DispatchQueue.main.async {
            self.isWorking = false
            self.status = "Cancelled"
        }
    }

    private static func parseTime(_ line: String) -> Double? {
        guard let r = line.range(of: "time=") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\r" }) else { return Double(rest) }
        return Double(rest[..<end])
    }
}