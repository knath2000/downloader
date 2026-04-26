import Foundation

enum TaskTrigger: Codable {
    case oneTime(Date)
    case recurring(CronExpression)
    case watchMode(url: String, intervalMinutes: Int)
    case rssMode(url: String, intervalMinutes: Int)

    var description: String {
        switch self {
        case .oneTime(let d):
            return "Once at \(d.formatted(date: .abbreviated, time: .shortened))"
        case .recurring(let cron):
            return "Recurring: \(cron.expression)"
        case .watchMode(let u, let m):
            return "Watch: \(u) every \(m)m"
        case .rssMode(let u, let m):
            return "RSS: \(u) every \(m)m"
        }
    }
}

struct CronExpression: Codable, Equatable {
    let minute: String
    let hour: String
    let dayOfMonth: String
    let month: String
    let dayOfWeek: String

    var expression: String { "\(minute) \(hour) \(dayOfMonth) \(month) \(dayOfWeek)" }

    init(minute: String = "*", hour: String = "*", dayOfMonth: String = "*",
         month: String = "*", dayOfWeek: String = "*") {
        self.minute = minute
        self.hour = hour
        self.dayOfMonth = dayOfMonth
        self.month = month
        self.dayOfWeek = dayOfWeek
    }

    init(from expression: String) {
        let parts = expression.split(separator: " ").map { String($0) }
        self.minute = parts.count >= 1 ? parts[0] : "*"
        self.hour = parts.count >= 2 ? parts[1] : "*"
        self.dayOfMonth = parts.count >= 3 ? parts[2] : "*"
        self.month = parts.count >= 4 ? parts[3] : "*"
        self.dayOfWeek = parts.count >= 5 ? parts[4] : "*"
    }
}

struct ScheduledTask: Identifiable, Codable {
    let id: UUID
    let type: TaskType
    let trigger: TaskTrigger
    var urls: [String]
    var cloudTarget: CloudTarget
    var qualityFilter: String?  // e.g. "1080p", "mp4"
    var enabled: Bool
    var lastRun: Date?
    let createdAt: Date

    init(id: UUID = UUID(), type: TaskType, trigger: TaskTrigger, urls: [String],
         cloudTarget: CloudTarget = .mega, qualityFilter: String? = nil) {
        self.id = id; self.type = type; self.trigger = trigger
        self.urls = urls; self.cloudTarget = cloudTarget
        self.qualityFilter = qualityFilter
        self.enabled = true
        self.lastRun = nil; self.createdAt = Date()
    }
}

enum TaskType: String, Codable, CaseIterable {
    case oneTime, recurring, watchMode, rssMode

    var displayName: String {
        switch self {
        case .oneTime: return "One-Time"
        case .recurring: return "Recurring"
        case .watchMode: return "Watch Mode"
        case .rssMode: return "RSS Mode"
        }
    }
}
