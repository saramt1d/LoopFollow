// LoopFollow
// InsightsDataSummaryBuilder.swift

import Foundation
import HealthKit

/// Turns the Nightscout data already loaded for the Statistics screen into a
/// compact, plain-text summary that Claude can analyse. All glucose values are
/// sent in mg/dL; Claude is told which unit to answer in.
///
/// Nothing that identifies the user (Nightscout URL, token, names) is included.
struct InsightsDataSummaryBuilder {
    struct Input {
        var bg: [ShareGlucoseData]
        var boluses: [MainViewController.bolusGraphStruct]
        var smbs: [MainViewController.bolusGraphStruct]
        var carbs: [MainViewController.carbGraphStruct]
        var start: Date
        var end: Date
        var averageDailyDose: Double?
        var averageDailyBolus: Double?
        var averageDailyCarbs: Double?
        var averageProgrammedBasal: Double?
        var averageActualBasal: Double?
    }

    static let maxListedEvents = 60

    let input: Input
    var calendar: Calendar = dateTimeUtils.displayCalendar()
    var lowThreshold: Double = UnitSettingsStore.shared.effectiveThresholds().low
    var highThreshold: Double = UnitSettingsStore.shared.effectiveThresholds().high

    private var sortedBG: [ShareGlucoseData] {
        input.bg.filter { $0.sgv > 0 }.sorted { $0.date < $1.date }
    }

    // MARK: - Public

    func build() -> String {
        let bg = sortedBG
        var out: [String] = []

        out.append(section("PERIOD"))
        let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: input.start), to: calendar.startOfDay(for: input.end)).day.map { $0 + 1 } ?? 1)
        out.append("\(dateTime(input.start)) to \(dateTime(input.end)) (\(days) days), time zone \(calendar.timeZone.identifier)")
        out.append("Target range used by the app: \(fmt(lowThreshold))-\(fmt(highThreshold)) mg/dL. Very low <\(fmt(GlucoseThresholds.veryLow)), very high >\(fmt(GlucoseThresholds.veryHigh)).")
        let device = Storage.shared.device.value
        if !device.isEmpty {
            out.append("Dosing system reported by Nightscout: \(device)")
        }

        guard bg.count >= 12 else {
            out.append("Not enough CGM readings in this period (\(bg.count)).")
            return out.joined(separator: "\n")
        }

        out.append(contentsOf: overall(bg: bg, days: days))
        out.append(contentsOf: hourlyProfile(bg: bg))
        out.append(contentsOf: daily(bg: bg))
        out.append(contentsOf: episodes(bg: bg))
        out.append(contentsOf: meals(bg: bg))
        out.append(contentsOf: therapySettings())

        return out.joined(separator: "\n")
    }

    // MARK: - Sections

    private func overall(bg: [ShareGlucoseData], days: Int) -> [String] {
        let values = bg.map { Double($0.sgv) }
        let mean = values.reduce(0, +) / Double(values.count)
        let sd = sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
        let gmi = 3.31 + 0.02392 * mean
        let expected = Double(days) * 288
        let coverage = min(100, Double(values.count) / expected * 100)

        var lines = [section("OVERALL GLUCOSE")]
        lines.append("Readings: \(values.count) (~\(fmt(coverage))% CGM coverage)")
        lines.append("Mean \(fmt(mean)) mg/dL, SD \(fmt(sd)), CV \(fmt(sd / mean * 100, 1))%, GMI \(fmt(gmi, 1))%")
        lines.append(bandLine(values))

        var insulin: [String] = []
        if let v = input.averageDailyDose { insulin.append("TDD \(fmt(v, 1)) U/day") }
        if let v = input.averageDailyBolus { insulin.append("bolus \(fmt(v, 1)) U/day") }
        if let v = input.averageProgrammedBasal { insulin.append("scheduled basal \(fmt(v, 1)) U/day") }
        if let v = input.averageActualBasal { insulin.append("delivered basal \(fmt(v, 1)) U/day") }
        if let v = input.averageDailyCarbs { insulin.append("carbs \(fmt(v)) g/day") }
        if !insulin.isEmpty {
            lines.append("Averages: " + insulin.joined(separator: ", "))
        }
        return lines
    }

    private func hourlyProfile(bg: [ShareGlucoseData]) -> [String] {
        var byHour = [[Double]](repeating: [], count: 24)
        for r in bg {
            let hour = calendar.component(.hour, from: Date(timeIntervalSince1970: r.date))
            byHour[hour].append(Double(r.sgv))
        }
        var lines = [section("HOURLY PROFILE (local time, all days combined)")]
        lines.append("hour | n | p10 | median | p90 | %<\(fmt(lowThreshold)) | %>\(fmt(highThreshold))")
        for hour in 0 ..< 24 {
            let v = byHour[hour].sorted()
            guard !v.isEmpty else {
                lines.append(String(format: "%02d | 0", hour))
                continue
            }
            lines.append(String(format: "%02d", hour) + " | \(v.count) | \(fmt(percentile(v, 0.1))) | \(fmt(percentile(v, 0.5))) | \(fmt(percentile(v, 0.9))) | \(fmt(pct(v) { $0 < lowThreshold })) | \(fmt(pct(v) { $0 > highThreshold }))")
        }
        return lines
    }

    private func daily(bg: [ShareGlucoseData]) -> [String] {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "EEE yyyy-MM-dd"

        let bgByDay = Dictionary(grouping: bg) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.date)) }
        let carbsByDay = Dictionary(grouping: input.carbs) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.date)) }
        let bolusByDay = Dictionary(grouping: input.boluses) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.date)) }
        let smbByDay = Dictionary(grouping: input.smbs) { calendar.startOfDay(for: Date(timeIntervalSince1970: $0.date)) }

        var lines = [section("DAILY SUMMARY")]
        lines.append("day | n | mean | %in range | %low | %high | carbs g | bolus U | SMB U")
        for day in bgByDay.keys.sorted() {
            let v = bgByDay[day, default: []].map { Double($0.sgv) }
            let mean = v.reduce(0, +) / Double(v.count)
            let carbs = carbsByDay[day, default: []].reduce(0) { $0 + $1.value }
            let bolus = bolusByDay[day, default: []].reduce(0) { $0 + $1.value }
            let smb = smbByDay[day, default: []].reduce(0) { $0 + $1.value }
            lines.append("\(dayFormatter.string(from: day)) | \(v.count) | \(fmt(mean)) | \(fmt(pct(v) { $0 >= lowThreshold && $0 <= highThreshold })) | \(fmt(pct(v) { $0 < lowThreshold })) | \(fmt(pct(v) { $0 > highThreshold })) | \(fmt(carbs)) | \(fmt(bolus, 1)) | \(fmt(smb, 1))")
        }
        return lines
    }

    private func episodes(bg: [ShareGlucoseData]) -> [String] {
        let lows = findEpisodes(bg: bg, minMinutes: 15, isLow: true) { $0 < lowThreshold }
        let highs = findEpisodes(bg: bg, minMinutes: 30, isLow: false) { $0 > GlucoseThresholds.veryHigh }

        var lines = [section("LOW EPISODES (<\(fmt(lowThreshold)) mg/dL for at least 15 min)")]
        lines.append("Total: \(lows.count)" + (lows.count > Self.maxListedEvents ? ", most recent \(Self.maxListedEvents) listed" : ""))
        lines.append("start | duration min | nadir | carbs g in prior 3h | bolus U in prior 3h")
        for e in lows.suffix(Self.maxListedEvents) {
            let startTime = e.start.timeIntervalSince1970
            let window = (startTime - 3 * 3600) ... startTime
            let carbs = input.carbs.filter { window.contains($0.date) }.reduce(0) { $0 + $1.value }
            let bolus = (input.boluses + input.smbs).filter { window.contains($0.date) }.reduce(0) { $0 + $1.value }
            lines.append("\(dateTime(e.start)) | \(Int(e.minutes)) | \(fmt(e.extreme)) | \(fmt(carbs)) | \(fmt(bolus, 1))")
        }

        lines.append(section("HIGH EPISODES (>\(fmt(GlucoseThresholds.veryHigh)) mg/dL for at least 30 min)"))
        lines.append("Total: \(highs.count)" + (highs.count > Self.maxListedEvents ? ", most recent \(Self.maxListedEvents) listed" : ""))
        lines.append("start | duration min | peak")
        for e in highs.suffix(Self.maxListedEvents) {
            lines.append("\(dateTime(e.start)) | \(Int(e.minutes)) | \(fmt(e.extreme))")
        }
        return lines
    }

    private func meals(bg: [ShareGlucoseData]) -> [String] {
        let meals = input.carbs.filter { $0.value >= 5 }.sorted { $0.date < $1.date }
        var lines = [section("MEALS (carb entries >= 5 g)")]
        lines.append("Total: \(meals.count)" + (meals.count > Self.maxListedEvents ? ", most recent \(Self.maxListedEvents) listed" : ""))
        lines.append("time | carbs g | bolus U within ±30 min (minutes from carb entry of first bolus) | BG at entry | peak BG in next 3h (min after) | BG at +3h")
        for meal in meals.suffix(Self.maxListedEvents) {
            let nearBoluses = input.boluses.filter { abs($0.date - meal.date) <= 30 * 60 }.sorted { $0.date < $1.date }
            let bolusTotal = nearBoluses.reduce(0) { $0 + $1.value }
            let bolusText: String
            if let first = nearBoluses.first {
                bolusText = "\(fmt(bolusTotal, 1)) (\(Int((first.date - meal.date) / 60)))"
            } else {
                bolusText = "0"
            }
            let after = bg.filter { $0.date >= meal.date && $0.date <= meal.date + 3 * 3600 }
            let peak = after.max { $0.sgv < $1.sgv }
            let peakText = peak.map { "\($0.sgv) (\(Int(($0.date - meal.date) / 60)))" } ?? "-"
            lines.append("\(dateTime(Date(timeIntervalSince1970: meal.date))) | \(fmt(meal.value)) | \(bolusText) | \(bgText(near: meal.date, in: bg)) | \(peakText) | \(bgText(near: meal.date + 3 * 3600, in: bg))")
        }
        return lines
    }

    private func therapySettings() -> [String] {
        let profile = ProfileManager.shared
        var lines = [section("THERAPY SETTINGS (current Nightscout profile)")]
        guard !profile.basalSchedule.isEmpty || !profile.isfSchedule.isEmpty || !profile.carbRatioSchedule.isEmpty else {
            lines.append("No profile loaded.")
            return lines
        }
        if !profile.basalSchedule.isEmpty {
            lines.append("Basal U/h: " + profile.basalSchedule.map { "\(clock($0.timeAsSeconds)) \(fmt($0.value, 3))" }.joined(separator: ", "))
        }
        if !profile.isfSchedule.isEmpty {
            lines.append("ISF mg/dL per U: " + profile.isfSchedule.map { "\(clock($0.timeAsSeconds)) \(fmt($0.value.doubleValue(for: .milligramsPerDeciliter)))" }.joined(separator: ", "))
        }
        if !profile.carbRatioSchedule.isEmpty {
            lines.append("Carb ratio g per U: " + profile.carbRatioSchedule.map { "\(clock($0.timeAsSeconds)) \(fmt($0.value, 1))" }.joined(separator: ", "))
        }
        if !profile.targetLowSchedule.isEmpty {
            let targets = zip(profile.targetLowSchedule, profile.targetHighSchedule).map {
                "\(clock($0.timeAsSeconds)) \(fmt($0.value.doubleValue(for: .milligramsPerDeciliter)))-\(fmt($1.value.doubleValue(for: .milligramsPerDeciliter)))"
            }
            lines.append("Correction target mg/dL: " + targets.joined(separator: ", "))
        }
        return lines
    }

    // MARK: - Helpers

    struct Episode {
        let start: Date
        let minutes: Double
        let extreme: Double
    }

    func findEpisodes(bg: [ShareGlucoseData], minMinutes: Double, isLow: Bool, matches: (Double) -> Bool) -> [Episode] {
        var result: [Episode] = []
        var startTime: TimeInterval?
        var lastTime: TimeInterval = 0
        var extreme = 0.0

        func close() {
            if let s = startTime {
                let minutes = (lastTime - s) / 60 + 5
                if minutes >= minMinutes {
                    result.append(Episode(start: Date(timeIntervalSince1970: s), minutes: minutes, extreme: extreme))
                }
            }
            startTime = nil
        }

        for r in bg {
            let v = Double(r.sgv)
            if startTime != nil, r.date - lastTime > 15 * 60 { close() }
            if matches(v) {
                if startTime == nil {
                    startTime = r.date
                    extreme = v
                } else {
                    extreme = isLow ? min(extreme, v) : max(extreme, v)
                }
                lastTime = r.date
            } else {
                close()
            }
        }
        close()
        return result
    }

    private func bandLine(_ values: [Double]) -> String {
        let veryLow = pct(values) { $0 < GlucoseThresholds.veryLow }
        let low = pct(values) { $0 >= GlucoseThresholds.veryLow && $0 < lowThreshold }
        let inRange = pct(values) { $0 >= lowThreshold && $0 <= highThreshold }
        let high = pct(values) { $0 > highThreshold && $0 <= GlucoseThresholds.veryHigh }
        let veryHigh = pct(values) { $0 > GlucoseThresholds.veryHigh }
        return "Time in bands: very low \(fmt(veryLow, 1))%, low \(fmt(low, 1))%, in range \(fmt(inRange, 1))%, high \(fmt(high, 1))%, very high \(fmt(veryHigh, 1))%"
    }

    private func bgText(near time: TimeInterval, in bg: [ShareGlucoseData]) -> String {
        guard let closest = bg.min(by: { abs($0.date - time) < abs($1.date - time) }),
              abs(closest.date - time) <= 10 * 60
        else { return "-" }
        return "\(closest.sgv)"
    }

    private func pct(_ values: [Double], where predicate: (Double) -> Bool) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter(predicate).count) / Double(values.count) * 100
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    private func section(_ title: String) -> String { "\n## \(title)" }

    private func fmt(_ value: Double, _ digits: Int = 0) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func clock(_ secondsFromMidnight: Int) -> String {
        String(format: "%02d:%02d", secondsFromMidnight / 3600, (secondsFromMidnight % 3600) / 60)
    }

    private func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE MM-dd HH:mm"
        return f.string(from: date)
    }
}
