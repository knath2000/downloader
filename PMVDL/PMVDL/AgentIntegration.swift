import Combine
import Darwin
import Foundation
import Security

enum LustreAgentJobStatus: String, Codable {
    case queued, running, paused, completed, failed, cancelled, verificationRequired
}

enum LustreAgentAction: String, Codable {
    case pause, resume, cancel, retry, forceStart
}

enum LustreAgentMediaKind: String, Codable {
    case direct, hls
    case ytDlp = "yt-dlp"
}

struct LustreAgentQualitySelector: Codable {
    let provider: String
    let mediaKind: LustreAgentMediaKind
    let formatSelector: String?
}

struct LustreAgentAssistedResolution: Codable {
    let mediaURL: URL
    let headers: [String: String]
    let mediaKind: LustreAgentMediaKind
    let title: String?
    let resolutionMethod: String
}

struct LustreAgentCompletionArtifact: Codable {
    let kind: String
    let path: String?
    let destination: String
    let filename: String
}

struct LustreAgentJob: Codable, Identifiable {
    let id: UUID
    let sourcePageURL: URL
    var title: String?
    var preferredQualityLabel: String?
    var destination: String
    var status: LustreAgentJobStatus
    var message: String
    var progress: Double?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var transferPhase: String?
    var phaseProgress: Double?
    var phaseBytes: Int64?
    var phaseTotalBytes: Int64?
    var phaseBytesPerSecond: Double?
    var completionArtifact: LustreAgentCompletionArtifact?
    var queuePriority: Int?
    let createdAt: Date
    var updatedAt: Date
}

struct LustreAgentHealth: Codable, Equatable {
    let status: String
    let runtimeVersion: String
    let databaseReady: Bool
    let activeJobs: Int

    private enum CodingKeys: String, CodingKey {
        case status, runtimeVersion, databaseReady, activeJobs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        runtimeVersion = try container.decodeIfPresent(String.self, forKey: .runtimeVersion) ?? "legacy"
        databaseReady = try container.decodeIfPresent(Bool.self, forKey: .databaseReady) ?? (status == "ok")
        activeJobs = try container.decodeIfPresent(Int.self, forKey: .activeJobs) ?? 0
    }
}

struct LustreAgentJobHistoryPage: Codable {
    let jobs: [LustreAgentJob]
    let nextCursor: Int?
}

struct LustreAgentExtractionResult: Codable {
    let sourcePageURL: URL
    let resolutionState: String
    let resolution: LustreAgentResolution?
}

struct LustreAgentResolution: Codable {
    let sourcePageURL: URL
    let provider: String
    let title: String?
    let thumbnailURL: URL?
    let qualities: [LustreAgentQuality]
}

struct LustreAgentQuality: Codable {
    let label: String
    let url: URL
    let headers: [String: String]
    let resolutionMethod: String
    let mediaKind: LustreAgentMediaKind
    let formatSelector: String?
}

struct LustreAgentCreateJobRequest: Codable {
    let id: UUID
    let sourcePageURL: URL
    let title: String?
    let preferredQualityLabel: String?
    let qualitySelector: LustreAgentQualitySelector?
    let assistedResolution: LustreAgentAssistedResolution?
    let destination: String
}

enum LustreAgentClientError: LocalizedError {
    case unavailable
    case invalidResponse
    case server(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The background Agent is not available."
        case .invalidResponse: "The background Agent returned an invalid response."
        case .server(let message): message
        case .http(let status, let message): "Agent request failed with HTTP \(status): \(message)"
        }
    }
}

struct LustreAgentClient {
    private let port: UInt16
    private let token: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LustreStudioAgent", isDirectory: true)
        let endpointURL = support.appendingPathComponent("endpoint.json")
        guard let data = try? Data(contentsOf: endpointURL),
              let endpoint = try? decoder.decode(Endpoint.self, from: data),
              let token = Self.keychainToken() else {
            throw LustreAgentClientError.unavailable
        }
        port = endpoint.port
        self.token = token
    }

    func health() async throws -> LustreAgentHealth {
        try await request(path: "/health", method: "GET", body: nil, authenticated: false)
    }

    func operationalSnapshot() async throws -> LustreAgentPollSnapshot {
        do {
            return try await request(path: "/v1/snapshot?terminalLimit=25", method: "GET", body: nil)
        } catch LustreAgentClientError.http(404, _) {
            async let health = health()
            async let jobs = jobs(scope: "active")
            return try await LustreAgentPollSnapshot(health: health, jobs: jobs)
        }
    }

    func jobs(scope: String? = nil) async throws -> [LustreAgentJob] {
        let path = scope.map { "/v1/jobs?scope=\($0)&terminalLimit=25" } ?? "/v1/jobs"
        do {
            return try await request(path: path, method: "GET", body: nil)
        } catch LustreAgentClientError.http(404, _) where scope != nil {
            return try await request(path: "/v1/jobs", method: "GET", body: nil)
        }
    }

    func completedJobHistory(cursor: Int = 0, limit: Int = 50) async throws -> LustreAgentJobHistoryPage {
        try await request(path: "/v1/job-history?cursor=\(cursor)&limit=\(limit)", method: "GET", body: nil)
    }

    func collections() async throws -> AgentCollectionSnapshot {
        try await request(path: "/v1/collections", method: "GET", body: nil)
    }

    func saveWatchlist(_ item: WatchlistItem) async throws -> AgentCollectionSnapshot {
        try await request(path: "/v1/collections/watchlist", method: "POST", body: try encoder.encode(item))
    }

    func removeWatchlist(sourcePageURL: String) async throws -> AgentCollectionSnapshot {
        try await request(path: "/v1/collections/watchlist", method: "DELETE", body: try encoder.encode(["sourcePageURL": sourcePageURL]))
    }

    func organizeLibrary(sourcePageURL: String, tags: [String], collection: String?, favorite: Bool) async throws -> AgentCollectionSnapshot {
        try await request(path: "/v1/collections/library", method: "PATCH", body: try encoder.encode(AgentLibraryOrganization(sourcePageURL: sourcePageURL, tags: tags, collection: collection, favorite: favorite)))
    }

    func removeLibrary(sourcePageURL: String) async throws -> AgentCollectionSnapshot {
        try await request(path: "/v1/collections/library", method: "DELETE", body: try encoder.encode(["sourcePageURL": sourcePageURL]))
    }

    func setMaximumConcurrentDownloads(_ limit: Int) async throws {
        let _: StatusEnvelope = try await request(
            path: "/v1/entitlement",
            method: "POST",
            body: try encoder.encode(["maximumConcurrentDownloads": max(limit, 1)])
        )
    }

    func extract(url: URL) async throws -> LustreAgentExtractionResult {
        try await request(path: "/v1/extract", method: "POST", body: try encoder.encode(["url": url.absoluteString]))
    }

    func queue(_ input: LustreAgentCreateJobRequest) async throws -> LustreAgentJob {
        try await request(path: "/v1/jobs", method: "POST", body: try encoder.encode(input))
    }

    func apply(_ action: LustreAgentAction, id: UUID) async throws -> LustreAgentJob {
        try await request(path: "/v1/jobs/\(id.uuidString)/action", method: "POST", body: try encoder.encode(["action": action.rawValue]))
    }

    func reorderJobs(_ ids: [UUID]) async throws -> [LustreAgentJob] {
        try await request(path: "/v1/jobs/order", method: "POST", body: try encoder.encode(["ids": ids.map(\.uuidString)]))
    }

    func removeJob(id: UUID) async throws {
        let _: EmptyEnvelope = try await request(path: "/v1/jobs/\(id.uuidString)", method: "DELETE", body: nil)
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?, authenticated: Bool = true) async throws -> T {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LustreAgentClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ErrorEnvelope.self, from: data).error) ?? "Agent request failed with HTTP \(http.statusCode)."
            throw LustreAgentClientError.http(http.statusCode, message)
        }
        guard let value = try? decoder.decode(T.self, from: data) else {
            throw LustreAgentClientError.invalidResponse
        }
        return value
    }

    private static func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.pmvdl.lustre-agent",
            kSecAttrAccount as String: "local-api-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct Endpoint: Codable { let port: UInt16 }
    private struct ErrorEnvelope: Codable { let error: String }
    private struct StatusEnvelope: Codable { let status: String }
    private struct EmptyEnvelope: Codable {}
}

struct AgentCollectionSnapshot: Decodable {
    let watchlist: [WatchlistItem]
    let library: [AgentLibraryItem]
    let cursor: Int64
    let pendingChanges: Int
}

struct AgentLibraryItem: Decodable {
    let id: UUID
    let sourcePageURL: URL
    let title: String
    let provider: String
    let thumbnailURL: URL?
    let mediaKind: String
    let completedAt: Date
    let tags: [String]
    let collection: String?
    let favorite: Bool

    var libraryItem: LibraryItem {
        LibraryItem(
            id: id, url: sourcePageURL.absoluteString, title: title,
            mp4Url: nil, hlsUrls: [], extractedAt: completedAt,
            thumbnailURL: thumbnailURL?.absoluteString, sourceSiteName: provider,
            remotePaths: [:], tags: tags.isEmpty ? nil : tags, collectionName: collection
        )
    }
}

private struct AgentLibraryOrganization: Encodable {
    let sourcePageURL: String
    let tags: [String]
    let collection: String?
    let favorite: Bool
}

struct LustreAgentPollSnapshot: Codable {
    let health: LustreAgentHealth
    let jobs: [LustreAgentJob]
}

@MainActor
final class LustreAgentController: ObservableObject {
    static let shared = LustreAgentController()

    @Published private(set) var health: LustreAgentHealth?
    @Published private(set) var lastError: String?
    @Published private(set) var isUpdatePending = false

    private var pollingTask: Task<Void, Never>?
    private var importedCompletions = Set<UUID>()
    private var projectedJobUpdates: [UUID: Date] = [:]
    private var activeJobCount = 0
    private var refreshInFlight = false
    private var lastEntitlementLimit: Int?
    private var lastEntitlementSyncAttempt: Date?
    private var activeRemovalIDs = Set<UUID>()
    private var completedHistoryCursor: Int? = 0
    private var completedHistoryLoaded = false
    private var completedHistoryLoading = false
    private var pendingRemovalIDs: Set<UUID> = Set(
        UserDefaults.standard.stringArray(forKey: "lustreAgentPendingRemovalIDs")?
            .compactMap(UUID.init(uuidString:)) ?? []
    )

    private init() {}

    func start() {
        guard pollingTask == nil else { return }
        Task { await installOrRepairIfNeeded() }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let active = self?.activeJobCount ?? 0
                try? await Task.sleep(nanoseconds: active > 0 ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        do {
            let entitlementLimit = ProFeatureGate.concurrentDownloadLimit
            let now = Date()
            let shouldSyncEntitlement = lastEntitlementLimit != entitlementLimit ||
                lastEntitlementSyncAttempt.map { now.timeIntervalSince($0) >= 60 } != false
            let snapshot = try await Task.detached(priority: .utility) {
                let client = try LustreAgentClient()
                if shouldSyncEntitlement {
                    try? await client.setMaximumConcurrentDownloads(entitlementLimit)
                }
                return try await client.operationalSnapshot()
            }.value
            if shouldSyncEntitlement {
                lastEntitlementLimit = entitlementLimit
                lastEntitlementSyncAttempt = now
            }
            if health != snapshot.health {
                health = snapshot.health
            }
            activeJobCount = snapshot.jobs.filter { $0.status == .running }.count
            if lastError != nil {
                lastError = nil
            }
            if Int(snapshot.health.runtimeVersion) ?? 0 >= 6 {
                await reconcilePendingRemovals()
            }
            project(snapshot.jobs)
            if isUpdatePending, activeJobCount == 0 {
                await installOrRepairIfNeeded()
            }
        } catch {
            if health != nil {
                health = nil
            }
            let message = error.localizedDescription
            if lastError != message {
                lastError = message
            }
        }
    }

    func loadCompletedHistoryIfNeeded() async {
        guard !completedHistoryLoaded else { return }
        await loadMoreCompletedHistory()
    }

    func loadMoreCompletedHistory() async {
        guard !completedHistoryLoading, let cursor = completedHistoryCursor else { return }
        completedHistoryLoading = true
        defer { completedHistoryLoading = false }
        do {
            let page = try await Task.detached(priority: .utility) {
                try await LustreAgentClient().completedJobHistory(cursor: cursor)
            }.value
            project(page.jobs)
            completedHistoryCursor = page.nextCursor
            completedHistoryLoaded = true
        } catch LustreAgentClientError.http(404, _) {
            do {
                let completed = try await Task.detached(priority: .utility) {
                    try await LustreAgentClient().jobs().filter { $0.status == .completed }
                }.value
                project(Array(completed.prefix(50)))
                completedHistoryCursor = completed.count > 50 ? 50 : nil
                completedHistoryLoaded = true
            } catch {
                lastError = error.localizedDescription
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func preview(url: URL) async throws -> LustreAgentExtractionResult {
        try await Task.detached(priority: .userInitiated) {
            try await LustreAgentClient().extract(url: url)
        }.value
    }

    func enqueue(
        id: UUID,
        sourcePageURL: String,
        title: String,
        preferredQualityLabel: String?,
        target: CloudTarget,
        assistedResolution: LustreAgentAssistedResolution? = nil,
        selector: LustreAgentQualitySelector? = nil
    ) async {
        do {
            guard let sourceURL = URL(string: sourcePageURL) else { throw VideoExtractorError.invalidURL }
            let client = try LustreAgentClient()
            let preview = try await client.extract(url: sourceURL)
            let effectiveAssistance: LustreAgentAssistedResolution?
            if preview.resolutionState == "verificationRequired" {
                guard let assistedResolution else {
                    throw LustreAgentClientError.server("Browser verification is required. Reopen this scene in LustreStudio to continue.")
                }
                effectiveAssistance = assistedResolution
            } else {
                effectiveAssistance = nil
            }
            guard target == .local else { throw RemovedDestinationError.unsupported(target) }
            let request = LustreAgentCreateJobRequest(
                id: id,
                sourcePageURL: sourceURL,
                title: title,
                preferredQualityLabel: preferredQualityLabel,
                qualitySelector: selector,
                assistedResolution: effectiveAssistance,
                destination: "local"
            )
            _ = try await client.queue(request)
            await refresh()
        } catch {
            DownloadQueue.shared.fail(id: id, message: error.localizedDescription)
        }
    }

    func apply(_ action: LustreAgentAction, id: UUID) {
        Task {
            do {
                _ = try await LustreAgentClient().apply(action, id: id)
                await refresh()
            } catch {
                DownloadQueue.shared.fail(id: id, message: error.localizedDescription)
            }
        }
    }

    func reorderQueuedJobs(_ ids: [UUID]) {
        Task {
            do {
                let jobs = try await LustreAgentClient().reorderJobs(ids)
                project(jobs)
            } catch {
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func retry(id: UUID, payload: DownloadRetryPayload, title: String) {
        Task {
            do {
                _ = try await LustreAgentClient().apply(.retry, id: id)
                await refresh()
            } catch LustreAgentClientError.http(404, _) {
                DownloadQueue.shared.update(
                    id: id,
                    status: .waiting,
                    progress: 0,
                    message: "Restoring job in background Agent…"
                )
                await enqueue(
                    id: id,
                    sourcePageURL: payload.sourcePageURL,
                    title: title,
                    preferredQualityLabel: payload.preferredQualityLabel,
                    target: payload.target
                )
            } catch {
                DownloadQueue.shared.fail(id: id, message: error.localizedDescription)
            }
        }
    }

    func remove(id: UUID) {
        guard activeRemovalIDs.insert(id).inserted else { return }
        pendingRemovalIDs.insert(id)
        persistPendingRemovals()
        Task {
            defer { activeRemovalIDs.remove(id) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let client = try LustreAgentClient()
                    do {
                        try await client.removeJob(id: id)
                    } catch let LustreAgentClientError.http(status, message)
                        where status == 404 || (status == 400 && message.hasPrefix("No job exists with id ")) {
                        return
                    }
                }.value
                pendingRemovalIDs.remove(id)
                persistPendingRemovals()
                projectedJobUpdates[id] = nil
                importedCompletions.remove(id)
                DownloadQueue.shared.removeAgentProjection(id: id)
                await refresh()
            } catch {
                let message = error.localizedDescription
                if lastError != message {
                    lastError = message
                }
                AppStateManager.shared.transientMessage = AppTransientMessage(
                    text: "Unable to remove Agent download: \(message)"
                )
            }
        }
    }

    private func project(_ jobs: [LustreAgentJob]) {
        var changed: [LustreAgentJob] = []
        for job in jobs {
            guard !pendingRemovalIDs.contains(job.id) else { continue }
            guard projectedJobUpdates[job.id] != job.updatedAt else { continue }
            projectedJobUpdates[job.id] = job.updatedAt
            changed.append(job)
            if job.status == .completed {
                importedCompletions.insert(job.id)
            }
        }
        DownloadQueue.shared.projectAgentJobs(changed)
    }

    private func reconcilePendingRemovals() async {
        let ids = pendingRemovalIDs.subtracting(activeRemovalIDs)
        guard !ids.isEmpty else { return }
        let removed = await Task.detached(priority: .utility) {
            guard let client = try? LustreAgentClient() else { return Set<UUID>() }
            var removed = Set<UUID>()
            for id in ids {
                do {
                    try await client.removeJob(id: id)
                    removed.insert(id)
                } catch let LustreAgentClientError.http(status, message)
                    where status == 404 || (status == 400 && message.hasPrefix("No job exists with id ")) {
                    removed.insert(id)
                } catch {
                }
            }
            return removed
        }.value
        guard !removed.isEmpty else { return }
        pendingRemovalIDs.subtract(removed)
        for id in removed {
            projectedJobUpdates[id] = nil
            importedCompletions.remove(id)
            DownloadQueue.shared.removeAgentProjection(id: id)
        }
        persistPendingRemovals()
    }

    private func persistPendingRemovals() {
        UserDefaults.standard.set(
            pendingRemovalIDs.map(\.uuidString).sorted(),
            forKey: "lustreAgentPendingRemovalIDs"
        )
    }

    private func importCompletion(_ job: LustreAgentJob) {
        guard let artifact = job.completionArtifact else { return }
        if artifact.kind == "local", let path = artifact.path {
            DownloadQueue.shared.complete(id: job.id, finalPath: path, message: job.message)
        } else {
            DownloadQueue.shared.complete(id: job.id, finalPath: artifact.path, message: job.message)
        }
    }

    private func installOrRepairIfNeeded() async {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("LustreAgentRuntime", isDirectory: true),
              FileManager.default.fileExists(atPath: bundled.path) else {
            lastError = "The bundled background Agent runtime is missing."
            return
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LustreStudioAgent/Runtime/\(version)", isDirectory: true)
        let executable = support.appendingPathComponent("lustre-agent")
        let runningClient = try? LustreAgentClient()
        let runningHealth = try? await runningClient?.health()
        let activeJobCount = runningHealth?.activeJobs ?? 0
        if let runningHealth, runningHealth.runtimeVersion != version, activeJobCount > 0 {
            isUpdatePending = true
            return
        }
        if !FileManager.default.isExecutableFile(atPath: executable.path) {
            do {
                try FileManager.default.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = support.deletingLastPathComponent().appendingPathComponent(".\(version)-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.copyItem(at: bundled, to: staging)
                try FileManager.default.moveItem(at: staging, to: support)
            } catch {
                lastError = "Unable to install the background Agent: \(error.localizedDescription)"
                return
            }
        }
        guard runningHealth?.runtimeVersion != version || runningHealth?.status != "ok" else {
            isUpdatePending = false
            return
        }
        do {
            try installLaunchAgent(executable: executable, runtimeVersion: version, replacingExisting: runningHealth != nil)
            isUpdatePending = false
        } catch {
            lastError = "Unable to install the background Agent: \(error.localizedDescription)"
        }
    }

    private func installLaunchAgent(executable: URL, runtimeVersion: String, replacingExisting: Bool) throws {
        let launchAgents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist = launchAgents.appendingPathComponent("com.pmvdl.lustre-agent.plist")
        let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LustreStudioAgent/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let configuration: [String: Any] = [
            "Label": "com.pmvdl.lustre-agent",
            "ProgramArguments": [executable.path],
            "EnvironmentVariables": ["LUSTRE_RUNTIME_VERSION": runtimeVersion],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logs.appendingPathComponent("agent.log").path,
            "StandardErrorPath": logs.appendingPathComponent("agent-error.log").path
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        let domain = "gui/\(getuid())"
        if replacingExisting {
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", domain, plist.path]
            try bootout.run()
            bootout.waitUntilExit()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootstrap", domain, plist.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw LustreAgentClientError.server("launchctl could not start the background Agent.")
        }
    }
}
