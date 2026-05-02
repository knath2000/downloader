import SwiftUI

@MainActor
struct SchedulerView: View {
    @StateObject private var engine = SchedulerEngine.shared
    @State private var showNewTask = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent)
                Text("Scheduler").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("New Task") { showNewTask.toggle() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(engine.isRunning ? "Stop" : "Start") {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if engine.tasks.isEmpty {
                VStack {
                    Image(systemName: "calendar.badge.clock")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .padding()
                    Text("No scheduled tasks").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text("Add a one-time, recurring, or watch-mode task").font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(engine.tasks) { task in
                            TaskCard(task: task,
                                onToggle: { engine.toggleTask(task) },
                                onDelete: { engine.removeTask(task) })
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            Spacer()
        }
        .sheet(isPresented: $showNewTask) {
            NewTaskForm()
        }
    }
}

struct TaskCard: View {
    let task: ScheduledTask
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: .constant(task.enabled))
                    .toggleStyle(.switch)
                    .disabled(true)
                    .onTapGesture { onToggle() }

                VStack(alignment: .leading) {
                    Text(task.type.displayName).font(.caption.bold())
                    Text(task.trigger.description).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()

                if let lr = task.lastRun {
                    Text("Last: \(lr.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                Button("Delete", role: .destructive) { onDelete() }
                    .buttonStyle(.bordered).controlSize(.mini)
            }

            ForEach(Array(task.urls.enumerated()), id: \.offset) { _, url in
                Text(url).font(.caption2).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(8)
        .glassCard(tint: Theme.lavender.opacity(0.25), cornerRadius: 12)
    }
}

struct NewTaskForm: View {
    @Environment(\.dismiss) var dismiss
    @State private var taskType: TaskType = .oneTime
    @State private var urls: String = ""
    @State private var cronExpression: String = "0 9 * * *"
    @State private var targetDate = Date()
    @State private var cloudTarget: CloudTarget = .mega
    @State private var qualityFilter: String = ""
    @State private var watchURL: String = ""
    @State private var intervalMinutes = 30

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("New Scheduled Task").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Form {
                Picker("Type", selection: $taskType) {
                    ForEach(TaskType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }

                if taskType == .watchMode {
                    TextField("URL to watch", text: $watchURL)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Check every \(intervalMinutes)m", value: $intervalMinutes, in: 5...1440, step: 5)
                } else if taskType == .rssMode {
                    TextField("RSS feed URL", text: $watchURL)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Check every \(intervalMinutes)m", value: $intervalMinutes, in: 5...1440, step: 5)
                } else if taskType == .oneTime {
                    DatePicker("Run at", selection: $targetDate)
                } else {
                    TextField("Cron expression", text: $cronExpression)
                        .textFieldStyle(.roundedBorder)
                    Text("Format: minute hour day month weekday").font(.caption2).foregroundStyle(Theme.textSecondary)
                }

                Picker("Cloud Target", selection: $cloudTarget) {
                    Text("Mega").tag(CloudTarget.mega)
                    Text("GDrive").tag(CloudTarget.gdrive)
                }

                TextField("Quality filter (optional)", text: $qualityFilter)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Button("Create") {
                let urlsList = urls.split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
                let finalURLs = taskType == .watchMode || taskType == .rssMode ? [watchURL] : urlsList.isEmpty ? [""] : urlsList
                let trigger: TaskTrigger
                switch taskType {
                case .oneTime: trigger = .oneTime(targetDate)
                case .recurring: trigger = .recurring(CronExpression(from: cronExpression))
                case .watchMode: trigger = .watchMode(url: watchURL, intervalMinutes: intervalMinutes)
                case .rssMode: trigger = .rssMode(url: watchURL, intervalMinutes: intervalMinutes)
                }
                let task = ScheduledTask(type: taskType, trigger: trigger, urls: finalURLs,
                                         cloudTarget: cloudTarget, qualityFilter: qualityFilter.isEmpty ? nil : qualityFilter)
                SchedulerEngine.shared.addTask(task)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .frame(width: 400, height: 500)
    }
}
