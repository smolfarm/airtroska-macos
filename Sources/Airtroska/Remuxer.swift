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
    let subtitles: [SubtitleTrack]
}

/// A subtitle stream discovered in the source container.
struct SubtitleTrack: Identifiable, Hashable {
    /// Relative index among subtitle streams (0-based). This is the value ffmpeg's
    /// `0:s:N`, `-map 0:s:N`, and the `subtitles` filter's `si=N` all expect.
    let index: Int
    let codec: String
    let language: String?   // e.g. "eng"; may be nil if unset
    let title: String?      // human label from the stream's `title` tag, if any

    var id: Int { index }

    /// Image-based subtitle codecs (PGS/DVB/etc.) must be burned in via the `overlay`
    /// filter against the source stream; text codecs go through the `subtitles` filter
    /// reading an extracted sidecar `.srt`.
    var isImage: Bool {
        Self.imageCodecs.contains(codec.lowercased())
    }

    /// A short, UI-friendly description, e.g. "English · SRT" or "Forced · PGS".
    var display: String {
        let label = title ?? language.map { Self.languageName($0) } ?? "Track \(index + 1)"
        return "\(label) · \(codec.uppercased())"
    }

    private static let imageCodecs: Set<String> = [
        "pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvbsub", "xsub",
    ]

    /// Map an ISO 639-2 code (what ffprobe returns) to an English language name when we
    /// recognise it; otherwise return the raw code so the UI still shows *something*.
    private static let languageNames: [String: String] = [
        "eng": "English", "spa": "Spanish", "fre": "French", "fra": "French",
        "ger": "German", "deu": "German", "ita": "Italian", "por": "Portuguese",
        "rus": "Russian", "jpn": "Japanese", "chi": "Chinese", "zho": "Chinese",
        "kor": "Korean", "dut": "Dutch", "nld": "Dutch", "swe": "Swedish",
        "nor": "Norwegian", "dan": "Danish", "fin": "Finnish", "pol": "Polish",
        "cze": "Czech", "ces": "Czech", "ara": "Arabic", "hin": "Hindi",
        "tur": "Turkish", "tha": "Thai", "vie": "Vietnamese", "ind": "Indonesian",
        "und": "Undetermined",
    ]
    private static func languageName(_ code: String) -> String {
        languageNames[code.lowercased()] ?? code
    }
}

enum ConversionError: LocalizedError {
    case noFFmpeg
    case noFFprobe
    case probeFailed(String)
    case ffmpegFailed(String)
    case noOutput
    case noSubtitlesFilter
    /// The user cancelled; callers should swallow this rather than show an error.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noFFmpeg: return "Couldn't find ffmpeg. Install it (e.g. `brew install ffmpeg`) and relaunch."
        case .noFFprobe: return "Couldn't find ffprobe (it ships with ffmpeg)."
        case .probeFailed(let m): return "Couldn't read the file: \(m)"
        case .ffmpegFailed(let m): return "Conversion failed: \(m)"
        case .noOutput: return "Conversion produced no playable file."
        case .noSubtitlesFilter:
            return "Burning in text subtitles needs an ffmpeg built with libass (the `subtitles` "
                 + "filter). This ffmpeg doesn't have it — install the standard "
                 + "`brew install ffmpeg`, or pick an image (PGS) track / no subtitles."
        case .cancelled: return "Conversion cancelled."
        }
    }
}

/// Runs ffprobe/ffmpeg in the background and reports progress.
final class Remuxer: ObservableObject {

    @Published var progress: Double = 0      // 0...1
    @Published var status: String = ""
    @Published var isWorking: Bool = false

    private var process: Process?
    /// Set by `cancel()` so `convert` can tell a user cancel from an ffmpeg failure.
    private var cancelRequested = false

    static let ffmpeg: URL? = FFTool.resolve("ffmpeg")
    static let ffprobe: URL? = FFTool.resolve("ffprobe")

    /// Whether the resolved ffmpeg exposes the `subtitles` filter (libass). Burning in
    /// text subtitle tracks (SRT/ASS/SSA) requires it; the standard Homebrew build has it,
    /// but minimal/custom builds don't. Probed once at startup so the picker can disable
    /// text tracks and `convert` can fail with a clear message instead of a cryptic error.
    static let subtitlesFilterAvailable: Bool = {
        guard let ffmpeg = ffmpeg else { return false }
        let p = Process()
        p.launchPath = ffmpeg.path
        p.arguments = ["-hide_banner", "-filters"]
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run(); p.waitUntilExit() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // `-filters` lines look like ` TS. subtitles        S->V ...`. The first token is the
        // flags column; the second is the filter name. Match the name exactly to avoid hits
        // on unrelated filters (e.g. `ass` matching `allpass`).
        return out.split(separator: "\n").contains { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            return parts.count >= 2 && parts[1] == "subtitles"
        }
    }()

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

        let subtitles = try probeSubtitles(url)

        return ProbeResult(videoCodec: videoCodec?.isEmpty == false ? videoCodec : nil,
                           audioCodec: audioCodec?.isEmpty == false ? audioCodec : nil,
                           duration: duration,
                           subtitles: subtitles)
    }

    /// Probe subtitle streams as JSON and parse them into `SubtitleTrack`s, preserving
    /// stream order so the relative subtitle-stream index (= position in this list) matches
    /// what ffmpeg's `0:s:N` / `-map 0:s:N` / `subtitles:si=N` expect.
    private func probeSubtitles(_ url: URL) throws -> [SubtitleTrack] {
        guard let ffprobe = Self.ffprobe else { throw ConversionError.noFFprobe }
        let p = Process()
        p.launchPath = ffprobe.path
        p.arguments = [
            "-v", "error",
            "-select_streams", "s",
            "-show_entries", "stream=codec_name:stream_tags=language,title",
            "-of", "json",
            url.path,
        ]
        let pipe = Pipe(); p.standardOutput = pipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = pipe.fileHandleForReading.readDataToEndOfFile() as Data?,
              !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]]
        else { return [] }

        return streams.enumerated().compactMap { (i, s) -> SubtitleTrack? in
            guard let codec = s["codec_name"] as? String else { return nil }
            let tags = s["tags"] as? [String: Any] ?? [:]
            let lang = tags["language"] as? String
            let title = tags["title"] as? String
            return SubtitleTrack(index: i,
                                 codec: codec,
                                 language: (lang?.isEmpty == false ? lang : nil),
                                 title: (title?.isEmpty == false ? title : nil))
        }
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
    /// If `subtitle` is set, that track is burned into the video (which forces an H.264
    /// transcode — overlay/subtitle filters change pixels, so `-c:v copy` is impossible).
    func convert(_ input: URL, subtitle: SubtitleTrack? = nil) async throws -> URL {
        guard let ffmpeg = Self.ffmpeg else { throw ConversionError.noFFmpeg }

        cancelRequested = false
        let variant = subtitle.map { "sub\($0.index)" } ?? "none"

        // Backstop: a text subtitle needs the libass `subtitles` filter. The picker disables
        // text tracks when it's missing, but guard here too so a stale pick can't reach ffmpeg.
        if let sub = subtitle, !sub.isImage, !Self.subtitlesFilterAvailable {
            throw ConversionError.noSubtitlesFilter
        }

        // Reuse a previous conversion of this exact file + subtitle choice instead of
        // running ffmpeg again. The variant is part of the cache key so a no-subtitle
        // conversion and a burned-in one don't collide.
        if let cached = ConversionCache.cachedURL(for: input, variant: variant) {
            ConversionCache.markUsed(cached)
            dbg("cache hit (variant=\(variant)) -> \(cached.lastPathComponent)")
            await MainActor.run {
                self.status = "Loaded from cache"
                self.progress = 1
                self.isWorking = false
            }
            return cached
        }

        let probe = try await self.probe(input)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtroska-\(UUID().uuidString).mp4")

        // For burn-in we extract the chosen text subtitle to a sidecar `.srt` first (avoids
        // escaping the source path through the `subtitles` filter). Image subs need no
        // sidecar — they burn in via the `overlay` filter against the source stream.
        var sidecar: URL? = nil
        if let sub = subtitle, !sub.isImage {
            sidecar = try await extractSidecar(input, sub)
        }
        defer { if let s = sidecar { try? FileManager.default.removeItem(at: s) } }

        var args = ["-hide_banner", "-nostdin", "-i", input.path,
                    "-map", "0:v:0", "-map", "0:a:0?",
                    "-map_metadata", "-1", "-map_chapters", "-1"]
        if let sub = subtitle {
            // Burn-in: must transcode video. Pick the filter by sub type.
            if sub.isImage {
                status = "Burning in image subtitles, transcoding to H.264…"
                args = ["-hide_banner", "-nostdin", "-i", input.path,
                        "-filter_complex", "[0:v:0][0:s:\(sub.index)]overlay[v]",
                        "-map", "[v]", "-map", "0:a:0?",
                        "-map_metadata", "-1", "-map_chapters", "-1",
                        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                        "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
            } else {
                status = "Burning in subtitles, transcoding to H.264…"
                let vf = "subtitles='\(sidecar!.path)'"
                args += ["-vf", vf,
                         "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                         "-c:a", "aac", "-b:a", "192k", "-ac", "2"]
            }
        } else {
            let kind = self.kind(for: probe)
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

        if cancelRequested {
            try? FileManager.default.removeItem(at: outURL)
            throw ConversionError.cancelled
        }
        if p.terminationStatus != 0 {
            let tail = String(data: handle.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ConversionError.ffmpegFailed(tail.suffix(400).description)
        }
        guard FileManager.default.fileExists(atPath: outURL.path) else { throw ConversionError.noOutput }
        // Promote the finished temp file into the cache (atomic move). Fall back to the temp
        // file if it couldn't be stored, so playback still works.
        let finalURL = ConversionCache.store(outURL, for: input, variant: variant) ?? outURL
        await MainActor.run { self.progress = 1 }
        dbg("convert ok (variant=\(variant) cached=\(ConversionCache.contains(finalURL))) -> \(finalURL.lastPathComponent)")
        return finalURL
    }

    /// Extract a text subtitle stream to a temporary `.srt` so the `subtitles` filter can read
    /// it without the source path's special characters going through filtergraph escaping.
    private func extractSidecar(_ input: URL, _ sub: SubtitleTrack) async throws -> URL {
        guard let ffmpeg = Self.ffmpeg else { throw ConversionError.noFFmpeg }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtroska-\(UUID().uuidString).srt")
        let p = Process()
        p.launchPath = ffmpeg.path
        p.arguments = ["-hide_banner", "-nostdin", "-v", "error",
                       "-i", input.path, "-map", "0:s:\(sub.index)",
                       "-c:s", "srt", "-y", url.path]
        let errPipe = Pipe(); p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            let tail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            dbg("sidecar extract failed: \(tail.suffix(300))")
            throw ConversionError.ffmpegFailed("Couldn't extract subtitle track: \(tail.suffix(300))")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.noOutput
        }
        dbg("sidecar extracted -> \(url.lastPathComponent)")
        return url
    }

    func cancel() {
        cancelRequested = true
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