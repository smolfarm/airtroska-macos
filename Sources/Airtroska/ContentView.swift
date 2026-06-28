import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var remuxer = Remuxer()
    @State private var convertedURL: URL?
    @State private var draggedOver = false
    @State private var error: String?
    @State private var sourceName: String?

    private let acceptedExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi"]

    /// What the player header shows: the dropped file's name (without extension), not the
    /// `airtroska-<uuid>.mp4` temp file the converter actually produced.
    private var displayTitle: String {
        if let sourceName {
            return URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        }
        return convertedURL?.deletingPathExtension().lastPathComponent ?? "Video"
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            if let url = convertedURL {
                PlayerView(url: url, title: displayTitle) {
                    cleanup()
                }
                .transition(.opacity)
            } else {
                dropZone
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: convertedURL)
        .alert("Problem", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 22) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Drop an .mkv here")
                    .font(.title2.weight(.semibold))
                Text("It'll be converted to AirPlay-friendly MP4, then you pick your Apple TV.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if remuxer.isWorking {
                VStack(spacing: 8) {
                    ProgressView(value: remuxer.progress)
                        .frame(width: 280)
                    Text(remuxer.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let n = sourceName {
                        Text(n).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.top, 4)
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
        guard let provider = providers.first(where: { $0.registeredTypeIdentifiers.contains(UTType.fileURL.identifier) }) else {
            dbg("drop: no fileURL provider")
            DispatchQueue.main.async { self.error = "That doesn't look like a file I can use." }
            return
        }
        provider.loadObject(ofClass: URL.self) { url, err in
            dbg("loadObject url=\(String(describing: url)) err=\(String(describing: err))")
            guard let url = url else {
                DispatchQueue.main.async { self.error = "Couldn't read the dropped file." }
                return
            }
            let ext = url.pathExtension.lowercased()
            dbg("ext=\(ext) path=\(url.path)")
            guard acceptedExtensions.contains(ext) else {
                DispatchQueue.main.async { self.error = "Drop an .mkv (or .mp4/.mov/.m4v/.avi)." }
                return
            }
            DispatchQueue.main.async { self.sourceName = url.lastPathComponent }
            Task { @MainActor in await run(url) }
        }
    }

    @MainActor
    private func run(_ url: URL) async {
        dbg("run: \(url.path)")
        // Sandboxed dropped URLs need to be accessible; start accessing right away.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        remuxer.status = "Preparing…"
        remuxer.isWorking = true
        dbg("ffmpeg=\(String(describing: Remuxer.ffmpeg))")

        do {
            let out = try await remuxer.convert(url)
            dbg("convert ok -> \(out.path)")
            convertedURL = out
            error = nil
        } catch ConversionError.noOutput {
            dbg("convert: no output")
            self.error = "Conversion produced no file. The MKV may use codecs ffmpeg couldn't handle."
            remuxer.isWorking = false
        } catch {
            dbg("convert error: \(error)")
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            remuxer.isWorking = false
        }
    }

    private func cleanup() {
        // Leave cached conversions in place so re-opening the same file is instant; only
        // remove an uncached temp output (e.g. if caching failed).
        if let url = convertedURL, !ConversionCache.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        convertedURL = nil
        sourceName = nil
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