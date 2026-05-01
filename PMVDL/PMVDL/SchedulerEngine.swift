import Foundation
import SwiftUI

@MainActor
class SchedulerEngine: ObservableObject {
    static let shared = SchedulerEngine()

    @Published var tasks: [ScheduledTask] = []
    @Published var isRunning = false

    private var timer: Timer?
    private let tasksKey = "schedulerTasks"

    private init() { loadTasks() }

    private func loadTasks() {
        if let data = UserDefaults.standard.data(forKey: tasksKey),
           let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            tasks = decoded
        }
    }

    func saveTasks() {
        if let encoded = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(encoded, forKey: tasksKey)
        }
    }

    func addTask(_ task: ScheduledTask) {
        tasks.append(task); saveTasks()
    }

    func removeTask(_ task: ScheduledTask) {
        tasks.removeAll { $0.id == task.id }; saveTasks()
    }

    func toggleTask(_ task: ScheduledTask) {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].enabled.toggle(); saveTasks()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkTasks() }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func checkTasks() async {
        let now = Date()
        for task in tasks where task.enabled {
            switch task.trigger {
            case .oneTime(let date):
                if date <= now && task.lastRun == nil {
                    await executeTask(task)
                }
            case .recurring(let cron):
                let parser = CronParser(cron)
                if parser.matches(now), task.lastRun.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                    await executeTask(task)
                    if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                        tasks[idx].lastRun = now
                    }
                    saveTasks()
                }
            case .watchMode(let url, _):
                // Last run check (throttled)
                if task.lastRun.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                    await executeWatchMode(url: url, task: task)
                    if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                        tasks[idx].lastRun = now
                    }
                    saveTasks()
                }
            case .rssMode:
                // RSS mode would parse RSS feed and queue new items
                if task.lastRun.map({ now.timeIntervalSince($0) > 300 }) ?? true {
                    if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
                        tasks[idx].lastRun = now
                    }
                    saveTasks()
                }
            }
        }
    }

    private func executeTask(_ task: ScheduledTask) async {
        for url in task.urls {
            DownloadQueue.shared.add(url: url, quality: task.qualityFilter ?? "MP4", targetCloud: task.cloudTarget)
        }
    }

    private func executeWatchMode(url: String, task: ScheduledTask) async {
        // Scrape the watched URL, compare against library for new content
        do {
            let source = try await VideoScraper.extract(from: url)
            if let mp4 = source.mp4 {
                let isKnown = VideoLibrary.shared.items.contains { $0.mp4Url == mp4 }
                if !isKnown {
                    DownloadQueue.shared.add(url: mp4, quality: "MP4", targetCloud: task.cloudTarget)
                }
            }
        } catch {
            // Silently fail — watch mode is best-effort
        }
    }
}
