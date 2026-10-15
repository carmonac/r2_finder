// FileService.swift
// Delete / create directory / rename — port of file_ops.zig.

import Foundation

public enum FileService {
    /// Permanently delete paths (rm -rf semantics: recursive, missing paths
    /// are not an error). Returns nil on success or a user-facing error
    /// message. The Trash flow lives in the UI layer (trashItemAtURL) — this
    /// is only used for volumes without a Trash.
    public static func deleteFiles(paths: [String]) -> String? {
        let fm = FileManager.default
        for path in paths {
            var lst = stat()
            guard lstat(path, &lst) == 0 else { continue } // already gone — rm -rf is silent
            do {
                try fm.removeItem(atPath: path)
            } catch {
                return String(format: String(localized: "couldn't delete: %@"), path)
            }
        }
        return nil
    }

    /// Create a directory (no intermediate directories, fails if it exists).
    /// Returns nil on success or a user-facing error message.
    public static func createDirectory(path: String) -> String? {
        do {
            try FileManager.default.createDirectory(atPath: path,
                                                    withIntermediateDirectories: false)
            return nil
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    /// Rename / same-volume move via rename(2) — atomic, replaces an existing
    /// destination file like the old implementation did.
    /// Returns nil on success or a user-facing error message.
    public static func rename(src: String, dst: String) -> String? {
        guard Darwin.rename(src, dst) == 0 else {
            return "error: \(String(cString: strerror(errno)))"
        }
        return nil
    }

    /// True if any of the sources' basenames already exists in dstDir.
    public static func checkCollision(sources: [String], dstDir: String) -> Bool {
        let fm = FileManager.default
        for src in sources {
            let basename = (src as NSString).lastPathComponent
            if fm.fileExists(atPath: dstDir + "/" + basename) { return true }
        }
        return false
    }
}
