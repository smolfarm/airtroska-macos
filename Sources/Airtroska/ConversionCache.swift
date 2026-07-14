import Foundation
import CryptoKit

/// A persistent, size-bounded cache of converted MP4s, keyed by the source file's identity
/// (path + size + modification time) so re-opening the same video skips reconversion.
///
/// Files live in the app's Caches directory rather than the temp dir, so they survive a
/// player close. A simple LRU eviction keeps the total under `maxBytes`.
enum ConversionCache {
    /// Bump when the conversion pipeline changes (codecs, flags, tags) so previously cached
    /// outputs are treated as misses instead of serving stale results.
    static let version = 2

    /// Soft cap on total cache size; least-recently-used files are evicted past this.
    static let maxBytes: UInt64 = 10_000_000_000   // 10 GB

    /// `…/Caches/Airtroska/ConvertedMedia` (not created by this getter — see `ensureDirectory`).
    static var directory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Airtroska/ConvertedMedia", isDirectory: true)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stable, filesystem-safe key from the source's path + size + modification time, plus a
    /// `variant` describing which subtitle track (if any) was burned in. Two conversions of the
    /// same source with different subtitle choices must NOT collide in the cache.
    private static func key(for input: URL, variant: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: input.path) else { return nil }
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = Int((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let raw = "v\(version)|\(input.path)|\(size)|\(mtime)|\(variant)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(for input: URL, variant: String) -> URL? {
        key(for: input, variant: variant).map { directory.appendingPathComponent("\($0).mp4") }
    }

    /// The cached conversion for `input`+`variant`, if a non-empty one exists.
    static func cachedURL(for input: URL, variant: String) -> URL? {
        guard let url = fileURL(for: input, variant: variant) else { return nil }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        return (size ?? 0) > 0 ? url : nil
    }

    /// Whether `url` lives inside the cache, so callers know not to delete it on close.
    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    /// Mark a cache hit as recently used so LRU eviction keeps it around.
    static func markUsed(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Move a freshly-converted temp file into the cache. Returns the cached URL, or nil if
    /// it couldn't be stored (caller should fall back to the temp file).
    static func store(_ tempURL: URL, for input: URL, variant: String) -> URL? {
        guard let dest = fileURL(for: input, variant: variant) else { return nil }
        ensureDirectory()
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tempURL, to: dest)
        } catch {
            dbg("cache store failed: \(error)")
            return nil
        }
        evictIfNeeded()
        return dest
    }

    /// Evict least-recently-used files until the total size is under `maxBytes`.
    private static func evictIfNeeded() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return }

        var entries = items.compactMap { url -> (url: URL, size: UInt64, date: Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, UInt64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(UInt64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }

        entries.sort { $0.date < $1.date }   // oldest (least recently used) first
        for entry in entries where total > maxBytes {
            do {
                try fm.removeItem(at: entry.url)
                total -= entry.size
                dbg("cache evict \(entry.url.lastPathComponent)")
            } catch {
                dbg("cache evict failed: \(error)")
            }
        }
    }
}
