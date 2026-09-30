import Foundation

/// Works out a reminder's due time from what the user said. Small models are unreliable at date
/// arithmetic ("at 5" in the evening, "tomorrow" late at night), so this is done in code.
///
/// Rules:
/// - "in 20 minutes", "in an hour", "in half an hour" count from now.
/// - A day ("today", "tomorrow", "Friday", "next Monday", "October 3") without a time means 9:00,
///   or the time of day it names ("tonight" 20:00, "this evening" 18:00).
/// - "at 5" with no am/pm and no day means the next 5 o'clock. On another day, 1–7 means pm.
/// - A time that has already passed today moves to tomorrow.
/// - No day or time at all means no due date.
enum DueDate {
    static func resolve(_ said: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let text = said.lowercased()
        if let offset = relativeOffset(text) { return now.addingTimeInterval(offset) }

        let today = calendar.startOfDay(for: now)
        let day = dayOffset(text, today: today, calendar: calendar).map { calendar.date(byAdding: .day, value: $0, to: today)! }
            ?? calendarDate(text, calendar: calendar)
        let period = partOfDay(text)
        let time = clockTime(text)
        guard day != nil || time != nil || period != nil else { return nil }

        func on(_ date: Date, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
        }
        func hour(_ time: ClockTime, pm: Bool) -> Int {
            time.hour == 12 ? (pm ? 12 : 0) : time.hour + (pm ? 12 : 0)
        }

        // A named day: use the time given, the part of day, or 9:00.
        if let day {
            guard let time else { return on(day, period?.defaultHour ?? 9, 0) }
            switch time.meridiem {
            case .fixed: return on(day, time.hour, time.minute)
            case .am, .pm: return on(day, hour(time, pm: time.meridiem == .pm), time.minute)
            case .ambiguous:
                let pm = period.map { $0.isPM } ?? ((1...7).contains(time.hour) || time.hour == 12)
                return on(day, hour(time, pm: pm), time.minute)
            }
        }

        // No day: today if still ahead, otherwise tomorrow.
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let candidates: [Date]
        if let time {
            switch time.meridiem {
            case .fixed: candidates = [on(today, time.hour, time.minute), on(tomorrow, time.hour, time.minute)]
            case .am, .pm:
                let h = hour(time, pm: time.meridiem == .pm)
                candidates = [on(today, h, time.minute), on(tomorrow, h, time.minute)]
            case .ambiguous:
                if let period {
                    let h = hour(time, pm: period.isPM)
                    candidates = [on(today, h, time.minute), on(tomorrow, h, time.minute)]
                } else {
                    let am = hour(time, pm: false), pm = hour(time, pm: true)
                    candidates = [on(today, am, time.minute), on(today, pm, time.minute), on(tomorrow, am, time.minute)]
                }
            }
        } else {
            candidates = [on(today, period!.defaultHour, 0), on(tomorrow, period!.defaultHour, 0)]
        }
        return candidates.first { $0 > now }
    }

    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Parts

    struct ClockTime {
        enum Meridiem { case am, pm, fixed, ambiguous }
        let hour: Int, minute: Int, meridiem: Meridiem
    }

    enum PartOfDay {
        case morning, afternoon, evening, night
        var isPM: Bool { self != .morning }
        var defaultHour: Int { [.morning: 9, .afternoon: 15, .evening: 18, .night: 20][self]! }
    }

    static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                          "eight": 8, "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
                          "forty-five": 45, "forty five": 45, "fifty": 50]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static let halfHour = Pattern(#"\bin\s+half\s+an?\s+hour\b"#)
    static let relative = Pattern(#"\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|thirty|forty[- ]five|forty|fifty)\s*(minutes?|mins?|hours?|hrs?)\b"#)
    static let withMeridiem = Pattern(#"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#)
    static let atTime = Pattern(#"\bat\s+(\d{1,2})(?::(\d{2}))?(?:\s*o'?clock)?\b"#)
    static let oClock = Pattern(#"\b(\d{1,2})\s*o'?clock\b"#)
    static let noon = Pattern(#"\b(?:noon|midday)\b"#)
    static let midnight = Pattern(#"\bmidnight\b"#)
    static let weekday = Pattern(#"\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#)
    static let monthOrNumericDate = Pattern(#"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b|\b\d{1,2}/\d{1,2}\b"#)

    static func relativeOffset(_ text: String) -> TimeInterval? {
        if halfHour.contains(text) { return 30 * 60 }
        guard let match = relative.firstMatch(in: text) else { return nil }
        let amount = Int(match.group(1)) ?? numbers[match.group(1)] ?? 1
        return TimeInterval(amount * (match.group(2).hasPrefix("h") ? 3600 : 60))
    }

    static func dayOffset(_ text: String, today: Date, calendar: Calendar) -> Int? {
        if text.contains("day after tomorrow") { return 2 }
        if text.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil { return 1 }
        if text.range(of: #"\b(?:today|tonight|this\s+(?:morning|afternoon|evening))\b"#, options: .regularExpression) != nil { return 0 }
        if let match = weekday.firstMatch(in: text), let target = weekdays.firstIndex(of: match.group(1)) {
            let current = calendar.component(.weekday, from: today) - 1
            let ahead = (target - current + 7) % 7
            return ahead == 0 ? 7 : ahead
        }
        return nil
    }

    /// Explicit calendar dates ("October 3", "3/10"), via Apple's date detector.
    static func calendarDate(_ text: String, calendar: Calendar) -> Date? {
        guard monthOrNumericDate.contains(text),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let date = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func partOfDay(_ text: String) -> PartOfDay? {
        if text.range(of: #"\b(?:tonight|night)\b"#, options: .regularExpression) != nil { return .night }
        if text.range(of: #"\bevening\b"#, options: .regularExpression) != nil { return .evening }
        if text.range(of: #"\bafternoon\b"#, options: .regularExpression) != nil { return .afternoon }
        if text.range(of: #"\bmorning\b"#, options: .regularExpression) != nil { return .morning }
        return nil
    }

    static func clockTime(_ text: String) -> ClockTime? {
        if noon.contains(text) { return ClockTime(hour: 12, minute: 0, meridiem: .fixed) }
        if midnight.contains(text) { return ClockTime(hour: 0, minute: 0, meridiem: .fixed) }
        if let match = withMeridiem.firstMatch(in: text) {
            guard let hour = Int(match.group(1)), (1...12).contains(hour) else { return nil }
            let minute = match.result.range(at: 2).location == NSNotFound ? 0 : Int(match.group(2)) ?? 0
            return ClockTime(hour: hour, minute: minute, meridiem: match.group(3).hasPrefix("p") ? .pm : .am)
        }
        guard let match = atTime.firstMatch(in: text) ?? oClock.firstMatch(in: text), let hour = Int(match.group(1)), hour < 24 else { return nil }
        let minute = match.result.numberOfRanges > 2 && match.result.range(at: 2).location != NSNotFound ? Int(match.group(2)) ?? 0 : 0
        guard minute < 60 else { return nil }
        return ClockTime(hour: hour, minute: minute, meridiem: (hour == 0 || hour > 12) ? .fixed : .ambiguous)
    }
}
