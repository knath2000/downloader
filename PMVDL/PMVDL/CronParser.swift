import Foundation

/// Simple 5-field cron expression parser and evaluator.
/// Supports: `*`, numeric values, */N (step), ranges (1-5), lists (1,3,5)
struct CronParser {
    let expression: CronExpression

    init(_ expression: CronExpression) { self.expression = expression }

    /// Check if the given date/time matches this cron expression.
    func matches(_ date: Date) -> Bool {
        let cal = Calendar.current
        let components = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)

        guard let minute = components.minute, let hour = components.hour,
              let day = components.day, let month = components.month,
              let weekday = components.weekday else { return false }

        // cron weekday: 0=Sun, 1=Mon, ..., 6=Sat; Swift: 1=Sun, 2=Mon, ..., 7=Sat
        let cronWeekday = weekday == 1 ? 0 : weekday - 1

        return fieldMatches(expression.minute, value: minute, min: 0, max: 59)
            && fieldMatches(expression.hour, value: hour, min: 0, max: 23)
            && fieldMatches(expression.dayOfMonth, value: day, min: 1, max: 31)
            && fieldMatches(expression.month, value: month, min: 1, max: 12)
            && fieldMatches(expression.dayOfWeek, value: cronWeekday, min: 0, max: 6)
    }

    /// Get the next date after `from` that matches this cron expression.
    /// Returns nil if no match found within 365 days.
    func nextFireDate(after from: Date) -> Date? {
        var date = Calendar.current.date(byAdding: .minute, value: 1, to: from)!
        let limit = Calendar.current.date(byAdding: .day, value: 365, to: from)!
        while date < limit {
            if matches(date) { return date }
            // Jump by minute is slow for large ranges, so jump by the appropriate field
            date = Calendar.current.date(byAdding: .minute, value: 1, to: date)!
        }
        return nil
    }

    private func fieldMatches(_ pattern: String, value: Int, min: Int, max: Int) -> Bool {
        if pattern == "*" { return true }

        // Handle */N (step)
        if pattern.hasPrefix("*/") {
            let step = Int(pattern.dropFirst(2)) ?? 1
            return step > 0 && (value - min) % step == 0
        }

        // Handle comma-separated values
        if pattern.contains(",") {
            return pattern.split(separator: ",").compactMap { Int($0) }.contains(value)
        }

        // Handle range (e.g. 1-5)
        if pattern.contains("-") {
            let parts = pattern.split(separator: "-").compactMap { Int($0) }
            if parts.count == 2 { return value >= parts[0] && value <= parts[1] }
        }

        // Simple number
        if let num = Int(pattern) { return value == num }

        return false
    }
}
