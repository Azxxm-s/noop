import Foundation
import SwiftUI
import WhoopStore

// MARK: - Personal "Focus" build: data + pure rules
//
// Everything here is on-device only (UserDefaults), like the rest of NOOP. Nothing leaves the phone.
//
//   • WeightLog       — one body-weight entry per day, plus the "asked today?" gate for the daily prompt
//   • FocusPrefs      — Focus-mode switches (focus tab on/off, morning tip time, run frequency)
//   • DailyEdge       — rule-based "how to be better today" from yesterday's / today's numbers
//   • RunCoach        — beginner-friendly feedback on a run + a prescription for the next one
//   • OverloadAdvisor — "last time you did X — here's how to beat it"

// MARK: - Weight log

struct WeightEntry: Codable, Identifiable, Equatable {
    var day: String      // yyyy-MM-dd (local calendar day)
    var kg: Double
    var loggedAt: Double // unix seconds
    var id: String { day }

    var date: Date { FocusDay.formatter.date(from: day) ?? Date(timeIntervalSince1970: loggedAt) }
}

/// Nonisolated day-key helpers (yyyy-MM-dd, local calendar).
enum FocusDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func key(_ date: Date = Date()) -> String { formatter.string(from: date) }
}

@MainActor
final class WeightLog: ObservableObject {
    static let shared = WeightLog()

    private static let entriesKey = "custom.weightLog.entries"
    private static let promptDayKey = "custom.weightLog.lastPromptDay"

    nonisolated static func dayKey(_ date: Date = Date()) -> String { FocusDay.key(date) }

    /// Oldest → newest.
    @Published private(set) var entries: [WeightEntry] = []

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.entriesKey),
              let decoded = try? JSONDecoder().decode([WeightEntry].self, from: data) else { return }
        entries = decoded.sorted { $0.day < $1.day }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.entriesKey)
        }
    }

    func log(kg: Double, on day: String = WeightLog.dayKey()) {
        guard kg.isFinite, kg > 20, kg < 400 else { return }
        entries.removeAll { $0.day == day }
        entries.append(WeightEntry(day: day, kg: kg, loggedAt: Date().timeIntervalSince1970))
        entries.sort { $0.day < $1.day }
        persist()
        markPrompted()
    }

    func delete(day: String) {
        entries.removeAll { $0.day == day }
        persist()
    }

    var today: WeightEntry? { entries.last { $0.day == Self.dayKey() } }
    var latest: WeightEntry? { entries.last }

    /// Prompt once per calendar day, the first time the app is opened, until answered or skipped.
    var shouldPromptToday: Bool {
        today == nil && UserDefaults.standard.string(forKey: Self.promptDayKey) != Self.dayKey()
    }

    func markPrompted() {
        UserDefaults.standard.set(Self.dayKey(), forKey: Self.promptDayKey)
    }

    /// Entries within the last 'days' days.
    func recent(days: Int) -> [WeightEntry] {
        let cutoff = Self.dayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return entries.filter { $0.day >= cutoff }
    }

    /// Mean of the entries inside a window of days ending 'endOffset' days ago.
    func average(lastDays days: Int, endingDaysAgo endOffset: Int = 0) -> Double? {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: -endOffset, to: Date()) ?? Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let lo = Self.dayKey(start), hi = Self.dayKey(end)
        let vals = entries.filter { $0.day >= lo && $0.day <= hi }.map(\.kg)
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// 7-day average this week minus the 7-day average the week before (kg). Smooths out water swings.
    var weeklyTrendKg: Double? {
        guard let now = average(lastDays: 7), let before = average(lastDays: 7, endingDaysAgo: 7) else { return nil }
        return now - before
    }

    /// Trailing 7-entry moving average for every entry (for the chart's smooth line).
    var movingAverage: [(date: Date, kg: Double)] {
        var out: [(Date, Double)] = []
        for (i, e) in entries.enumerated() {
            let window = entries[max(0, i - 6)...i].map(\.kg)
            out.append((e.date, window.reduce(0, +) / Double(window.count)))
        }
        return out.map { (date: $0.0, kg: $0.1) }
    }
}

// MARK: - Prefs

enum FocusPrefs {
    static let focusModeKey = "custom.focusMode.enabled"          // Focus tab replaces Today as tab 1
    static let morningTipEnabledKey = "custom.dailyEdge.enabled"
    static let morningTipMinutesKey = "custom.dailyEdge.minutes"  // minutes after local midnight
    static let defaultMorningTipMinutes = 7 * 60 + 15
    static let goalKey = "custom.goal"                           // "cut" | "maintain" | "bulk"
}

enum BodyGoal: String, CaseIterable, Identifiable {
    case cut, maintain, bulk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "Lose fat"
        case .maintain: return "Recomp / maintain"
        case .bulk: return "Build muscle"
        }
    }
}

// MARK: - Daily edge (rule-based, offline)

struct EdgeTip: Identifiable, Equatable {
    enum Kind { case recover, push, sleep, train, run, weight, info }
    let kind: Kind
    let title: String
    let detail: String
    var id: String { title }

    var symbol: String {
        switch kind {
        case .recover: return "leaf.fill"
        case .push: return "flame.fill"
        case .sleep: return "moon.zzz.fill"
        case .train: return "dumbbell.fill"
        case .run: return "figure.run"
        case .weight: return "scalemass.fill"
        case .info: return "sparkles"
        }
    }
}

struct DailyEdgeInputs {
    var today: DailyMetric?
    var yesterday: DailyMetric?
    /// Older days for baselines (oldest → newest), excluding today.
    var history: [DailyMetric]
    var daysSinceLift: Int?
    var daysSinceRun: Int?
    var runsLast14Days: Int
    var weightTrendKg: Double?
    var goal: BodyGoal
    var loggedWeightToday: Bool
}

enum DailyEdge {

    private static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// The single most important line — used as the notification body and the Focus headline.
    static func headline(_ i: DailyEdgeInputs) -> String {
        tips(i).first.map { "\($0.title). \($0.detail)" } ?? "Log your weight, train with intent, sleep 7.5h+. Small wins compound."
    }

    static func tips(_ i: DailyEdgeInputs) -> [EdgeTip] {
        var out: [EdgeTip] = []
        let base = Array(i.history.suffix(28))
        let hrvBase = mean(base.compactMap(\.avgHrv))
        let rhrBase = mean(base.compactMap { $0.restingHr.map(Double.init) })
        let sleepBase = mean(base.compactMap(\.totalSleepMin))

        let rec = i.today?.recovery
        let sleepMin = i.today?.totalSleepMin
        let yStrain = i.yesterday?.strain
        let hrv = i.today?.avgHrv
        let rhr = i.today?.restingHr.map(Double.init)

        // 1. Readiness — decides how hard today should be.
        if let rec {
            if rec < 34 {
                out.append(EdgeTip(kind: .recover, title: "Recovery is low (\(Int(rec))%)",
                    detail: "Make today a technique or mobility day: same exercises, ~60% of your usual weight, stop 3+ reps short of failure. If you run, keep it a walk or very easy jog."))
            } else if rec < 67 {
                out.append(EdgeTip(kind: .train, title: "Recovery is moderate (\(Int(rec))%)",
                    detail: "Train normally but don't chase PRs. Hit your planned sets and aim to match last session — beat it only if the first set moves fast."))
            } else {
                out.append(EdgeTip(kind: .push, title: "Green light (\(Int(rec))%)",
                    detail: "Good day to push progressive overload: add a rep or the smallest weight jump on your main lift."))
            }
        }

        // 2. HRV / resting HR vs your own baseline — early warning for under-recovery or illness.
        if let hrv, let hrvBase, hrvBase > 0, hrv < hrvBase * 0.85 {
            out.append(EdgeTip(kind: .recover, title: "HRV is \(Int(((1 - hrv / hrvBase) * 100).rounded()))% below your normal",
                detail: "Your nervous system is still loaded. Extra water, lighter volume, and an earlier night today."))
        } else if let rhr, let rhrBase, rhr >= rhrBase + 5 {
            out.append(EdgeTip(kind: .recover, title: "Resting HR is up \(Int(rhr - rhrBase)) bpm",
                detail: "Often a sign of poor sleep, late food/alcohol, stress or getting sick. Keep intensity down until it settles."))
        }

        // 3. Sleep.
        if let sleepMin {
            let h = sleepMin / 60
            if h < 6.5 {
                out.append(EdgeTip(kind: .sleep, title: String(format: "Only %.1fh sleep", h),
                    detail: "Muscle is built while you sleep. Aim for lights-out 30–45 min earlier tonight, no caffeine after 2pm, and a 20-min nap if you can."))
            } else if let sleepBase, sleepMin < sleepBase - 45 {
                out.append(EdgeTip(kind: .sleep, title: "Sleep was shorter than usual",
                    detail: "You're ~\(Int((sleepBase - sleepMin).rounded())) min under your average. Protect your bedtime tonight."))
            }
        }

        // 4. Yesterday's load.
        if let yStrain, yStrain >= 70, (rec ?? 50) < 67 {
            out.append(EdgeTip(kind: .recover, title: "Big day yesterday",
                detail: "Yesterday's effort was high. Eat enough protein (~2 g per kg bodyweight) and carbs today to refill."))
        } else if let yStrain, yStrain < 25, (rec ?? 0) >= 50 {
            out.append(EdgeTip(kind: .push, title: "Yesterday was light",
                detail: "You're fresh — today is a good day for a hard session or your weekly run."))
        }

        // 5. Training rhythm.
        if let d = i.daysSinceLift, d >= 3 {
            out.append(EdgeTip(kind: .train, title: "\(d) days since your last lift",
                detail: "Get a session in today, even a 40-minute full-body one. Consistency beats perfection while you rebuild."))
        } else if i.daysSinceLift == nil {
            out.append(EdgeTip(kind: .train, title: "Log your first lift",
                detail: "Set up your program in Lift Log once — after that every session shows what you lifted last time so you can beat it."))
        }

        if let d = i.daysSinceRun, d >= 10 {
            out.append(EdgeTip(kind: .run, title: "Time for your run",
                detail: "It's been \(d) days. Keep it easy and conversational — 20–30 min with walk breaks is perfect. Avoid the day before leg day."))
        } else if i.daysSinceRun == nil {
            out.append(EdgeTip(kind: .run, title: "Start running easy",
                detail: "First run: 10 × (1 min jog + 1 min walk). Slow enough to talk. Start it from Workouts → Running so it's tracked."))
        }

        // 6. Weight vs goal.
        if !i.loggedWeightToday {
            out.append(EdgeTip(kind: .weight, title: "Weigh in",
                detail: "Same time every morning, after the bathroom, before food. Trust the weekly average, not the daily number."))
        } else if let t = i.weightTrendKg {
            switch i.goal {
            case .cut where t > 0.1:
                out.append(EdgeTip(kind: .weight, title: "Weight trending up",
                    detail: String(format: "+%.1f kg week over week. Trim ~200–300 kcal/day (usually from fats/snacks) and keep protein high.", t)))
            case .cut where t < -1.0:
                out.append(EdgeTip(kind: .weight, title: "Dropping fast",
                    detail: String(format: "%.1f kg in a week risks losing muscle. Add ~150–200 kcal back, mostly carbs around training.", t)))
            case .bulk where t < 0.05:
                out.append(EdgeTip(kind: .weight, title: "Not gaining",
                    detail: "Add ~200 kcal/day. A lean bulk is roughly +0.25–0.5% bodyweight per week."))
            case .bulk where t > 0.6:
                out.append(EdgeTip(kind: .weight, title: "Gaining quickly",
                    detail: String(format: "+%.1f kg in a week is mostly not muscle. Pull back ~150 kcal/day.", t)))
            default:
                break
            }
        }

        if out.isEmpty {
            out.append(EdgeTip(kind: .info, title: "Keep stacking good days",
                detail: "Log your weight, follow your plan, and get 7.5h+ of sleep."))
        }
        return out
    }
}

// MARK: - Run coach

struct RunSummary: Identifiable, Equatable {
    let row: WorkoutRow
    var id: String { "\(row.startTs)|\(row.sport)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(row.startTs)) }
    var minutes: Double { (row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60 }
    var km: Double? { row.distanceM.flatMap { $0 > 50 ? $0 / 1000 : nil } }
    /// Minutes per km.
    var pace: Double? { km.flatMap { $0 > 0 ? minutes / $0 : nil } }

    static func isRun(_ row: WorkoutRow) -> Bool {
        let s = row.sport.lowercased()
        return s.contains("run") || s.contains("jog")
    }
}

struct RunFeedback {
    var verdict: String
    var points: [String]
    var nextRun: String
    var effortLabel: String
    var effortColor: Color
}

enum RunCoach {

    static func paceText(_ minPerKm: Double, imperial: Bool) -> String {
        let p = imperial ? minPerKm * 1.609344 : minPerKm
        let total = Int((p * 60).rounded())
        return String(format: "%d:%02d /%@", total / 60, total % 60, imperial ? "mi" : "km")
    }

    /// Easy-run ("zone 2") heart-rate band for a given max HR: ~60–72% HRmax.
    static func easyBand(hrMax: Int) -> ClosedRange<Int> {
        let lo = Int((Double(hrMax) * 0.60).rounded())
        let hi = Int((Double(hrMax) * 0.72).rounded())
        return lo...max(lo, hi)
    }

    static func feedback(for run: RunSummary, previous: RunSummary?, allRuns: [RunSummary],
                         hrMax: Int, recoveryToday: Double?, imperial: Bool) -> RunFeedback {
        var points: [String] = []
        let band = easyBand(hrMax: hrMax)
        var verdict = "Run logged"
        var effortLabel = "—"
        var effortColor: Color = FT.text3
        var wasHard = false

        if let hr = run.row.avgHr, hrMax > 0 {
            let pct = Double(hr) / Double(hrMax)
            if pct >= 0.85 {
                verdict = "That was a hard effort"
                effortLabel = "Hard · \(Int(pct * 100))% max HR"
                effortColor = FT.red
                wasHard = true
                points.append("Average HR \(hr) bpm is well above easy pace. As a beginner, ~80% of your running should feel conversational — around \(band.lowerBound)–\(band.upperBound) bpm for you.")
                points.append("Slow down until you could speak full sentences. If you can't stay in that range while jogging, use walk breaks: that's how aerobic base is built, not a failure.")
            } else if pct >= 0.75 {
                verdict = "Solid, moderately hard run"
                effortLabel = "Moderate · \(Int(pct * 100))% max HR"
                effortColor = FT.yellow
                wasHard = true
                points.append("Average HR \(hr) bpm — a bit above easy. Fine occasionally, but most runs should sit at \(band.lowerBound)–\(band.upperBound) bpm so you recover quickly and can still lift hard.")
            } else {
                verdict = "Great easy run"
                effortLabel = "Easy · \(Int(pct * 100))% max HR"
                effortColor = FT.green
                points.append("Average HR \(hr) bpm is right in the easy zone. This is exactly the effort that builds your engine without hurting your lifting.")
            }
            if let mx = run.row.maxHr, Double(mx) >= Double(hrMax) * 0.95 {
                points.append("You touched \(mx) bpm (near max). If that was a sprint finish, great — otherwise ease off hills and the last few minutes.")
            }
        } else {
            points.append("No heart rate for this run — wear the strap so the coach can judge effort.")
        }

        if run.minutes < 15 {
            points.append("Short session (\(Int(run.minutes)) min). Build toward 20–30 minutes of continuous easy movement first; speed comes later.")
        }

        if let prev = previous {
            if let p1 = run.pace, let p0 = prev.pace, let h1 = run.row.avgHr, let h0 = prev.row.avgHr {
                let paceDelta = (p0 - p1) * 60 // seconds faster per km
                if paceDelta > 5 && h1 <= h0 + 2 {
                    points.append("Faster than last run (\(Int(paceDelta)) s/km) at the same or lower heart rate — your fitness is improving. 👏")
                } else if paceDelta < -5 && h1 < h0 - 3 {
                    points.append("Slower but at a lower HR than last time — that's the right direction for base building.")
                } else if h1 > h0 + 5 && abs(paceDelta) < 5 {
                    points.append("Same pace as last time but HR is \(h1 - h0) bpm higher — likely fatigue, heat, or poor sleep. Not a fitness loss.")
                }
            }
            if let k1 = run.km, let k0 = prev.km, k0 > 0, k1 > k0 * 1.15 {
                points.append(String(format: "Distance jumped %.0f%% vs last run. Keep weekly increases around 10%% to protect shins, calves and knees.", (k1 / k0 - 1) * 100))
            }
        } else {
            points.append("First run tracked — this is your baseline. Every next run gets compared to it.")
        }

        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        let recent = allRuns.filter { $0.date >= cutoff }.count
        if recent <= 1 {
            points.append("You're running about once every 1–2 weeks. That's a fine start; a second short 20-min easy run each week will make the long ones feel much easier.")
        }
        points.append("Lifter tip: keep runs at least 24–48 h away from heavy leg day, and do them after upper-body sessions or on rest days.")

        // Next run prescription.
        let nextMinutes: Int
        let next: String
        if wasHard {
            nextMinutes = max(15, Int(run.minutes.rounded()))
            next = "Next run: \(nextMinutes) min at \(band.lowerBound)–\(band.upperBound) bpm. Walk whenever your HR goes above \(band.upperBound). Same time, lower effort."
        } else if run.minutes < 20 {
            nextMinutes = Int(run.minutes.rounded()) + 3
            next = "Next run: \(nextMinutes) min easy. Try jogging 3 min / walking 1 min if continuous jogging is too much."
        } else if run.minutes < 45 {
            nextMinutes = min(Int((run.minutes * 1.1).rounded()), Int(run.minutes.rounded()) + 5)
            next = "Next run: \(nextMinutes) min easy (about +10%). Keep HR \(band.lowerBound)–\(band.upperBound) bpm."
        } else {
            nextMinutes = Int(run.minutes.rounded())
            next = "Next run: keep \(nextMinutes) min easy, and add 4–6 × 20-second relaxed strides at the end to sharpen form."
        }

        var finalNext = next
        if let r = recoveryToday, r < 34 {
            finalNext += " (Recovery is low today — wait a day or make it a brisk walk.)"
        }
        _ = imperial
        return RunFeedback(verdict: verdict, points: points, nextRun: finalNext,
                           effortLabel: effortLabel, effortColor: effortColor)
    }

    /// The beginner ladder, picked from the longest recent run.
    static func ladder(longestMinutes: Double) -> (stage: Int, title: String, steps: [String]) {
        let steps = [
            "Run/walk: 10 × (1 min jog, 1 min walk)",
            "Run/walk: 6 × (3 min jog, 1 min walk)",
            "Run/walk: 3 × (8 min jog, 1 min walk)",
            "20 min continuous easy jog",
            "30 min continuous easy jog",
            "5K easy, then add 1 weekly session of strides",
        ]
        let stage: Int
        switch longestMinutes {
        case ..<18: stage = 0
        case ..<23: stage = 1
        case ..<26: stage = 2
        case ..<28: stage = 3
        case ..<33: stage = 4
        default: stage = 5
        }
        return (stage, steps[stage], steps)
    }
}

// MARK: - Progressive overload

enum OverloadAdvisor {

    /// "80×8 · 80×8 · 75×7"
    static func lastTimeLine(_ sets: [Int: (kg: Double?, reps: Int?)], format: (Double) -> String) -> String? {
        let ordered = sets.keys.sorted().compactMap { k -> String? in
            guard let s = sets[k] else { return nil }
            switch (s.kg, s.reps) {
            case let (kg?, reps?): return "\(format(kg))×\(reps)"
            case let (nil, reps?): return "BW×\(reps)"
            case let (kg?, nil): return format(kg)
            default: return nil
            }
        }
        return ordered.isEmpty ? nil : ordered.joined(separator: " · ")
    }

    /// One short instruction to beat last time.
    static func suggestion(_ sets: [Int: (kg: Double?, reps: Int?)], repsHigh: Int?,
                           incrementKg: Double, format: (Double) -> String) -> String? {
        let working = sets.values.filter { $0.reps != nil }
        guard !working.isEmpty else { return nil }
        let reps = working.compactMap(\.reps)
        let topKg = working.compactMap(\.kg).max()
        let topRange = repsHigh ?? 12
        if let topKg, reps.allSatisfy({ $0 >= topRange }) {
            return "All sets hit \(topRange)+ reps → go up to \(format(topKg + incrementKg)) and aim for \(max(1, topRange - 4))+ reps"
        }
        if let topKg {
            return "Beat it: \(format(topKg)) for +1 rep on at least one set"
        }
        return "Beat it: +1 rep on at least one set"
    }
}
