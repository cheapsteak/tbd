import Foundation

extension Date {
    /// Cached DateFormatters. DateFormatter is expensive to construct;
    /// reuse across calls. Reading a DateFormatter is thread-safe.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let monthDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    /// Absolute local time. "3:42 PM" for today; "May 3, 3:42 PM" for the
    /// current year; "May 3, 2025, 3:42 PM" for older. Never relative.
    var absoluteShort: String {
        let cal = Calendar.current
        let now = Date()
        let timeStr = Self.timeFormatter.string(from: self)
        if cal.isDateInToday(self) {
            return timeStr
        }
        let dateFmt = cal.isDate(self, equalTo: now, toGranularity: .year)
            ? Self.monthDayFormatter
            : Self.monthDayYearFormatter
        return "\(dateFmt.string(from: self)), \(timeStr)"
    }

    /// "Today 3:42 PM", "Yesterday 5:12 PM", "Mon 3:42 PM", "Apr 6, 3:42 PM"
    var smartFormatted: String {
        let cal = Calendar.current
        let now = Date()
        let timeStr = Self.timeFormatter.string(from: self)
        if cal.isDateInToday(self) {
            return "Today \(timeStr)"
        } else if cal.isDateInYesterday(self) {
            return "Yesterday \(timeStr)"
        } else if let days = cal.dateComponents([.day], from: self, to: now).day, days < 7 {
            return "\(Self.weekdayFormatter.string(from: self)) \(timeStr)"
        } else {
            return "\(Self.monthDayFormatter.string(from: self)), \(timeStr)"
        }
    }
}
