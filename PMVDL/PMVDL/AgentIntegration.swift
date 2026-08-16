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

struct LustreAgentGoogleDriveProfile: Codable {
    let id: UUID
    let name: String
    let remoteName: String
    let remotePath: String
}

enum LustreAgentClientError: LocalizedError {
    case unavailable
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The background Agent is not available."
        case .invalidResponse: "The background Agent returned an invalid response."
        case .server(let message): message
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

    func jobs() async throws -> [LustreAgentJob] {
        try await request(path: "/v1/jobs", method: "GET", body: nil)
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

    func googleDriveProfiles() async throws -> [LustreAgentGoogleDriveProfile] {
        try await request(path: "/v1/destinations/google-drive", method: "GET", body: nil)
    }

    func connectGoogleDrive(remoteName: String) async throws -> LustreAgentGoogleDriveProfile {
        try await request(path: "/v1/destinations/google-drive/connect", method: "POST", body: try encoder.encode(["remoteName": remoteName]))
    }

    func selectGoogleDrive(profileID: UUID, path: String) async throws -> LustreAgentGoogleDriveProfile {
        try await request(path: "/v1/destinations/google-drive/\(profileID.uuidString)/select", method: "POST", body: try encoder.encode(["path": path]))
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
            throw LustreAgentClientError.server(message)
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
}

@MainActor
final class LustreAgentController: ObservableObject {
    static let shared = LustreAgentController()

    @Published private(set) var health: LustreAgentHealth?
    @Published private(set) var lastError: String?
    @Published private(set) var isUpdatePending = false

    private var pollingTask: Task<Void, Never>?
    private var importedCompletions = Set<UUID>()

    private init() {}

    func start() {
        guard pollingTask == nil else { return }
        Task { await installOrRepairIfNeeded() }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let active = self?.health?.activeJobs ?? 0
                try? await Task.sleep(nanoseconds: active > 0 ? 1_000_000_000 : 5_000_000_000)
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refresh() async {
        do {
            let client = try LustreAgentClient()
            try? await client.setMaximumConcurrentDownloads(ProFeatureGate.concurrentDownloadLimit)
            async let nextHealth = client.health()
            async let nextJobs = client.jobs()
            let (health, jobs) = try await (nextHealth, nextJobs)
            self.health = health
            lastError = nil
            project(jobs)
            if isUpdatePending, health.activeJobs == 0 {
                await installOrRepairIfNeeded()
            }
        } catch {
            health = nil
            lastError = error.localizedDescription
        }
    }

    func enqueue(
        id: UUID,
        sourcePageURL: String,
        title: String,
        preferredQualityLabel: String?,
        target: CloudTarget,
        gdriveRemoteName: String,
        gdriveRemotePath: String,
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
            let destination: String
            if target == .gdrive {
                let profiles = try await client.googleDriveProfiles()
                var profile = profiles.first { $0.remoteName == gdriveRemoteName }
                if profile == nil { profile = try await client.connectGoogleDrive(remoteName: gdriveRemoteName) }
                guard let connected = profile else { throw LustreAgentClientError.unavailable }
                let selected = try await client.selectGoogleDrive(profileID: connected.id, path: gdriveRemotePath)
                destination = "gdrive:\(selected.id.uuidString)"
            } else {
                destination = "local"
            }
            let request = LustreAgentCreateJobRequest(
                id: id,
                sourcePageURL: sourceURL,
                title: title,
                preferredQualityLabel: preferredQualityLabel,
                qualitySelector: selector,
                assistedResolution: effectiveAssistance,
                destination: destination
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

    private func project(_ jobs: [LustreAgentJob]) {
        for job in jobs {
            DownloadQueue.shared.projectAgentJob(job)
            if job.status == .completed, importedCompletions.insert(job.id).inserted {
                importCompletion(job)
            }
        }
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
        let runningJobs = try? await runningClient?.jobs()
        let activeJobCount = runningJobs?.filter { $0.status == .running }.count ?? runningHealth?.activeJobs ?? 0
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
