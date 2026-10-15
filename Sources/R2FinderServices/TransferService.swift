// TransferService.swift
// Async file copy/move via rsync — port of transfer.zig.
//
// Threading model (unchanged from the Zig implementation):
//   • Each transfer runs on its own detached background thread.
//   • Callbacks are invoked on that thread; the UI layer must dispatch to
//     the main queue before touching UI.
//
// The batch rsync invocation is byte-identical to the old one:
//   rsync -a --info=progress2 --no-inc-recursive
//         [--ignore-existing] [--remove-source-files] <sources> <dst>/
// Sources renamed under .keepBoth each get their own invocation, since
// rsync can't rename several sources in one run.

import Foundation

public enum TransferService {
    // Handlers are invoked on background threads — callers that touch UI must
    // hop to the main actor themselves.
    public typealias ProgressHandler = @Sendable (_ progress: Double, _ bytes: UInt64,
                                                  _ total: UInt64, _ speed: Double,
                                                  _ etaSecs: Int64) -> Void
    public typealias CompletionHandler = @Sendable (_ success: Bool, _ errorMessage: String?) -> Void

    /// What to do when a source's name already exists in the destination.
    public enum ConflictPolicy: Sendable {
        /// Leave existing destination files alone (rsync --ignore-existing).
        /// A skipped file stays in the source on a move.
        case skip
        /// Overwrite existing files; folders are merged.
        case replace
        /// Transfer the clashing item under a free name ("name 2.ext"),
        /// like Finder's "Keep Both".
        case keepBoth
    }

    public static func copy(rsyncPath: String, sources: [String], dstDir: String,
                            conflict: ConflictPolicy,
                            onProgress: @escaping ProgressHandler,
                            onDone: @escaping CompletionHandler) {
        start(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
              conflict: conflict, isMove: false, onProgress: onProgress, onDone: onDone)
    }

    public static func move(rsyncPath: String, sources: [String], dstDir: String,
                            conflict: ConflictPolicy,
                            onProgress: @escaping ProgressHandler,
                            onDone: @escaping CompletionHandler) {
        start(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
              conflict: conflict, isMove: true, onProgress: onProgress, onDone: onDone)
    }

    private static func start(rsyncPath: String, sources: [String], dstDir: String,
                              conflict: ConflictPolicy, isMove: Bool,
                              onProgress: @escaping ProgressHandler,
                              onDone: @escaping CompletionHandler) {
        Thread.detachNewThread {
            run(rsyncPath: rsyncPath, sources: sources, dstDir: dstDir,
                conflict: conflict, isMove: isMove,
                onProgress: onProgress, onDone: onDone)
        }
    }

    private static func run(rsyncPath: String, sources: [String], dstDir: String,
                            conflict: ConflictPolicy, isMove: Bool,
                            onProgress: @escaping ProgressHandler,
                            onDone: CompletionHandler) {
        // Destination needs a trailing slash: rsync copies sources *into* the dir.
        let dst = dstDir.hasSuffix("/") ? dstDir : dstDir + "/"

        // Decide where each source lands. Under .keepBoth a clashing source
        // gets a free name; names picked earlier in this transfer count as
        // taken so two same-named sources don't pick the same one.
        var batch: [String] = []                              // → dst/<own name>
        var renamed: [(src: String, target: String)] = []     // → dst/<free name>
        var taken = Set<String>()
        for src in sources {
            let name = (src as NSString).lastPathComponent
            if conflict == .keepBoth, exists(dst + name) || taken.contains(name) {
                let free = freeName(for: name, in: dst, taken: taken)
                taken.insert(free)
                renamed.append((src, dst + free))
            } else {
                taken.insert(name)
                batch.append(src)
            }
        }

        // Moves within one volume are a rename(2): instant locally and done
        // server-side on network shares, instead of copying every byte through
        // this machine and deleting the source. Only sources that rename can't
        // handle (another volume → EXDEV, or a name collision that needs
        // rsync's merge/--ignore-existing semantics) fall through to rsync.
        if isMove {
            batch = batch.filter { !renameIfFree($0, dst + ($0 as NSString).lastPathComponent) }
            renamed = renamed.filter { !renameIfFree($0.src, $0.target) }
        }

        // One rsync run for the batch, one per renamed source. A directory is
        // renamed by syncing its *contents* (`src/`) into `target/`; a file
        // (or symlink) is copied straight to the `target` path.
        var jobs: [(sources: [String], dst: String)] = []
        if !batch.isEmpty { jobs.append((batch, dst)) }
        for r in renamed {
            jobs.append(isDirectory(r.src) ? ([r.src + "/"], r.target + "/") : ([r.src], r.target))
        }

        if jobs.isEmpty {
            onProgress(1.0, 0, 0, 0, 0)
            onDone(true, nil)
            return
        }

        for (i, job) in jobs.enumerated() {
            var args = ["-a", "--info=progress2", "--no-inc-recursive"]
            if conflict == .skip { args.append("--ignore-existing") }
            if isMove { args.append("--remove-source-files") } // atomic move
            args.append(contentsOf: job.sources)
            args.append(job.dst)

            // Each run reports its own 0…1; spread them evenly over the bar.
            let base = Double(i), count = Double(jobs.count)
            let isLast = i == jobs.count - 1
            if let error = rsync(rsyncPath, args: args, finalRun: isLast, onProgress: { p, bytes, speed, eta in
                let overall = p > 1.0 ? p : (base + p) / count
                onProgress(overall, bytes, 0, speed, isLast ? eta : 0)
            }) {
                onDone(false, error)
                return
            }
        }

        // For a move, --remove-source-files only removes files (not empty
        // dirs). Clean up the directories it emptied — but only empty ones:
        // with --ignore-existing, skipped files stay in the source and must
        // not be deleted along with it.
        if isMove {
            for src in batch + renamed.map(\.src) {
                removeEmptyDirs(src)
            }
        }

        onDone(true, nil)
    }

    /// Run one rsync invocation. Returns nil on success or a user-facing
    /// error message. `onProgress` gets (progress, bytes, speed, eta).
    private static func rsync(_ rsyncPath: String, args: [String], finalRun: Bool,
                              onProgress: @escaping @Sendable (Double, UInt64, Double, Int64) -> Void) -> String? {
        let child = Subprocess(executablePath: rsyncPath, arguments: args)

        // After the data transfer hits 100%, rsync keeps running while the OS
        // flushes writes to disk. 500 ms after the final 100% line we send
        // progress > 1.0 so the UI can show "Sincronizando…" with an
        // indeterminate bar. The group guarantees the signal fires before
        // completion is reported (matching the old thread-join ordering).
        // Only the last run of a transfer does this — earlier ones just
        // report 100% of their share.
        var sentComplete = false
        var syncSignal: DispatchGroup?

        let spawnError = child.run { line in
            guard let info = RsyncProgressParser.parse(line: line), !sentComplete else { return }
            if info.progress >= 1.0 {
                sentComplete = true
                // rsync's --info=progress2 doesn't emit a stable total byte
                // count per line, so pass 0 and let the UI display bytes+speed.
                onProgress(info.progress, info.bytes, info.speed, 0)
                guard finalRun else { return }
                let group = DispatchGroup()
                group.enter()
                syncSignal = group
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    onProgress(1.5, 0, 0, 0)
                    group.leave()
                }
            } else {
                // ETA from speed and remaining share of the (estimated) total.
                var eta: Int64 = 0
                if info.speed > 0, info.progress > 0, info.progress < 1.0 {
                    let totalEst = Double(info.bytes) / info.progress
                    eta = Int64((totalEst - Double(info.bytes)) / info.speed)
                }
                onProgress(info.progress, info.bytes, info.speed, eta)
            }
        }

        if let spawnError { return "Error: \(spawnError)" }

        // Wait for the sync-phase signal before reporting completion.
        syncSignal?.wait()

        guard child.exitCode == 0 else {
            let se = child.stderrText
            return se.isEmpty ? String(format: String(localized: "rsync exited with code %d"), child.exitCode) : "rsync: \(se)"
        }
        return nil
    }

    /// Finder-style free name in `dir`: "photo.jpg" → "photo 2.jpg",
    /// "photo 3.jpg", …; folders and extensionless files get "name 2".
    static func freeName(for name: String, in dir: String, taken: Set<String> = []) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        // A leading-dot name like ".env" has no extension to preserve.
        let stem = ext.isEmpty || (name.hasPrefix(".") && ns.deletingPathExtension.isEmpty)
            ? name : ns.deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var n = 2
        while true {
            let candidate = "\(stem) \(n)\(suffix)"
            if !taken.contains(candidate), !exists(dir + candidate) { return candidate }
            n += 1
        }
    }

    /// lstat, not fileExists: a dangling symlink still counts as taken.
    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Try to move `src` to `target` with a plain rename. Returns false —
    /// leaving `src` untouched — when `target` already exists or the rename
    /// fails (e.g. EXDEV across volumes).
    private static func renameIfFree(_ src: String, _ target: String) -> Bool {
        if exists(target) { return false }
        return rename(src, target) == 0
    }

    /// Remove `path` and its subdirectories bottom-up, but only where they are
    /// empty (rmdir semantics). Files and symlinks are never touched.
    private static func removeEmptyDirs(_ path: String) {
        guard isDirectory(path) else { return }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for child in children {
            removeEmptyDirs(path + "/" + child)
        }
        rmdir(path) // fails harmlessly if something was left behind
    }
}
