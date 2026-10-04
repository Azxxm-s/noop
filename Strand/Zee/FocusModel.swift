import Foundation
import SwiftUI
import UserNotifications
import WhoopStore

/// One exercise from the most recent lift session, compared with the time before.
struct ExerciseProgress: Identifiable, Equatable {
    let exercise: String
    let lastLine: String            // "80×8 · 80×8 · 75×7"
    let lastBestE1RM: Double?       // kg
    let previousBestE1RM: Double?   // kg
    var id: String { exercise }

    enum Trend { case up, flat, down, new }
    var trend: Trend {
        guard let a = lastBestE1RM else { return .new }
        guard let b = previousBestE1RM else { return .new }
        if a > b * 1.005 { return .up }
        if a < b * 0.985 { return .down }
        return .flat
    }

    /// Epley estimated one-rep max.
    static func e1rm(kg: Double?, reps: Int?) -> Double? {
        guard let kg, let reps, reps > 0, kg > 0 else { return nil }
        return reps == 1 ? kg : kg * (1 + Double(reps) / 30)
    }
}

@MainActor
final class FocusModel: ObservableObject {
    static let shared = FocusModel()

    @Published private(set) var runs: [RunSummary] = []          // newest first
    @Published private(set) var lastLiftSession: LiftSessionRow?
    @Published private(set) var liftSessionsLast7: Int = 0
    @Published private(set) var progress: [ExerciseProgress] = []
    @Published private(set) var loaded = false

    private init() {}

    func load(repo: Repository) async {
        let now = Int(Date().timeIntervalSince1970)

        // Runs
        let rows = await repo.workoutRows(days: 180)
        runs = rows.filter(RunSummary.isRun).map(RunSummary.init).sorted { $0.row.startTs > $1.row.startTs }

        // Lifts
        if let store = await repo.storeHandle() {
            let sessions = (try? await store.liftSessions(deviceId: repo.deviceId,
                                                          fromTs: now - 120 * 86_400, toTs: now + 86_400)) ?? []
            let sorted = sessions.sorted { $0.startTs > $1.startTs }
            lastLiftSession = sorted.first
            liftSessionsLast7 = sorted.filter { $0.startTs >= now - 7 * 86_400 }.count
            var out: [ExerciseProgress] = []
            if let last = sorted.first {
                let sets = ((try? await store.liftSets(sessionId: last.id)) ?? []).filter { !$0.isWarmup }
                var order: [String] = []
                var byExercise: [String: [LiftSetRow]] = [:]
                for s in sets.sorted(by: { $0.ord < $1.ord }) {
                    if byExercise[s.exercise] == nil { order.append(s.exercise) }
                    byExercise[s.exercise, default: []].append(s)
                }
                for ex in order {
                    let mine = (byExercise[ex] ?? []).sorted { $0.setIndex < $1.setIndex }
                    let prev = ((try? await store.lastLiftSets(deviceId: repo.deviceId, exercise: ex,
                                                               before: last.startTs)) ?? []).filter { !$0.isWarmup }
                    var dict: [Int: (kg: Double?, reps: Int?)] = [:]
                    for s in mine { dict[s.setIndex] = (s.weightKg, s.reps) }
                    let line = OverloadAdvisor.lastTimeLine(dict) { LiftFormat.trim($0) } ?? "—"
                    out.append(ExerciseProgress(
                        exercise: ex, lastLine: line,
                        lastBestE1RM: mine.compactMap { ExerciseProgress.e1rm(kg: $0.weightKg, reps: $0.reps) }.max(),
                        previousBestE1RM: prev.compactMap { ExerciseProgress.e1rm(kg: $0.weightKg, reps: $0.reps) }.max()))
                }
            }
            progress = out
        }
        loaded = true
    }

    var daysSinceLift: Int? {
        lastLiftSession.map { Self.daysAgo(ts: $0.startTs) }
    }

    var daysSinceRun: Int? {
        runs.first.map { Self.daysAgo(ts: $0.row.startTs) }
    }

    var runsLast14: Int {
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        return runs.filter { $0.date >= cutoff }.count
    }

    static func daysAgo(ts: Int) -> Int {
        let cal = Calendar.current
        let a = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(ts)))
        let b = cal.startOfDay(for: Date())
        return max(0, cal.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    func edgeInputs(repo: Repository) -> DailyEdgeInputs {
        let todayKey = Repository.logicalDayKey(Date())
        let yKey = FocusDay.key(Calendar.current.date(byAdding: .day, value: -1,
                                                       to: FocusDay.formatter.date(from: todayKey) ?? Date()) ?? Date())
        let today = repo.today
        let yesterday = repo.days.last { $0.day == yKey }
        let history = repo.days.filter { $0.day < todayKey }
        let goal = BodyGoal(rawValue: UserDefaults.standard.string(forKey: FocusPrefs.goalKey) ?? "") ?? .cut
        return DailyEdgeInputs(today: today, yesterday: yesterday, history: history,
                               daysSinceLift: daysSinceLift, daysSinceRun: daysSinceRun,
                               runsLast14Days: runsLast14, weightTrendKg: WeightLog.shared.weeklyTrendKg,
                               goal: goal, loggedWeightToday: WeightLog.shared.today != nil)
    }
}

// MARK: - Morning "how to be better today" notification

@MainActor
enum DailyEdgeNotifier {
    private static let idPrefix = "custom-daily-edge-"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: FocusPrefs.morningTipEnabledKey) == nil
            ? true : UserDefaults.standard.bool(forKey: FocusPrefs.morningTipEnabledKey)
    }

    static var minutes: Int {
        let v = UserDefaults.standard.object(forKey: FocusPrefs.morningTipMinutesKey) as? Int
        return v ?? FocusPrefs.defaultMorningTipMinutes
    }

    static func requestPermission() async -> Bool {
        let c = UNUserNotificationCenter.current()
        let settings = await c.notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { return true }
        return (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func cancel() {
        let ids = (0..<4).map { "\(idPrefix)\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Re-plans the next three mornings. The first carries today's computed advice (based on the most
    /// recent synced data); the next two are gentle nudges in case the app isn't opened in between —
    /// each app open re-plans them with fresh numbers.
    static func reschedule(repo: Repository) async {
        #if os(macOS)
        return   // the morning tip comes from the iPhone; don't double-notify from the Mac
        #else
        cancel()
        guard enabled else { return }
        guard await requestPermission() else { return }

        let inputs = FocusModel.shared.edgeInputs(repo: repo)
        let tips = DailyEdge.tips(inputs)

        let cal = Calendar.current
        let now = Date()
        var first = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: now) ?? now
        if first <= now { first = cal.date(byAdding: .day, value: 1, to: first) ?? first }

        for i in 0..<3 {
            guard let fire = cal.date(byAdding: .day, value: i, to: first) else { continue }
            let content = UNMutableNotificationContent()
            if i == 0 {
                content.title = tips.first?.title ?? "Today's edge"
                var body = tips.first?.detail ?? "Log your weight and follow your plan."
                if tips.count > 1 { body += "\n\nAlso: \(tips[1].title.lowercased())." }
                content.body = body
            } else {
                content.title = "Good morning — weigh in & check your edge"
                content.body = "Open NOOP to sync last night and get today's plan: recovery, training and run advice."
            }
            content.sound = .default
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(identifier: "\(idPrefix)\(i)", content: content, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(req)
        }
        #endif
    }
}
