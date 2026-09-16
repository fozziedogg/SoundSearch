import Foundation

/// Maps between absolute paths and (volume identity, path relative to the mount point).
///
/// A mount point is not a stable name for a drive. The same disk appears at
/// `/Volumes/SFX` today and `/Volumes/SFX-1` tomorrow when an earlier mount was not
/// cleanly ejected, and at a different point again on another machine. The volume's
/// identity is stable; the path it is currently reachable at is not. Storing both lets
/// the absolute path be regenerated on every launch instead of being trusted.
enum VolumeIndex {

    /// Stable identity for a volume, in the form `uuid:<UUID>` or `name:<volume name>`.
    ///
    /// Local disks report a volume UUID. Network shares frequently do not, so those fall
    /// back to the volume name with any mount-collision suffix removed — `/Volumes/SFX-1`
    /// and `/Volumes/SFX` produce the same key, which is the entire point.
    struct Identity: Equatable, Hashable {
        var key: String
        var mountPoint: String

        var isUUIDBased: Bool { key.hasPrefix("uuid:") }
    }

    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeURLKey,
    ]

    // MARK: - Identity

    /// Identity of the volume containing `path`, resolved from the nearest existing
    /// ancestor so that a missing file under a mounted drive still resolves.
    static func identity(forPath path: String) -> Identity? {
        guard let existing = nearestExistingAncestor(of: path),
              let values = try? URL(fileURLWithPath: existing).resourceValues(forKeys: volumeKeys),
              let mount = values.volume?.path
        else { return nil }
        guard let key = identityKey(uuid: values.volumeUUIDString, name: values.volumeName,
                                    mountPoint: mount)
        else { return nil }
        return Identity(key: key, mountPoint: mount)
    }

    private static func identityKey(uuid: String?, name: String?, mountPoint: String) -> String? {
        if let uuid, !uuid.isEmpty { return "uuid:\(uuid)" }
        // Prefer the reported volume name; fall back to the mount's last component, which
        // is what /Volumes entries are named after.
        let raw = (name?.isEmpty == false ? name! : (mountPoint as NSString).lastPathComponent)
        guard !raw.isEmpty, raw != "/" else {
            return mountPoint == "/" ? "name:/" : nil
        }
        return "name:\(strippingMountSuffix(raw))"
    }

    /// `SFX-1`, `SFX 2`, `SFX_3` are all the same drive remounted alongside a stale mount.
    static func strippingMountSuffix(_ name: String) -> String {
        name.replacingOccurrences(of: "[-_ ]\\d+$", with: "", options: .regularExpression)
    }

    /// Every volume mounted right now, keyed the same way as `identity(forPath:)`.
    ///
    /// When two volumes collide on a name-based key — the stale-mount case, where both
    /// `/Volumes/SFX` and `/Volumes/SFX-1` are present — the shorter mount point wins,
    /// since the suffixed one is the newcomer.
    static func currentMounts() -> [String: String] {
        // No .skipHiddenVolumes: that option drops volumes mounted `nobrowse`, which is
        // how plenty of studio SMB/NFS automounts appear. Missing one means every path on
        // it looks stale. Extra volumes in the map are harmless — lookups are by identity.
        let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys), options: []) ?? []

        var result: [String: String] = [:]
        for url in mounts {
            guard let values = try? url.resourceValues(forKeys: volumeKeys) else { continue }
            let mount = values.volume?.path ?? url.path
            guard let key = identityKey(uuid: values.volumeUUIDString,
                                        name: values.volumeName, mountPoint: mount)
            else { continue }
            if let existing = result[key], existing.count <= mount.count { continue }
            result[key] = mount
        }
        return result
    }

    // MARK: - Path arithmetic

    /// Splits an absolute path into its volume identity and the remainder below the
    /// mount point. The remainder never has a leading slash, so it composes cleanly with
    /// both `/Volumes/Name` and the root mount `/`.
    static func split(path: String) -> (identity: Identity, relativePath: String)? {
        guard let identity = identity(forPath: path),
              let relative = relativePath(of: path, underMount: identity.mountPoint)
        else { return nil }
        return (identity, relative)
    }

    static func relativePath(of path: String, underMount mount: String) -> String? {
        if path == mount { return "" }
        let prefix = mountPrefix(mount)
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The mount point with exactly one trailing slash — `/` stays `/`, `/Volumes/SFX`
    /// becomes `/Volumes/SFX/`. Concatenating this with a relative path is the inverse of
    /// `relativePath(of:underMount:)`, in Swift and in SQL alike.
    static func mountPrefix(_ mount: String) -> String {
        mount.hasSuffix("/") ? mount : mount + "/"
    }

    static func absolutePath(mount: String, relativePath: String) -> String {
        relativePath.isEmpty ? mount : mountPrefix(mount) + relativePath
    }

    // MARK: - Cache

    /// Remembers which mount a path belongs to, so a large scan pays one volume lookup
    /// per drive instead of one per file. Safe to share across the scanner's tasks.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [String: Identity] = [:]   // mount prefix -> identity

        func split(path: String) -> (identity: Identity, relativePath: String)? {
            lock.lock()
            // Longest matching prefix wins: a nested mount must not be attributed to the
            // volume it is mounted inside.
            let hit = identities
                .filter { path.hasPrefix($0.key) }
                .max { $0.key.count < $1.key.count }
            lock.unlock()

            if let hit, let relative = VolumeIndex.relativePath(of: path,
                                                               underMount: hit.value.mountPoint) {
                return (hit.value, relative)
            }

            guard let fresh = VolumeIndex.split(path: path) else { return nil }
            lock.lock()
            identities[VolumeIndex.mountPrefix(fresh.identity.mountPoint)] = fresh.identity
            lock.unlock()
            return fresh
        }
    }

    // MARK: - Helpers

    static func nearestExistingAncestor(of path: String) -> String? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: path)
        while true {
            if fm.fileExists(atPath: probe.path) { return probe.path }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return nil }
            probe = parent
        }
    }
}
