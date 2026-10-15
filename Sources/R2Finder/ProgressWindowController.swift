// ProgressWindowController.swift
// Port of ProgressWindowController.m: floating progress window shown while
// rsync / 7zz operations run.

import AppKit

final class ProgressWindowController: NSWindowController {

    private let refreshCallback: () -> Void
    private let operationTitle: String

    private let progressBar = NSProgressIndicator()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let speedLabel = NSTextField(labelWithString: String(localized: "Calculating…"))
    private var cancelButton: NSButton!

    init(title: String, destinationFolder dst: String, refreshCallback: @escaping () -> Void) {
        self.refreshCallback = refreshCallback
        operationTitle = title
        titleLabel = NSTextField(labelWithString: "\(title)…")
        detailLabel = NSTextField(labelWithString: String(format: String(localized: "Destination: %@"), dst))

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.center()

        super.init(window: win)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Title
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(titleLabel)

        // Detail (destination)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(detailLabel)

        // Progress bar
        progressBar.style = .bar
        progressBar.minValue = 0.0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0.0
        progressBar.isIndeterminate = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.startAnimation(nil)
        cv.addSubview(progressBar)

        // Speed / ETA
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(speedLabel)

        // Cancel
        cancelButton = NSButton(title: "Cancelar", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(cancelButton)

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: m),
            titleLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            detailLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            progressBar.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 14),
            progressBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),
            progressBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),

            speedLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            speedLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: m),

            cancelButton.centerYAnchor.constraint(equalTo: speedLabel.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -m),
        ])
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Public API (always called on the main thread)
    // ─────────────────────────────────────────────────────────────────────────

    func updateProgress(_ progress: Double, bytesTransferred bytesDone: UInt64,
                        totalBytes total: UInt64, speed bytesPerSec: Double,
                        etaSecs eta: Int64) {
        // progress > 1.0 signals the sync-to-disk phase (OS write cache flush)
        if progress > 1.0 {
            if !progressBar.isIndeterminate {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            let sizeStr = total > 0 ? formattedSize(total) : formattedSize(bytesDone)
            speedLabel.stringValue = sizeStr + "   " + String(localized: "Syncing…")
            return
        }

        if progressBar.isIndeterminate {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
        }
        // Progress only moves forward — rsync can re-baseline between files,
        // which would otherwise make the bar visibly jump backwards.
        if progress > progressBar.doubleValue { progressBar.doubleValue = progress }

        let pctStr = "\(Int(progressBar.doubleValue * 100))%"
        let sizeStr = formattedSize(bytesDone)
        let speedStr = formattedSpeed(bytesPerSec)
        let etaStr = eta > 0 ? formattedETA(eta) : "—"
        speedLabel.stringValue = "\(pctStr)  •  \(sizeStr)  •  \(speedStr)  •  ETA \(etaStr)"
    }

    func finish(success: Bool, errorMessage msg: String?) {
        if success {
            close()
            refreshCallback()
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            titleLabel.stringValue = String(localized: "Operation failed")
            speedLabel.stringValue = msg ?? String(localized: "Unknown error")
            cancelButton.title = String(localized: "Close")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Actions
    // ─────────────────────────────────────────────────────────────────────────

    @IBAction private func cancelClicked(_ sender: Any?) {
        // TODO: send SIGTERM to the rsync process. For now just close.
        close()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: – Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func formattedSize(_ bytes: UInt64) -> String {
        let v = Double(bytes)
        if v < 1024 { return String(format: "%.0f B", v) }
        if v < 1024 * 1024 { return String(format: "%.1f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB", v / 1024 / 1024) }
        return String(format: "%.2f GB", v / 1024 / 1024 / 1024)
    }

    private func formattedSpeed(_ bps: Double) -> String {
        if bps <= 0 { return "" }
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / 1024 / 1024)
    }

    private func formattedETA(_ secs: Int64) -> String {
        if secs < 0 { return "—" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
