import SwiftUI
import AVKit
import AppKit

/// Wraps AVRoutePickerView so the user can pick an Apple TV / AirPlay destination.
/// On macOS the view itself is the button; binding its `player` makes it route that player.
struct RoutePickerButton: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
    }
}

/// Shows the converted MP4 in a native AVPlayer with AirPlay enabled.
struct PlayerView: View {
    let url: URL
    let onClose: () -> Void

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var observations: [NSKeyValueObservation] = []
    @State private var server: LocalHTTPServer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                RoutePickerButton(player: player)
                    .frame(width: 30, height: 24)
                    .help("Pick an AirPlay destination (e.g. your Apple TV)")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            VideoPlayer(player: player)
                .onAppear { setupPlayer() }
                .onDisappear {
                    player?.pause()
                    observations.removeAll()
                    server?.stop()
                    server = nil
                }
        }
        .background(Color.black.opacity(0.05))
    }

    private func setupPlayer() {
        // Serve over HTTP on the Mac's LAN IP. A Roku (non-Apple) AirPlay receiver
        // can't be handed a file:// asset — it must fetch the video from a URL it can
        // reach, so we give AVPlayer an http://<lan-ip> URL with byte-range support.
        let playURL: URL
        if let server = try? LocalHTTPServer(fileURL: url) {
            try? server.start()
            self.server = server
            playURL = server.url ?? url
            dbg("serving \(url.lastPathComponent) at \(playURL.absoluteString)")
        } else {
            playURL = url
        }

        let item = AVPlayerItem(url: playURL)
        let p = AVPlayer(playerItem: item)
        // Let AirPlay send the video to a TV while controls stay here.
        p.allowsExternalPlayback = true
        p.actionAtItemEnd = .pause

        // Diagnostics: watch item status, player rate, and playback state.
        observations = []
        observations.append(item.observe(\.status, options: [.new]) { it, _ in
            dbg("item status=\(it.status.rawValue) error=\(String(describing: it.error?.localizedDescription))")
        })
        observations.append(p.observe(\.rate, options: [.new]) { pl, _ in
            dbg("player rate=\(pl.rate)")
        })
        observations.append(p.observe(\.timeControlStatus, options: [.new]) { pl, _ in
            dbg("timeControlStatus=\(pl.timeControlStatus.rawValue) (0=paused 1=waiting 2=playing)")
        })
        observations.append(p.observe(\.isExternalPlaybackActive, options: [.new]) { pl, _ in
            dbg("externalPlaybackActive=\(pl.isExternalPlaybackActive)")
        })

        player = p
        p.play()
        isPlaying = true
        dbg("player setup, play() called for \(url.lastPathComponent)")
    }
}