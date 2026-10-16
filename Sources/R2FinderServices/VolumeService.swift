// VolumeService.swift
// Mounted volumes and special directories — port of volumes.zig.

import Foundation

public struct VolumeEntry {
    public var name: String
    public var path: String
    /// Can be ejected from the sidebar: removable media, disk images,
    /// external drives and network shares.
    public var isEjectable = false
}

public enum VolumeService {
    /// Mounted volumes under /Volumes (DMGs, network shares, external drives).
    /// Uses mountedVolumeURLs so volume display names are correct, filtered to
    /// /Volumes/ so the boot volume ("/") and hidden system volumes don't
    /// clutter the sidebar (which adds "Macintosh HD" → "/" itself).
    public static func volumes() -> [VolumeEntry] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsEjectableKey,
                                         .volumeIsRemovableKey, .volumeIsInternalKey,
                                         .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            let path = url.path
            guard path.hasPrefix("/Volumes/") else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            let name = values?.volumeName ?? url.lastPathComponent
            // Same rule as Finder's eject button: anything that isn't a fixed
            // internal disk. Network shares report isLocal == false.
            let ejectable = values?.volumeIsEjectable == true
                || values?.volumeIsRemovable == true
                || values?.volumeIsInternal == false
                || values?.volumeIsLocal == false
            return VolumeEntry(name: name, path: path, isEjectable: ejectable)
        }
    }

    /// Well-known user directories (relative to home), in sidebar order.
    public static let specialDirPaths = ["", "/Desktop", "/Documents", "/Downloads",
                                         "/Music", "/Pictures", "/Movies", "/Applications"]

    /// Well-known user directories, only those that exist. Names come from
    /// the system, so they follow the Mac's language ("Downloads"/"Descargas")
    /// like Finder's sidebar.
    public static func specialDirs() -> [VolumeEntry] {
        let home = NSHomeDirectory()
        var result: [VolumeEntry] = []
        for rel in specialDirPaths {
            let full = home + rel
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            result.append(VolumeEntry(name: FileManager.default.displayName(atPath: full), path: full))
        }
        return result
    }
}
