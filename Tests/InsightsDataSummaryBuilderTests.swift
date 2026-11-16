// LoopFollow
// InsightsDataSummaryBuilderTests.swift

import Foundation
@testable import LoopFollow
import Testing

struct InsightsDataSummaryBuilderTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func readings(_ values: [Int]) -> [ShareGlucoseData] {
        values.enumerated().map { i, v in
            ShareGlucoseData(sgv: v, date: t0.addingTimeInterval(Double(i) * 300).timeIntervalSince1970, direction: nil)
        }
    }

    private func builder(_ bg: [ShareGlucoseData], carbs: [MainViewController.carbGraphStruct] = []) -> InsightsDataSummaryBuilder {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var b = InsightsDataSummaryBuilder(input: .init(
            bg: bg, boluses: [], smbs: [], carbs: carbs,
            start: t0, end: t0.addingTimeInterval(86400),
            averageDailyDose: nil, averageDailyBolus: nil, averageDailyCarbs: nil,
            averageProgrammedBasal: nil, averageActualBasal: nil
        ))
        b.calendar = calendar
        b.lowThreshold = 70
        b.highThreshold = 180
        return b
    }

    @Test("a low lasting 4 readings (20 min) is one episode with the right nadir")
    func lowEpisode() {
        let bg = readings([100, 90, 68, 60, 55, 65, 80, 100])
        let episodes = builder(bg).findEpisodes(bg: bg, minMinutes: 15, isLow: true) { $0 < 70 }
        #expect(episodes.count == 1)
        #expect(episodes.first?.minutes == 20)
        #expect(episodes.first?.extreme == 55)
    }

    @Test("a single low reading is shorter than the minimum and is ignored")
    func shortLowIgnored() {
        let bg = readings([100, 65, 100, 100])
        #expect(builder(bg).findEpisodes(bg: bg, minMinutes: 15, isLow: true) { $0 < 70 }.isEmpty)
    }

    @Test("a data gap splits an episode")
    func gapSplitsEpisode() {
        var bg = readings([60, 60, 60, 60])
        bg += readings([60, 60, 60, 60]).map {
            ShareGlucoseData(sgv: $0.sgv, date: $0.date + 3600, direction: nil)
        }
        #expect(builder(bg).findEpisodes(bg: bg, minMinutes: 15, isLow: true) { $0 < 70 }.count == 2)
    }

    @Test("summary includes the main sections and no Nightscout URL or token")
    func summarySections() {
        let bg = readings(Array(repeating: 120, count: 30) + [250, 260, 270, 280, 270, 260, 255])
        let summary = builder(bg).build()
        #expect(summary.contains("## OVERALL GLUCOSE"))
        #expect(summary.contains("## HOURLY PROFILE"))
        #expect(summary.contains("## DAILY SUMMARY"))
        #expect(summary.contains("## MEALS"))
        let url = Storage.shared.url.value
        if !url.isEmpty { #expect(!summary.contains(url)) }
    }

    @Test("too little data produces a short notice")
    func notEnoughData() {
        let summary = builder(readings([100, 110])).build()
        #expect(summary.contains("Not enough CGM readings"))
    }
}
