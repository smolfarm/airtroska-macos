import SwiftUI
import UniformTypeIdentifiers

/// One entry in the drop-created playback queue. Conversion output and failure state are
/// tracked per item so the queue can advance past bad files and revisit finished ones
/// without reconverting.
struct PlaylistItem: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    /// The converted, AirPlay-ready MP4, once conversion finishes.
    var readyURL: URL? = nil
    /// Set when conversion failed; auto-advance skips failed items, but clicking one
    /// in the playlist retries it.
    var failed: String? = nil

    /// What the player header and playlist rows show: the source name without extension,
    /// not the `airtroska-<hash>.mp4` file the converter actually produced.
    var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }
}

struct ContentView: View {
    @StateObject private var remuxer = Remuxer()
    @State private var playlist: [PlaylistItem] = []
    /// Index of the item currently playing or converting; nil = drop zone.
    @State private var currentIndex: Int? = nil
    @State private var draggedOver = false
    @State private var error: String?
    /// Set after probing a file with subtitle streams; presenting the sheet lets the user
    /// pick which track to burn in (or none) before conversion runs.
    @State private var subtitlePicker: SubtitlePickerModel?
    /// The picker's current selection: `nil` = "No subtitles", else a track's relative index.
    @State private var selectedSubtitleIndex: Int? = nil

    private let acceptedExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi"]

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            if let idx = currentIndex, playlist.indices.contains(idx) {
                let item = playlist[idx]
                if let url = item.readyURL {
                    PlayerView(url: url,
                               title: item.displayName,
                               playlist: playlist,
                               currentIndex: idx,
                               onSelect: { i in Task { @MainActor in await play(index: i) } },
                               onEnded: advance,
                               onClose: endSession)
                        .transition(.opacity)
                } else {
                    interstitial(item, index: idx)
                        .transition(.opacity)
                }
            } else {
                dropZone
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playlist)
        .animation(.easeInOut(duration: 0.2), value: currentIndex)
        .alert("Problem", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sheet(item: $subtitlePicker) { model in
            subtitlePickerSheet(model)
        }
    }

    /// Lets the user pick a subtitle track to burn in (or none). "No subtitles" is the
    /// default so the fast copy path survives unless the user opts into a burn-in transcode.
    private func subtitlePickerSheet(_ model: SubtitlePickerModel) -> some View {
        VStack(spacing: 14) {
            Text("Subtitles found")
                .font(.headline)
            // Name the file so the sheet makes sense when it pops mid-playlist.
            Text(model.sourceURL.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Burn-in renders the chosen track into the video so it shows up on the "
                 + "TV over AirPlay. It transcodes the video, so it's slower than no subtitles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)

            // Scrolls when a file has many tracks so the sheet never outgrows the screen.
            ScrollView {
                VStack(spacing: 2) {
                    pickerRow(label: "No subtitles (fast — copies video)",
                              isSelected: selectedSubtitleIndex == nil,
                              enabled: true) {
                        selectedSubtitleIndex = nil
                    }
                    Divider().padding(.vertical, 2)
                    ForEach(model.tracks) { track in
                        // Text subtitle burn-in needs ffmpeg's libass `subtitles` filter; image
                        // subs burn via the always-available `overlay` filter. When libass is
                        // missing, disable text tracks so the user can't pick an unrunnable path.
                        let enabled = track.isImage || Remuxer.subtitlesFilterAvailable
                        pickerRow(label: track.display,
                                  isSelected: selectedSubtitleIndex == track.index,
                                  enabled: enabled) {
                            selectedSubtitleIndex = track.index
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

            if !Remuxer.subtitlesFilterAvailable {
                Label("Your ffmpeg lacks libass, so only image (PGS) tracks can be burned in. The standard `brew install ffmpeg` adds text-subtitle support.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 6)
            }

            HStack {
                Button("Cancel") {
                    subtitlePicker = nil
                    selectedSubtitleIndex = nil
                    endSession()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Convert") {
                    let chosen = model.tracks.first { $0.index == selectedSubtitleIndex }
                    let itemID = model.itemID
                    subtitlePicker = nil
                    Task { @MainActor in
                        if let item = playlist.first(where: { $0.id == itemID }) {
                            await finishConvert(item, subtitle: chosen)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func pickerRow(label: String, isSelected: Bool, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .foregroundStyle(isSelected ? Color.accentColor
                                              : (enabled ? Color.primary : Color.secondary))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    /// Shown while the current playlist item is converting (or failed with nothing to
    /// auto-advance to), so a mid-playlist conversion doesn't dump the user back on the
    /// drop zone.
    private func interstitial(_ item: PlaylistItem, index: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: item.failed == nil ? "film.stack" : "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(item.failed == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))

            if playlist.count > 1 {
                Text("\(index + 1) of \(playlist.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(item.sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)

            if let failed = item.failed {
                Text(failed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    if hasNextPlayable {
                        Button("Skip") { advance() }
                    }
                    Button("Retry") {
                        Task { @MainActor in await play(index: index) }
                    }
                    Button("Close") { endSession() }
                }
            } else {
                ProgressView(value: remuxer.progress)
                    .frame(width: 280)
                Text(remuxer.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") { endSession() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 22) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Drop .mkv files here")
                    .font(.title2.weight(.semibold))
                Text("They'll be converted to AirPlay-friendly MP4, then you pick your Apple TV. "
                     + "Drop several at once to queue them up as a playlist.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            if Remuxer.ffmpeg == nil {
                Label("ffmpeg not found — install with `brew install ffmpeg`",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Label("ffmpeg: \(Remuxer.ffmpeg!.path)",
                      systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(draggedOver ? Color.accentColor : Color.gray.opacity(0.3),
                              lineWidth: draggedOver ? 3 : 2)
                .padding(24)
        )
        .onDrop(of: [.fileURL], isTargeted: $draggedOver) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        dbg("drop: \(providers.count) provider(s)")
        for p in providers { dbg("  provider types: \(p.registeredTypeIdentifiers)") }
        let fileProviders = providers.filter {
            $0.registeredTypeIdentifiers.contains(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            dbg("drop: no fileURL providers")
            DispatchQueue.main.async { self.error = "That doesn't look like files I can use." }
            return
        }

        // Each provider loads its URL asynchronously; collect them all (keeping drop order)
        // before building the playlist.
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [(order: Int, url: URL)] = []
        for (i, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, err in
                dbg("loadObject[\(i)] url=\(String(describing: url)) err=\(String(describing: err))")
                if let url {
                    lock.lock()
                    loaded.append((i, url))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = loaded.sorted { $0.order < $1.order }.map(\.url)
            let accepted = urls.filter { acceptedExtensions.contains($0.pathExtension.lowercased()) }
            guard !accepted.isEmpty else {
                self.error = urls.isEmpty ? "Couldn't read the dropped files."
                                          : "Drop .mkv files (or .mp4/.mov/.m4v/.avi)."
                return
            }
            if accepted.count < urls.count {
                dbg("drop: skipped \(urls.count - accepted.count) unsupported file(s)")
            }
            self.startPlaylist(accepted)
        }
    }

    private func startPlaylist(_ urls: [URL]) {
        dbg("startPlaylist: \(urls.count) file(s)")
        playlist = urls.map { PlaylistItem(sourceURL: $0) }
        Task { @MainActor in await play(index: 0) }
    }

    /// Make `index` the current item, converting it first if needed. Clicking a failed
    /// item retries it.
    @MainActor
    private func play(index: Int) async {
        guard playlist.indices.contains(index) else { return }
        playlist[index].failed = nil
        currentIndex = index
        guard playlist[index].readyURL == nil else { return }

        let url = playlist[index].sourceURL
        dbg("play item \(index): \(url.path)")
        // Sandboxed dropped URLs need to be accessible; start accessing right away.
        // (This app is ad-hoc signed / unsandboxed, so this is a no-op, but kept for correctness.)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        remuxer.status = "Reading file…"
        remuxer.isWorking = true
        dbg("ffmpeg=\(String(describing: Remuxer.ffmpeg))")

        do {
            let probe = try await remuxer.probe(url)
            if probe.subtitles.isEmpty {
                // No subtitles → no choice to make; convert straight away on the fast path.
                await finishConvert(playlist[index], subtitle: nil)
            } else {
                // Defer conversion until the user picks a track (or none).
                dbg("probe found \(probe.subtitles.count) subtitle track(s); showing picker")
                remuxer.isWorking = false
                remuxer.status = ""
                selectedSubtitleIndex = nil   // default to "No subtitles" (keeps the fast path)
                subtitlePicker = SubtitlePickerModel(sourceURL: url,
                                                     tracks: probe.subtitles,
                                                     itemID: playlist[index].id)
            }
        } catch {
            dbg("probe error: \(error)")
            remuxer.isWorking = false
            markFailed(playlist[index].id,
                       message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    @MainActor
    private func finishConvert(_ item: PlaylistItem, subtitle: SubtitleTrack?) async {
        dbg("finishConvert: \(item.sourceURL.path) subtitle=\(String(describing: subtitle?.index))")
        remuxer.status = "Preparing…"
        remuxer.isWorking = true

        do {
            let out = try await remuxer.convert(item.sourceURL, subtitle: subtitle)
            dbg("convert ok -> \(out.path)")
            guard let idx = playlist.firstIndex(where: { $0.id == item.id }) else {
                // The session ended while converting; don't leak an uncached output.
                if !ConversionCache.contains(out) { try? FileManager.default.removeItem(at: out) }
                return
            }
            playlist[idx].readyURL = out
            error = nil
        } catch ConversionError.cancelled {
            dbg("convert cancelled")
            remuxer.isWorking = false
        } catch ConversionError.noOutput {
            dbg("convert: no output")
            remuxer.isWorking = false
            markFailed(item.id,
                       message: "Conversion produced no file. The MKV may use codecs ffmpeg couldn't handle.")
        } catch {
            dbg("convert error: \(error)")
            remuxer.isWorking = false
            markFailed(item.id,
                       message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private func markFailed(_ id: UUID, message: String) {
        guard let idx = playlist.firstIndex(where: { $0.id == id }) else { return }
        playlist[idx].failed = message
        error = message
        // Keep a multi-file session going: hop to the next playable item if there is one.
        if currentIndex == idx,
           let next = playlist.indices.first(where: { $0 > idx && playlist[$0].failed == nil }) {
            Task { @MainActor in await play(index: next) }
        }
    }

    private var hasNextPlayable: Bool {
        guard let cur = currentIndex else { return false }
        return playlist.indices.contains { $0 > cur && playlist[$0].failed == nil }
    }

    /// Auto-advance: called when the current video plays to its end (and by "Skip").
    private func advance() {
        guard let cur = currentIndex,
              let next = playlist.indices.first(where: { $0 > cur && playlist[$0].failed == nil })
        else { return }
        Task { @MainActor in await play(index: next) }
    }

    /// Tear the whole session down and return to the drop zone.
    private func endSession() {
        remuxer.cancel()
        // Leave cached conversions in place so re-opening the same file is instant; only
        // remove uncached temp outputs (e.g. if caching failed).
        for item in playlist {
            if let url = item.readyURL, !ConversionCache.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        playlist = []
        currentIndex = nil
        remuxer.progress = 0
        remuxer.status = ""
    }
}

func dbg(_ s: String) {
    let line = "[airtroska] \(s)\n"
    fputs(line, stderr)
    let path = "/tmp/airtroska.log"
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        try? h.close()
    }
}

/// Carrier for the subtitle-picker sheet: the source URL and playlist item (so conversion
/// can resume after the pick) and the probed tracks to choose from. `Identifiable` so
/// `.sheet(item:)` can present it.
struct SubtitlePickerModel: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let tracks: [SubtitleTrack]
    let itemID: UUID
}
