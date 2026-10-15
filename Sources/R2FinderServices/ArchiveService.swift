// ArchiveService.swift
// Async compress/uncompress via 7zz — port of archive.zig.
//
// All archive jobs run on one serial queue so only a single 7zz process is
// alive at a time (the old implementation used a global lock for the same
// reason: avoiding I/O contention). Callbacks fire on background threads;
// the UI layer dispatches to main.
//
// Progress:
//   • 7zz -bsp1 stdout percent lines            → (pct, 0, 0, 0, 0)
//   • compression only: a 300 ms output-size poll → (min(0.99, out/in), out, in, 0, 0)
// Extraction relies on the -bsp1 lines alone — polling the *source* archive
// against its own size (the old behavior, inherited from archive.zig) pinned
// the bar at 99 % from the first tick.

import Foundation

public enum ArchiveService {
    public typealias ProgressHandler = TransferService.ProgressHandler
    public typealias CompletionHandler = TransferService.CompletionHandler

    /// Serializes all archive operations (replaces the old global lock).
    private static let queue = DispatchQueue(label: "com.r2finder.archive")

    public static func compress(sevenzzPath: String, sources: [String],
                                archivePath: String,
                                volumeSizeMB: UInt32 = 0, storeOnly: Bool = false,
                                onProgress: @escaping ProgressHandler,
                                onDone: @escaping CompletionHandler) {
        queue.async {
            var args = ["a", "-y", "-bsp1"] // -bsp1: progress to stdout
            if storeOnly { args.append("-mx0") } // no compression, just store
            if volumeSizeMB > 0 { args.append("-v\(volumeSizeMB)m") }
            args.append(archivePath)
            args.append(contentsOf: sources)

            let totalInput = sources.reduce(UInt64(0)) { $0 + pathSize($1) }
            run(sevenzzPath: sevenzzPath, arguments: args,
                sizeMonitor: (archivePath: archivePath, totalInput: totalInput,
                              isSplit: volumeSizeMB > 0),
                onProgress: onProgress, onDone: onDone)
        }
    }

    public static func uncompress(sevenzzPath: String, archivePath: String,
                                  dstDir: String,
                                  onProgress: @escaping ProgressHandler,
                                  onDone: @escaping CompletionHandler) {
        queue.async {
            let args = ["x", "-y", "-bsp1", "-o\(dstDir)", archivePath]
            // No size monitor: 7zz's -bsp1 percent lines are the real
            // extraction progress.
            run(sevenzzPath: sevenzzPath, arguments: args, sizeMonitor: nil,
                onProgress: onProgress, onDone: onDone)
        }
    }

    private static func run(sevenzzPath: String, arguments: [String],
                            sizeMonitor: (archivePath: String, totalInput: UInt64, isSplit: Bool)?,
                            onProgress: @escaping ProgressHandler,
                            onDone: CompletionHandler) {
        let child = Subprocess(executablePath: sevenzzPath, arguments: arguments)

        // Compression: poll the growing output archive every 300 ms and
        // report byte-level progress alongside 7zz's own percent lines.
        var monitor: DispatchSourceTimer?
        if let sizeMonitor, sizeMonitor.totalInput > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .milliseconds(300), repeating: .milliseconds(300))
            timer.setEventHandler {
                let outputSize = outputSize(archivePath: sizeMonitor.archivePath,
                                            isSplit: sizeMonitor.isSplit)
                if outputSize > 0 {
                    let progress = min(0.99, Double(outputSize) / Double(sizeMonitor.totalInput))
                    onProgress(progress, outputSize, sizeMonitor.totalInput, 0, 0)
                }
            }
            timer.resume()
            monitor = timer
        }
        defer { monitor?.cancel() }

        let spawnError = child.run { line in
            if let pct = SevenZipProgressParser.parsePercent(line: line) {
                onProgress(pct / 100.0, 0, 0, 0, 0)
            }
        }

        if let spawnError {
            onDone(false, "Error: \(spawnError)")
            return
        }

        guard child.exitCode == 0 else {
            let se = child.stderrText
            onDone(false, se.isEmpty ? String(format: String(localized: "7zz exited with code %d"), child.exitCode)
                                     : "7zz: \(se)")
            return
        }

        onDone(true, nil)
    }

    // MARK: – Sizes

    /// stat(2) size of a single file, 0 on failure.
    private static func statSize(_ path: String) -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        return UInt64(max(0, st.st_size))
    }

    /// Total size of a path — the file's size, or the recursive sum for a
    /// directory.
    private static func pathSize(_ path: String) -> UInt64 {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        if (st.st_mode & S_IFMT) != S_IFDIR { return UInt64(max(0, st.st_size)) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return 0 }
        return names.reduce(UInt64(0)) { $0 + pathSize(path + "/" + $1) }
    }

    /// Size of the output archive. For split archives, sums the volume files
    /// (.001, .002, …) until the first missing one.
    private static func outputSize(archivePath: String, isSplit: Bool) -> UInt64 {
        guard isSplit else { return statSize(archivePath) }
        var total: UInt64 = 0
        for i in 1..<10000 {
            let vol = archivePath + String(format: ".%03d", i)
            let sz = statSize(vol)
            if sz == 0 && i > 1 { break } // no more volumes
            total += sz
        }
        return total
    }
}
