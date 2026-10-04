import SwiftUI
import UserNotifications
import StrandDesign

/// The Focus tab: only what matters for a lifter getting back in shape and starting to run.
struct FocusView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var model = FocusModel.shared
    @ObservedObject private var weights = WeightLog.shared
    @ObservedObject private var bodyFat = BodyFatLog.shared

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceRaw = ""
    private var imperialDistance: Bool { UnitPrefs.resolveDistance(system: unitSystem, override: distanceRaw) == .imperial }
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    @State private var showWeighIn = false
    @State private var showSettings = false

    var body: some View {
        FTPage {
            header
            dials
            edgeSection
            weightSection
            bodyFatSection
            statsSection
            trainingSection
            runningSection
            NavigationLink {
                Group {
                    if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
            } label: {
                Text("Full dashboard")
            }
            .buttonStyle(FTSecondaryButtonStyle())
        }
        .refreshable {
            await repo.refresh()
            await model.load(repo: repo)
        }
        .task(id: repo.refreshSeq) {
            await model.load(repo: repo)
            await DailyEdgeNotifier.reschedule(repo: repo)
        }
        .sheet(isPresented: $showWeighIn) { WeighInSheet() }
        .sheet(isPresented: $showSettings) { FocusSettingsView() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                FTLabel(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)), color: FT.text3)
                Text("Today")
                    .font(FT.head(32))
                    .foregroundStyle(FT.text)
            }
            Spacer()
            ZeeModeSwitch()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(FT.text)
                    .frame(width: 40, height: 40)
                    .background(FT.card, in: Circle())
                    .overlay(Circle().stroke(FT.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Zee mode settings")
        }
        .padding(.top, 6)
    }

    // MARK: Dials

    private var sleepPct: Double? {
        guard let t = repo.today else { return nil }
        if let p = repo.importedSleep[t.day]?.performancePct { return p }
        guard let mins = t.totalSleepMin else { return nil }
        let need = repo.importedSleep[t.day]?.needMin ?? 480
        return min(100, mins / max(1, need) * 100)
    }

    private var dials: some View {
        let t = repo.today
        let strain21 = t?.strain.map { $0 * 0.21 }
        return HStack(alignment: .top, spacing: 4) {
            FTDial(label: "Sleep",
                   value: sleepPct.map { "\(Int($0.rounded()))%" } ?? "—",
                   progress: sleepPct.map { $0 / 100 }, color: FT.sleep, size: 92,
                   caption: t?.totalSleepMin.map { String(format: "%.1fh", $0 / 60) })
            FTDial(label: "Recovery",
                   value: t?.recovery.map { "\(Int($0.rounded()))%" } ?? "—",
                   progress: t?.recovery.map { $0 / 100 }, color: FT.recovery(t?.recovery), size: 116)
            FTDial(label: "Strain",
                   value: strain21.map { String(format: "%.1f", $0) } ?? "—",
                   progress: strain21.map { $0 / 21 }, color: FT.strain, size: 92)
        }
        .padding(.vertical, 6)
    }

    // MARK: Today's edge

    private var edgeSection: some View {
        let tips = Array(DailyEdge.tips(model.edgeInputs(repo: repo)).prefix(4))
        return FTSection("Today's edge") {
            FTCard {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(tips) { tip in
                        FTInsight(title: tip.title, detail: tip.detail, tint: tip.kind.tint)
                    }
                }
            }
        }
    }

    // MARK: Weight

    private var weightSection: some View {
        FTSection(title: "Body weight", trailing: {
            NavigationLink { WeightHistoryView() } label: { FTLabel("History", color: FT.text) }
        }) {
            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let w = weights.today ?? weights.latest {
                            Text(LiftFormat.trim((LiftFormat.display(fromKilograms: w.kg, system: unitSystem) * 10).rounded() / 10))
                                .font(FT.number(44))
                                .foregroundStyle(FT.text)
                            Text(LiftFormat.weightUnit(unitSystem).uppercased())
                                .font(FT.head(15)).foregroundStyle(FT.text3)
                        } else {
                            Text("—").font(FT.number(44)).foregroundStyle(FT.text3)
                        }
                        Spacer()
                        if let t = weights.weeklyTrendKg { trendBadge(t) }
                    }
                    HStack(spacing: 18) {
                        miniStat("7-day avg", weights.average(lastDays: 7).map { formatWeight($0) } ?? "—")
                        miniStat("Logged", weights.today == nil ? "Not today" : "Today")
                        miniStat("Goal", (BodyGoal(rawValue: UserDefaults.standard.string(forKey: FocusPrefs.goalKey) ?? "") ?? .cut).label)
                    }
                    let recent = weights.recent(days: 30)
                    if recent.count >= 2 {
                        WeightChart(entries: recent, unitSystem: unitSystem).frame(height: 130)
                    }
                    if weights.today == nil {
                        Button { showWeighIn = true } label: { Text("Log today's weight") }
                            .buttonStyle(FTPrimaryButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Body fat

    private var bodyFatSection: some View {
        FTSection("Body composition") {
            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    NavigationLink { BodyFatView() } label: {
                        if let e = bodyFat.latest {
                            let w = (weights.today ?? weights.latest)?.kg ?? e.weightKg
                            FTActivityRow(icon: "percent", tint: FT.green, title: "Body fat",
                                          subtitle: e.method.label + " · " + e.date.formatted(.dateTime.day().month(.abbreviated))
                                            + (w.map { " · lean " + formatWeight($0 * (1 - e.percent / 100)) } ?? ""),
                                          value: String(format: "%.1f%%", e.percent), valueCaption: "Latest")
                        } else {
                            FTActivityRow(icon: "percent", tint: FT.green, title: "Body fat",
                                          subtitle: "Estimate with a tailor's tape or skinfold calipers.")
                        }
                    }
                    .buttonStyle(.plain)
                    if let e = bodyFat.latest, FocusModel.daysAgo(ts: Int(e.ts)) >= 14 {
                        FTInsight(title: "Time to re-measure",
                                  detail: "Last check-in was \(FocusModel.daysAgo(ts: Int(e.ts))) days ago. Same method, same time of day.",
                                  tint: FT.green)
                    }
                }
            }
        }
    }

    private func formatWeight(_ kg: Double) -> String {
        "\(LiftFormat.trim((LiftFormat.display(fromKilograms: kg, system: unitSystem) * 10).rounded() / 10)) \(LiftFormat.weightUnit(unitSystem))"
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FTLabel(label, color: FT.text3)
            Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(FT.text).lineLimit(1)
        }
    }

    private func trendBadge(_ kg: Double) -> some View {
        let d = LiftFormat.display(fromKilograms: abs(kg), system: unitSystem)
        let txt = "\(kg >= 0 ? "▲" : "▼") \(LiftFormat.trim((d * 10).rounded() / 10)) \(LiftFormat.weightUnit(unitSystem)) / WK"
        return Text(txt)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(FT.cardHi, in: Capsule())
            .foregroundStyle(FT.text2)
    }

    // MARK: Key statistics

    private func baseline(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private var statsSection: some View {
        let t = repo.today
        let hist = Array(repo.days.filter { $0.day < (t?.day ?? "9999") }.suffix(30))
        let hrvBase = baseline(hist.compactMap(\.avgHrv))
        let rhrBase = baseline(hist.compactMap { $0.restingHr.map(Double.init) })
        let sleepBase = baseline(hist.compactMap(\.totalSleepMin))
        return FTSection("Key statistics · vs 30-day") {
            FTCard(padding: 12) {
                VStack(spacing: 0) {
                    FTStatRow(icon: "waveform.path.ecg", name: "HRV",
                              value: t?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—", unit: "MS",
                              delta: delta(t?.avgHrv, hrvBase), deltaGood: good(t?.avgHrv, hrvBase, higherIsBetter: true))
                    Divider().overlay(FT.stroke)
                    FTStatRow(icon: "heart.fill", name: "Resting HR",
                              value: t?.restingHr.map { "\($0)" } ?? "—", unit: "BPM",
                              delta: delta(t?.restingHr.map(Double.init), rhrBase),
                              deltaGood: good(t?.restingHr.map(Double.init), rhrBase, higherIsBetter: false))
                    Divider().overlay(FT.stroke)
                    FTStatRow(icon: "moon.fill", name: "Hours of sleep",
                              value: t?.totalSleepMin.map { String(format: "%.1f", $0 / 60) } ?? "—", unit: "H",
                              delta: delta(t?.totalSleepMin.map { $0 / 60 }, sleepBase.map { $0 / 60 }, decimals: 1),
                              deltaGood: good(t?.totalSleepMin, sleepBase, higherIsBetter: true))
                    if let r = t?.respRateBpm {
                        Divider().overlay(FT.stroke)
                        FTStatRow(icon: "lungs.fill", name: "Respiratory rate", value: String(format: "%.1f", r), unit: "RPM")
                    }
                }
            }
        }
    }

    private func delta(_ v: Double?, _ base: Double?, decimals: Int = 0) -> String? {
        guard let v, let base else { return nil }
        let d = v - base
        let mag = decimals == 0 ? "\(Int(abs(d).rounded()))" : String(format: "%.1f", abs(d))
        return "\(d >= 0 ? "▲" : "▼") \(mag)"
    }

    private func good(_ v: Double?, _ base: Double?, higherIsBetter: Bool) -> Bool? {
        guard let v, let base, abs(v - base) > 0.5 else { return nil }
        return higherIsBetter ? v > base : v < base
    }

    // MARK: Training

    private var trainingSection: some View {
        FTSection("Strength") {
            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    NavigationLink { LiftLogView() } label: {
                        FTActivityRow(icon: "dumbbell.fill", tint: FT.strain,
                                      title: model.lastLiftSession?.programName ?? "Lift log",
                                      subtitle: model.lastLiftSession == nil
                                        ? "Build your program once — every set then shows what to beat."
                                        : "Last session " + daysText(model.daysSinceLift ?? 0).lowercased(),
                                      value: "\(model.liftSessionsLast7)", valueCaption: "This week")
                    }
                    .buttonStyle(.plain)

                    if !model.progress.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(model.progress) { p in
                                HStack(spacing: 10) {
                                    trendIcon(p.trend)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.exercise).font(FT.head(14)).foregroundStyle(FT.text).lineLimit(1)
                                        Text(p.lastLine).font(.system(size: 12, weight: .medium).monospacedDigit())
                                            .foregroundStyle(FT.text2).lineLimit(1)
                                    }
                                    Spacer()
                                    if let e = p.lastBestE1RM {
                                        VStack(alignment: .trailing, spacing: 0) {
                                            Text(LiftFormat.trim(LiftFormat.display(fromKilograms: (e * 2).rounded() / 2, system: unitSystem)))
                                                .font(FT.number(18)).foregroundStyle(FT.text)
                                            FTLabel("Est. 1RM", color: FT.text3)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 2)
                    }

                    NavigationLink { LiftLogView() } label: { Text("Start workout") }
                        .buttonStyle(FTPrimaryButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func trendIcon(_ t: ExerciseProgress.Trend) -> some View {
        Group {
            switch t {
            case .up: Image(systemName: "arrow.up.right").foregroundStyle(FT.green)
            case .flat: Image(systemName: "equal").foregroundStyle(FT.yellow)
            case .down: Image(systemName: "arrow.down.right").foregroundStyle(FT.red)
            case .new: Image(systemName: "sparkle").foregroundStyle(FT.text3)
            }
        }
        .font(.system(size: 13, weight: .bold))
        .frame(width: 26, height: 26)
        .background(FT.cardHi, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func daysText(_ d: Int) -> String {
        switch d {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(d) days ago"
        }
    }

    // MARK: Running

    private var runningSection: some View {
        FTSection("Running") {
            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    if let run = model.runs.first {
                        let prev = model.runs.dropFirst().first
                        let f = RunCoach.feedback(for: run, previous: prev, allRuns: model.runs,
                                                  hrMax: profile.hrMax, recoveryToday: repo.today?.recovery,
                                                  imperial: imperialDistance)
                        NavigationLink { RunCoachView() } label: {
                            FTActivityRow(icon: "figure.run", tint: FT.teal, title: f.verdict,
                                          subtitle: daysText(model.daysSinceRun ?? 0) + " · " + f.effortLabel,
                                          value: run.km.map { String(format: imperialDistance ? "%.1f" : "%.1f", imperialDistance ? $0 / 1.609344 : $0) },
                                          valueCaption: imperialDistance ? "MI" : "KM")
                        }
                        .buttonStyle(.plain)
                        FTInsight(title: "Next run", detail: f.nextRun, tint: FT.teal)
                    } else {
                        NavigationLink { RunCoachView() } label: {
                            FTActivityRow(icon: "figure.run", tint: FT.teal, title: "Start running",
                                          subtitle: "First run: 10 × (1 min jog + 1 min walk), slow enough to talk.")
                        }
                        .buttonStyle(.plain)
                    }
                    NavigationLink { RunCoachView() } label: { Text("Running coach") }
                        .buttonStyle(FTSecondaryButtonStyle())
                }
            }
        }
    }
}

// MARK: - Focus settings

struct FocusSettingsView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    @AppStorage(FocusPrefs.focusModeKey) private var focusMode = true
    @AppStorage(FocusPrefs.morningTipEnabledKey) private var tipEnabled = true
    @AppStorage(FocusPrefs.morningTipMinutesKey) private var tipMinutes = FocusPrefs.defaultMorningTipMinutes
    @AppStorage(FocusPrefs.goalKey) private var goalRaw = BodyGoal.cut.rawValue

    @State private var sentTest = false

    private var tipTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: tipMinutes / 60, minute: tipMinutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                tipMinutes = (c.hour ?? 7) * 60 + (c.minute ?? 0)
            })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Zee mode", isOn: $focusMode)
                } footer: {
                    Text("Zee mode puts the focused tab first. More mode is the original NOOP layout. You can also flip it with the Zee | More switch at the top of the Zee tab and the More tab.")
                }
                Section("Goal") {
                    Picker("Current goal", selection: $goalRaw) {
                        ForEach(BodyGoal.allCases) { g in Text(g.label).tag(g.rawValue) }
                    }
                }
                #if os(iOS)
                Section {
                    Toggle("Morning tip notification", isOn: $tipEnabled)
                    if tipEnabled {
                        DatePicker("Time", selection: tipTime, displayedComponents: .hourAndMinute)
                        Button {
                            Task { await sendTest() }
                        } label: {
                            Text(sentTest ? "Sent — check in 5 seconds" : "Send a test now")
                        }
                    }
                } footer: {
                    Text("Built from your latest recovery, sleep, HRV, training and weight trend. Calculated on your phone — nothing is sent anywhere.")
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(FT.bg.ignoresSafeArea())
            .tint(FT.green)
            .navigationTitle("Zee mode settings")
            .zeeInlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onDisappear { Task { await DailyEdgeNotifier.reschedule(repo: repo) } }
        }
        .zeeSheetFrame()
        .preferredColorScheme(.dark)
    }

    private func sendTest() async {
        guard await DailyEdgeNotifier.requestPermission() else { return }
        let tips = DailyEdge.tips(FocusModel.shared.edgeInputs(repo: repo))
        let content = UNMutableNotificationContent()
        content.title = tips.first?.title ?? "Today's edge"
        content.body = tips.first?.detail ?? ""
        content.sound = .default
        let req = UNNotificationRequest(identifier: "custom-daily-edge-test", content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        try? await UNUserNotificationCenter.current().add(req)
        sentTest = true
    }
}
