import SwiftUI
import AVKit
import AVFoundation
import AppKit

/// Owns the AVPlayer, the local HTTP server, and all the playback / AirPlay state the
/// player UI binds to. Kept as a plain `ObservableObject` (not `@MainActor`) so KVO and
/// time-observer callbacks can publish on the main thread without actor-hop churn.
final class PlayerController: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    /// True while AVPlayer is actually routing video to an external (AirPlay) display.
    @Published var isExternalActive = false
    /// True while the system route menu is on screen.
    @Published var isPresentingRoutes = false

    let player = AVPlayer()

    /// Set by the scrubber while the user drags so the periodic observer doesn't fight it.
    var isScrubbing = false

    /// Called (on main) when the current item plays to its end — drives playlist auto-advance.
    var onItemEnded: (() -> Void)?

    private var server: LocalHTTPServer?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var routeDetector: AVRouteDetector?
    private var endObserver: NSObjectProtocol?

    init() {
        player.allowsExternalPlayback = true   // let AirPlay carry the video to a TV
        player.actionAtItemEnd = .pause
    }

    /// Load and play `url`. Safe to call again with a new URL (playlist advance): the
    /// previous item's server and observers are torn down, but the AVPlayer itself is
    /// kept so an active AirPlay route carries over to the next video.
    func start(url: URL) {
        teardownItem()
        currentTime = 0
        duration = 0

        // Serve over HTTP on the Mac's LAN IP. A non-Apple AirPlay receiver (e.g. a Roku)
        // can't be handed a file:// asset — it must fetch the video from a URL it can reach.
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
        player.replaceCurrentItem(with: item)

        observations = []
        observations.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                dbg("item status=\(it.status.rawValue) error=\(String(describing: it.error?.localizedDescription))")
                let d = it.duration.seconds
                if it.status == .readyToPlay, d.isFinite, d > 0 { self?.duration = d }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] pl, _ in
            DispatchQueue.main.async {
                dbg("timeControlStatus=\(pl.timeControlStatus.rawValue) (0=paused 1=waiting 2=playing)")
                self?.isPlaying = (pl.timeControlStatus == .playing)
            }
        })
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] pl, _ in
            DispatchQueue.main.async {
                dbg("externalPlaybackActive=\(pl.isExternalPlaybackActive)")
                self?.isExternalActive = pl.isExternalPlaybackActive
            }
        })

        // End-of-item drives playlist auto-advance.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            dbg("item played to end")
            self?.onItemEnded?()
        }

        // Periodic clock for the scrubber (4×/sec), delivered on the main queue.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            guard let self else { return }
            if !self.isScrubbing, t.seconds.isFinite { self.currentTime = t.seconds }
            if self.duration == 0, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
        }

        // Actively drive AirPlay device discovery while the player is on screen. This is
        // the documented "enable only while showing a picker" hook, and it's what makes the
        // route menu actually find every Apple TV on the network — AVKit's built-in player
        // does the same internally. (We deliberately do NOT bind `multipleRoutesDetected` to
        // the UI: testing showed it stays false even while a route is in active use, so it's
        // useless as an availability signal. We keep the detector only for its discovery.)
        if routeDetector == nil {
            let detector = AVRouteDetector()
            detector.isRouteDetectionEnabled = true
            routeDetector = detector
        }

        player.play()
        dbg("player setup, play() called for \(url.lastPathComponent)")
    }

    /// Undo everything `start(url:)` set up for the current item, leaving the player and
    /// route detector alone so playback can move to another item seamlessly.
    private func teardownItem() {
        if let t = timeObserver { player.removeTimeObserver(t); timeObserver = nil }
        observations.removeAll()              // invalidate KVO before tearing down its targets
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        server?.stop()
        server = nil
    }

    func togglePlay() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        teardownItem()
        routeDetector?.isRouteDetectionEnabled = false
        routeDetector = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// AppKit's `AVRoutePickerView` *is* the AirPlay button. We make it bordered and
/// prominent, accent the active state, and report when the route menu opens/closes.
struct RoutePickerButton: NSViewRepresentable {
    let player: AVPlayer
    var onPresentingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPresentingChange) }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.delegate = context.coordinator
        v.isRoutePickerButtonBordered = true
        // NB: `prioritizesVideoDevices` (ranking Apple TVs above HomePods) is iOS/tvOS-only —
        // it's explicitly unavailable on macOS, so we can't reorder the system route menu here.
        v.setRoutePickerButtonColor(.controlAccentColor, for: .active)
        v.setRoutePickerButtonColor(.controlAccentColor, for: .activeHighlighted)
        return v
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        nsView.player = player
        context.coordinator.onPresentingChange = onPresentingChange
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentingChange: (Bool) -> Void
        init(_ onPresentingChange: @escaping (Bool) -> Void) { self.onPresentingChange = onPresentingChange }
        func routePickerViewWillBeginPresentingRoutes(_ v: AVRoutePickerView) { onPresentingChange(true) }
        func routePickerViewDidEndPresentingRoutes(_ v: AVRoutePickerView) { onPresentingChange(false) }
    }
}

/// The video itself. We render with `AVPlayerView` but turn OFF its built-in controls so
/// it doesn't ship a *second* AirPlay button — the header's `RoutePickerButton` is the
/// single, enhanced AirPlay control.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

/// The single AirPlay affordance: a context-aware label plus the route-picker button.
private struct AirPlayControl: View {
    @ObservedObject var controller: PlayerController

    private var label: String {
        if controller.isExternalActive { return "Playing on TV" }
        if controller.isPresentingRoutes { return "Choose a device…" }
        return "AirPlay"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(controller.isExternalActive ? Color.accentColor : Color.secondary)
                .animation(.easeInOut(duration: 0.15), value: label)

            RoutePickerButton(player: controller.player) { presenting in
                controller.isPresentingRoutes = presenting
            }
            .frame(width: 44, height: 28)
        }
        .help("Send this video to your Apple TV")
    }
}

/// Shows the converted MP4 in a native AVPlayer with a single, enhanced AirPlay control.
/// When the playlist has more than one item it also offers prev/next transport buttons
/// and a toggleable queue sidebar.
struct PlayerView: View {
    let url: URL
    let title: String
    var playlist: [PlaylistItem] = []
    var currentIndex: Int = 0
    /// Jump to a playlist item (converting it first if needed).
    var onSelect: ((Int) -> Void)? = nil
    /// The current video played to its end.
    var onEnded: (() -> Void)? = nil
    let onClose: () -> Void

    @StateObject private var controller = PlayerController()
    @State private var showPlaylist = true

    private var hasPlaylist: Bool { playlist.count > 1 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                // Video. AVPlayerView shows its own "playing on TV" message when external
                // playback is active, so we don't draw our own overlay (it would collide).
                ZStack {
                    Color.black
                    PlayerSurface(player: controller.player)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                transport
            }

            if hasPlaylist && showPlaylist {
                Divider()
                playlistPanel
            }
        }
        .onAppear {
            controller.onItemEnded = onEnded
            controller.start(url: url)
        }
        // Playlist advance swaps the URL in place; reload on the same controller so an
        // active AirPlay route carries over to the next video.
        .onChange(of: url) { newURL in
            controller.onItemEnded = onEnded
            controller.start(url: newURL)
        }
        .onDisappear { controller.stop() }
    }

    // Header: title • AirPlay • playlist toggle • close
    private var header: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if hasPlaylist {
                Text("\(currentIndex + 1) of \(playlist.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            AirPlayControl(controller: controller)
            if hasPlaylist {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showPlaylist.toggle() } }) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(showPlaylist ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(showPlaylist ? "Hide playlist" : "Show playlist")
            }
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
        .background(.regularMaterial)
    }

    // Transport: (prev) play/pause (next) • elapsed • scrubber • duration
    private var transport: some View {
        HStack(spacing: 12) {
            if hasPlaylist {
                Button(action: { onSelect?(currentIndex - 1) }) {
                    Image(systemName: "backward.end.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == 0)
                .help("Previous")
            }

            Button(action: controller.togglePlay) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(controller.isPlaying ? "Pause" : "Play")

            if hasPlaylist {
                Button(action: { onSelect?(currentIndex + 1) }) {
                    Image(systemName: "forward.end.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex + 1 >= playlist.count)
                .help("Next")
            }

            Text(timeString(controller.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Slider(
                value: $controller.currentTime,
                in: 0...max(controller.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        controller.isScrubbing = true
                    } else {
                        controller.seek(to: controller.currentTime)
                        controller.isScrubbing = false
                    }
                }
            )
            .disabled(controller.duration <= 0)

            Text(timeString(controller.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var playlistPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playlist")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(playlist.enumerated()), id: \.element.id) { i, item in
                        playlistRow(i, item)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 240)
        .background(.regularMaterial)
    }

    private func playlistRow(_ i: Int, _ item: PlaylistItem) -> some View {
        Button(action: { if i != currentIndex { onSelect?(i) } }) {
            HStack(spacing: 8) {
                Group {
                    if i == currentIndex {
                        Image(systemName: "play.fill")
                            .foregroundStyle(Color.accentColor)
                    } else if item.failed != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(i + 1)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption.monospacedDigit())
                .frame(width: 18)

                Text(item.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(i == currentIndex ? Color.accentColor : Color.primary)

                Spacer(minLength: 0)

                // Already converted — jumping here is instant.
                if item.readyURL != nil && i != currentIndex {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(i == currentIndex ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(item.failed ?? item.sourceURL.lastPathComponent)
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
