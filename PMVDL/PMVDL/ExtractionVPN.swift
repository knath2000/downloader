import Foundation

enum ExtractionVPNPreferenceKeys {
    static let enabled = "extractionVPNRetryEnabled"
    static let serviceName = "extractionVPNServiceName"
}

struct ExtractionVPNService: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String

    var isConnected: Bool {
        status.localizedCaseInsensitiveContains("connected")
            && !status.localizedCaseInsensitiveContains("disconnected")
    }
}

enum ExtractionVPNTestResult: Equatable {
    case usable(Int)
    case challenged(Int)
    case blocked(Int)
    case failed(String)

    var message: String {
        switch self {
        case .usable(let statusCode):
            return "OK - Playmogo responded with HTTP \(statusCode)."
        case .challenged(let statusCode):
            return "Blocked - Playmogo returned a browser challenge with HTTP \(statusCode)."
        case .blocked(let statusCode):
            return "Blocked - Playmogo returned HTTP \(statusCode)."
        case .failed(let detail):
            return "Failed - \(detail)"
        }
    }

    var isSuccess: Bool {
        if case .usable = self { return true }
        return false
    }
}

enum ExtractionVPNManager {
    static let scutilURL = URL(fileURLWithPath: "/usr/sbin/scutil")

    static func services() async -> [ExtractionVPNService] {
        do {
            let result = try await SubprocessRunner.run(
                executable: scutilURL,
                arguments: ["--nc", "list"],
                timeout: 5
            )
            guard result.exitStatus == 0 else { return [] }
            return parseServices(from: result.stdout)
        } catch {
            return []
        }
    }

    static func status(for serviceName: String) async -> String? {
        let name = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        do {
            let result = try await SubprocessRunner.run(
                executable: scutilURL,
                arguments: ["--nc", "status", name],
                timeout: 5
            )
            guard result.exitStatus == 0 else { return nil }
            return result.stdout
                .split(whereSeparator: \.isNewline)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            return nil
        }
    }

    static func isConnected(serviceName: String) async -> Bool {
        guard let status = await status(for: serviceName) else { return false }
        return status.localizedCaseInsensitiveContains("connected")
            && !status.localizedCaseInsensitiveContains("disconnected")
    }

    static func testPlaymogoReachability() async -> ExtractionVPNTestResult {
        guard let url = URL(string: "https://playmogo.com/") else {
            return .failed("Invalid Playmogo test URL.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("No HTTP response.")
            }

            let statusCode = httpResponse.statusCode
            let mitigated = httpResponse.value(forHTTPHeaderField: "cf-mitigated")?.localizedCaseInsensitiveContains("challenge") == true
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? ""
            if mitigated || body.localizedCaseInsensitiveContains("Just a moment") {
                return .challenged(statusCode)
            }
            return (200...399).contains(statusCode) ? .usable(statusCode) : .blocked(statusCode)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parseServices(from output: String) -> [ExtractionVPNService] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ExtractionVPNService? in
                let raw = String(line)
                guard raw.contains("[VPN:"),
                      let nameRange = raw.range(of: #""([^"]+)""#, options: .regularExpression),
                      let statusRange = raw.range(of: #"\([^)]+\)"#, options: .regularExpression) else {
                    return nil
                }

                let name = String(raw[nameRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let status = String(raw[statusRange]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                return ExtractionVPNService(id: name, name: name, status: status)
            }
    }
}
