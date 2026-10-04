import Foundation

/// Five-field cron evaluator using the Core machine's local calendar and time zone.
/// Supports wildcards, lists, ranges and steps (for example `1-5` and `0-30/10`).
public struct CronEvaluator {
    private static let bounds = [0...59, 0...23, 1...31, 1...12, 0...7]

    public static func isValid(cronExpression: String) -> Bool {
        fields(cronExpression) != nil
    }

    public static func isDue(cronExpression: String, date: Date = Date()) -> Bool {
        guard let fields = fields(cronExpression) else { return false }
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: date)
        
        let minute = components.minute ?? 0
        let hour = components.hour ?? 0
        let day = components.day ?? 0
        let month = components.month ?? 0
        let weekday = (components.weekday ?? 1) - 1 // 1 is Sunday in Foundation Calendar
        
        return fields[0].contains(minute) &&
               fields[1].contains(hour) &&
               fields[2].contains(day) &&
               fields[3].contains(month) &&
               (fields[4].contains(weekday) || (weekday == 0 && fields[4].contains(7)))
    }

    private static func fields(_ expression: String) -> [Set<Int>]? {
        let parts = expression.split(whereSeparator: \Character.isWhitespace)
        guard parts.count == bounds.count else { return nil }
        var result: [Set<Int>] = []
        for (part, bound) in zip(parts, bounds) {
            guard let values = values(part, bounds: bound) else { return nil }
            result.append(values)
        }
        return result
    }

    private static func values(_ part: Substring, bounds: ClosedRange<Int>) -> Set<Int>? {
        var result: Set<Int> = []
        for item in part.split(separator: ",", omittingEmptySubsequences: false) {
            let stepped = item.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(stepped.count) else { return nil }
            let step: Int
            if stepped.count == 2 {
                guard let parsed = Int(stepped[1]), parsed > 0 else { return nil }
                step = min(parsed, bounds.count)
            } else {
                step = 1
            }

            let lower: Int
            let upper: Int
            if stepped[0] == "*" {
                lower = bounds.lowerBound
                upper = bounds.upperBound
            } else {
                let range = stepped[0].split(separator: "-", omittingEmptySubsequences: false)
                guard (1...2).contains(range.count), let start = Int(range[0]) else { return nil }
                lower = start
                if range.count == 2 {
                    guard let end = Int(range[1]) else { return nil }
                    upper = end
                } else {
                    upper = stepped.count == 2 ? bounds.upperBound : start
                }
            }
            guard bounds.contains(lower), bounds.contains(upper), lower <= upper else { return nil }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        return result.isEmpty ? nil : result
    }
}
