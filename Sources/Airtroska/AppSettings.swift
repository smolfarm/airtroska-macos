import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// UserDefaults keys, shared between `@AppStorage` in the Settings window and the
/// non-View code (Remuxer, ConversionCache) that reads the same values via `Prefs`.
enum PrefKey {
    static let videoQuality = "videoQuality"
    static let audioBitrateKbps = "audioBitrateKbps"
    static let subtitleMode = "subtitleMode"
    static let letterbox = "letterboxTo16x9"
    static let cacheLimitGB = "cacheLimitGB"
    static let ffmpegDirectory = "ffmpegDirectory"
}

/// x264 settings used when a conversion must transcode video (non-Apple codec or
/// subtitle burn-in). The copy path ignores this entirely.
enum VideoQuality: String, CaseIterable, Identifiable {
    case faster, balanced, quality

    var id: String { rawValue }

    var label: String {
        switch self {
        case .faster: return "Faster (default)"
        case .balanced: return "Balanced"
        case .quality: return "Higher quality"
        }
    }

    var preset: String {
        switch self {
        case .faster: return "veryfast"
        case .balanced: return "fast"
        case .quality: return "medium"
        }
    }

    var crf: String {
        switch self {
        case .faster: return "20"
        case .balanced: return "19"
        case .quality: return "18"
        }
    }
}

enum SubtitleMode: String, CaseIterable, Identifiable {
    /// Show the track picker whenever a file has subtitle streams.
    case ask
    /// Skip the picker and always take the fast no-subtitles path.
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask which track to burn in"
        case .never: return "Never burn in (always use the fast path)"
        }
    }
}

/// Typed, defaulted access to the preferences for non-View code.
enum Prefs {
    static var videoQuality: VideoQuality {
        VideoQuality(rawValue: UserDefaults.standard.string(forKey: PrefKey.videoQuality) ?? "") ?? .faster
    }

    static var audioBitrateKbps: Int {
        let v = UserDefaults.standard.integer(forKey: PrefKey.audioBitrateKbps)
        return [128, 192, 256].contains(v) ? v : 192
    }

    static var subtitleMode: SubtitleMode {
        SubtitleMode(rawValue: UserDefaults.standard.string(forKey: PrefKey.subtitleMode) ?? "") ?? .ask
    }

    /// Pad non-16:9 video to 16:9 so TVs that stretch AirPlay video can't distort it. On by
    /// default; `object(forKey:)` tells "never set" apart from an explicit false.
    static var letterbox: Bool {
        UserDefaults.standard.object(forKey: PrefKey.letterbox) as? Bool ?? true
    }

    static var cacheLimitBytes: UInt64 {
        let gb = UserDefaults.standard.integer(forKey: PrefKey.cacheLimitGB)
        return UInt64(gb > 0 ? gb : 10) * 1_000_000_000
    }

    /// Folder to look for ffmpeg/ffprobe in before the standard locations, or nil.
    static var ffmpegDirectory: String? {
        let dir = UserDefaults.standard.string(forKey: PrefKey.ffmpegDirectory) ?? ""
        return dir.isEmpty ? nil : (dir as NSString).expandingTildeInPath
    }
}

/// Everything the app will accept from a drop, an open panel, or Finder's Open With.
enum Media {
    static let acceptedExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts",
        "flv", "wmv", "mpg", "mpeg",
    ]

    /// Content types for NSOpenPanel, derived from the accepted extensions.
    static var openPanelTypes: [UTType] {
        acceptedExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .movie) }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    var body: some View {
        TabView {
            ConversionSettingsPane()
                .tabItem { Label("Conversion", systemImage: "film") }
            CacheSettingsPane()
                .tabItem { Label("Cache", systemImage: "internaldrive") }
            AdvancedSettingsPane()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 480)
    }
}

private struct ConversionSettingsPane: View {
    @AppStorage(PrefKey.videoQuality) private var videoQuality = VideoQuality.faster.rawValue
    @AppStorage(PrefKey.audioBitrateKbps) private var audioBitrate = 192
    @AppStorage(PrefKey.subtitleMode) private var subtitleMode = SubtitleMode.ask.rawValue
    @AppStorage(PrefKey.letterbox) private var letterbox = true

    var body: some View {
        Form {
            Section {
                Picker("Video quality", selection: $videoQuality) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q.rawValue)
                    }
                }
                Text("Applies only when video has to be re-encoded (non-Apple codecs, "
                     + "letterboxing, or subtitle burn-in). Otherwise Apple-friendly video is "
                     + "copied untouched.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Letterbox to 16:9", isOn: $letterbox)
                Text("Some TVs (Vizio, for one) stretch any video that isn't 16:9 to fill the "
                     + "screen. This bakes the black bars into the video so there's nothing to "
                     + "stretch, at the cost of re-encoding those videos. HDR video is left "
                     + "as-is. Apple TV letterboxes by itself, so turn this off if that's all "
                     + "you AirPlay to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Audio bitrate", selection: $audioBitrate) {
                    Text("128 kbps").tag(128)
                    Text("192 kbps (default)").tag(192)
                    Text("256 kbps").tag(256)
                }
                Text("Audio is always converted to stereo AAC — it's the only thing that "
                     + "reliably plays over AirPlay.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("When a file has subtitles", selection: $subtitleMode) {
                    ForEach(SubtitleMode.allCases) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CacheSettingsPane: View {
    @AppStorage(PrefKey.cacheLimitGB) private var cacheLimitGB = 10
    @State private var usageBytes: UInt64 = 0

    var body: some View {
        Form {
            Section {
                Picker("Size limit", selection: $cacheLimitGB) {
                    Text("2 GB").tag(2)
                    Text("5 GB").tag(5)
                    Text("10 GB (default)").tag(10)
                    Text("25 GB").tag(25)
                    Text("50 GB").tag(50)
                }
                LabeledContent("In use",
                               value: ByteCountFormatter.string(fromByteCount: Int64(usageBytes),
                                                                countStyle: .file))
                Button("Clear Converted Files") {
                    ConversionCache.clear()
                    usageBytes = ConversionCache.totalBytes()
                }
                Text("Converted MP4s are kept so re-opening the same file skips ffmpeg. "
                     + "Least-recently-used files are deleted once the limit is exceeded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { usageBytes = ConversionCache.totalBytes() }
        .onChange(of: cacheLimitGB) { _ in
            ConversionCache.enforceLimit()
            usageBytes = ConversionCache.totalBytes()
        }
    }
}

private struct AdvancedSettingsPane: View {
    @AppStorage(PrefKey.ffmpegDirectory) private var ffmpegDirectory = ""
    /// Bumped after refreshTools() so the detected-path rows re-read the statics.
    @State private var toolRefresh = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("ffmpeg", value: Remuxer.ffmpeg?.path ?? "Not found")
                LabeledContent("ffprobe", value: Remuxer.ffprobe?.path ?? "Not found")
                LabeledContent("Text-subtitle burn-in (libass)",
                               value: Remuxer.subtitlesFilterAvailable ? "Available" : "Unavailable")
            }
            .id(toolRefresh)
            Section {
                HStack {
                    TextField("Custom ffmpeg folder", text: $ffmpegDirectory,
                              prompt: Text("e.g. /opt/homebrew/bin"))
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDirectory() }
                }
                Text("Looked in before the standard locations. Leave empty to auto-detect "
                     + "(Homebrew, /usr/local, PATH).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: ffmpegDirectory) { _ in
            Remuxer.refreshTools()
            toolRefresh += 1
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegDirectory = url.path
        }
    }
}
