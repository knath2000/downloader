import Foundation

@MainActor
class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published var transfers: [TransferItem] = []
    @Published var isActive = false
    @Published var isPolling: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var megaExec: URL? { findMegaExec() }

    private init() {}

    func start() {
        guard !isActive else { return }
        isActive = true
        isPolling = true
        pollingTask = Task { await poll() }
    }

    func stop() {
        isActive = false
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    func cancelTransfer(tag: String) async {
        guard !tag.isEmpty else { return }
        guard let megaExec = megaExec else { return }
        let p = Process()
        p.executableURL = megaExec
        p.arguments = ["cancel", tag]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        await fetchTransfers()
    }

    private func poll() async {
        while isActive, !Task.isCancelled {
            await fetchTransfers()
            try? await Task.sleep(for: .seconds(2))
        }
        isPolling = false
    }

    private func fetchTransfers() async {
        guard let megaExec = megaExec else {
            transfers = []
            return
        }

        let p = Process()
        p.executableURL = megaExec
        p.arguments = ["transfers", "--only-uploads", "--path-display-size=500"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        try? p.run()
        let rs = Date()
        while Date().timeIntervalSince(rs) < 5 && p.isRunning {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if p.isRunning { p.terminate() }
        _ = p.waitUntilExit()

        let outPipe = p.standardOutput as! Pipe
        guard let data = try? outPipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8) else {
            transfers = []
            return
        }

        var result: [TransferItem] = []
        for line in output.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.contains("TYPE") || s.isEmpty { continue }
            if let item = parseTransferLine(s) {
                result.append(item)
            }
        }

        transfers = result
        // Update widget data
        if result.isEmpty {
            WidgetDataStore.shared.clearWidgetData()
        } else {
            let activeCount = result.filter { $0.state == "ACTIVE" }.count
            let avgProgress = result.reduce(0.0) { $0 + $1.progress } / Double(result.count)
            WidgetDataStore.shared.updateTransferCount(activeCount, progress: avgProgress)
        }
    }

    /// Parse a line from `mega-exec transfers --only-uploads`.
    ///
    /// Typical format (split by spaces, not tabs):
    /// `⇑ 2269 /var/folders/.../viddl_abc123.mp4 /Cloud/VidDL/  38.20% of  981.87 MB  ACTIVE`
    ///
    /// Source path can contain spaces, so we scan for the `%` token
    /// rather than using fixed end-offsets.
    private func parseTransferLine(_ line: String) -> TransferItem? {
        let parts = line.split(separator: " ").filter { !$0.isEmpty }.map { String($0) }
        guard parts.count >= 5 else { return nil }

        // Tag is always at index 1
        let tag = parts[1]

        // Scan for the element ending with "%" — that's the progress value
        var pctIndex: Int?
        for (i, p) in parts.enumerated() where p.hasSuffix("%") {
            pctIndex = i
        }
        guard let pctIdx = pctIndex else { return nil }

        let progressText = parts[pctIdx]
        let state = parts.last ?? ""

        // Size: the 1-2 tokens after `% of`
        var sizeText: String
        if pctIdx + 3 < parts.count {
            sizeText = parts[pctIdx + 2] + " " + parts[pctIdx + 3]
        } else if pctIdx + 2 < parts.count {
            sizeText = parts[pctIdx + 2]
        } else {
            sizeText = ""
        }

        // Extract numeric progress
        var progress: Double = 0
        if let pctMatch = progressText.range(of: "[\\d.]+", options: .regularExpression) {
            progress = Double(progressText[pctMatch]) ?? 0
        }

        // Extract the filename from the first path-like token (starts / and has a dot)
        var filename = "unknown"
        for part in parts[2...] {
            if part.hasPrefix("/"), part.contains(".") {
                if let slashIdx = part.lastIndex(of: "/") {
                    let name = String(part[part.index(after: slashIdx)...])
                    if !name.isEmpty { filename = name; break }
                }
            }
        }

        return TransferItem(
            id: tag,
            tag: tag,
            filename: filename,
            progress: progress,
            size: sizeText.trimmingCharacters(in: .whitespaces),
            state: state,
            remotePath: ""
        )
    }

    private func findMegaExec() -> URL? {
        ToolLocator.find("mega-exec", extraPaths: ["/Applications/MEGAcmd.app/Contents/MacOS/mega-exec"])
    }
}
