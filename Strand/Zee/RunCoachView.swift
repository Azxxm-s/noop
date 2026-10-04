import SwiftUI
import Charts
import StrandDesign

/// Running hub: last run feedback, the beginner ladder, and history.
struct RunCoachView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var model = FocusModel.shared

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceRaw = ""
    private var imperial: Bool {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceRaw) == .imperial
    }

    @State private var selected: RunSummary?

    var body: some View {
        FTPage {
            VStack(alignment: .leading, spacing: 4) {
                FTLabel("Coach", color: FT.text3)
                Text("Running").font(FT.head(32)).foregroundStyle(FT.text)
                Text("Built for a lifter running once a week or every other week.")
                    .font(FT.small).foregroundStyle(FT.text2)
            }

            if let run = selected ?? model.runs.first {
                RunFeedbackCard(run: run, previous: previous(of: run), all: model.runs,
                                hrMax: profile.hrMax, recovery: repo.today?.recovery, imperial: imperial)
            } else {
                FTCard {
                    FTInsight(title: "No runs yet",
                              detail: "Start your first run from Workouts → Running with the strap on. Afterwards this screen grades the effort and tells you exactly what to do next time.",
                              tint: FT.teal)
                }
            }

            NavigationLink { WorkoutsView() } label: { Text("Start a run") }
                .buttonStyle(FTPrimaryButtonStyle())

            ladderSection
            essentialsSection
            if model.runs.count >= 2 { trendSection }

            if !model.runs.isEmpty {
                FTSection("Run history") {
                    FTCard(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(model.runs.prefix(20)) { r in
                                Button { withAnimation(.easeOut(duration: 0.2)) { selected = r } } label: { runRow(r) }
                                    .buttonStyle(.plain)
                                Divider().overlay(FT.stroke)
                            }
                        }
                    }
                }
            }
        }
        .zeeInlineTitle()
        .task { await model.load(repo: repo) }
        .refreshable { await model.load(repo: repo) }
    }

    private func previous(of run: RunSummary) -> RunSummary? {
        model.runs.first { $0.row.startTs < run.row.startTs }
    }

    private func runRow(_ r: RunSummary) -> some View {
        let isSel = (selected ?? model.runs.first)?.id == r.id
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(isSel ? FT.teal : Color.clear).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.date.formatted(.dateTime.weekday(.abbreviated).day().month()))
                    .font(FT.head(15)).foregroundStyle(FT.text)
                Text(summaryLine(r)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(FT.text2)
            }
            Spacer()
            if let hr = r.row.avgHr {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(hr)").font(FT.number(20)).foregroundStyle(FT.text)
                    FTLabel("Avg BPM", color: FT.text3)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func summaryLine(_ r: RunSummary) -> String {
        var parts = ["\(Int(r.minutes.rounded())) min"]
        if let km = r.km {
            parts.append(imperial ? String(format: "%.2f mi", km / 1.609344) : String(format: "%.2f km", km))
        }
        if let p = r.pace { parts.append(RunCoach.paceText(p, imperial: imperial)) }
        return parts.joined(separator: " · ")
    }

    private var ladderSection: some View {
        let longest = model.runs.filter { $0.date >= Date().addingTimeInterval(-28 * 86_400) }.map(\.minutes).max() ?? 0
        let l = RunCoach.ladder(longestMinutes: longest)
        return FTSection("Beginner ladder · step \(l.stage + 1) of \(l.steps.count)") {
            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(l.title).font(FT.head(20)).foregroundStyle(FT.text)
                    // Segmented progress bar
                    HStack(spacing: 4) {
                        ForEach(0..<l.steps.count, id: \.self) { i in
                            Capsule().fill(i <= l.stage ? FT.teal : FT.track).frame(height: 5)
                        }
                    }
                    Text("Move up a step when the current one feels easy — you could talk the whole time — for two runs in a row.")
                        .font(FT.small).foregroundStyle(FT.text2)
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(l.steps.enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                                    .frame(width: 22, height: 22)
                                    .background(i < l.stage ? FT.teal : (i == l.stage ? Color.white : FT.cardHi), in: Circle())
                                    .foregroundStyle(i <= l.stage ? Color.black : FT.text3)
                                Text(s).font(.system(size: 13, weight: i == l.stage ? .semibold : .regular))
                                    .foregroundStyle(i == l.stage ? FT.text : FT.text2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var essentialsSection: some View {
        let band = RunCoach.easyBand(hrMax: profile.hrMax)
        return FTSection("Essentials") {
            FTCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(band.lowerBound)–\(band.upperBound)").font(FT.number(40)).foregroundStyle(FT.teal)
                        Text("BPM").font(FT.head(15)).foregroundStyle(FT.text3)
                        Spacer()
                        FTLabel("Your easy zone", color: FT.text2)
                    }
                    FTInsight(title: "Talk test", detail: "If you can't speak full sentences, slow down or walk. That's how the aerobic base gets built.", tint: FT.teal)
                    FTInsight(title: "10% rule", detail: "Add no more than ~10% total running time per week.", tint: FT.strain)
                    FTInsight(title: "Protect leg day", detail: "Keep runs 24–48 h away from heavy squats and deadlifts.", tint: FT.yellow)
                    FTInsight(title: "Short quick steps", detail: "Land under your hips. Overstriding is the usual cause of sore shins.", tint: FT.text2)
                    FTInsight(title: "Heat", detail: "Run early in the morning in hot weather and carry water on anything over 45 min.", tint: FT.red)
                }
            }
        }
    }

    private var trendSection: some View {
        let pts = model.runs.prefix(15).reversed().compactMap { r -> (Date, Double)? in
            guard let p = r.pace else { return nil }
            return (r.date, imperial ? p * 1.609344 : p)
        }
        return FTSection("Pace trend") {
            FTCard {
                if pts.count >= 2 {
                    Chart {
                        ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                            LineMark(x: .value("Date", p.0), y: .value("Pace", p.1))
                                .foregroundStyle(FT.teal)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            PointMark(x: .value("Date", p.0), y: .value("Pace", p.1))
                                .foregroundStyle(FT.teal)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                    .chartYAxis {
                        AxisMarks(position: .trailing) { _ in
                            AxisGridLine().foregroundStyle(FT.track)
                            AxisValueLabel().foregroundStyle(FT.text3)
                        }
                    }
                    .chartXAxis {
                        AxisMarks { _ in AxisValueLabel().foregroundStyle(FT.text3) }
                    }
                    .frame(height: 170)
                } else {
                    Text("Runs need GPS distance to plot pace (min per \(imperial ? "mi" : "km"); higher on the chart = faster).")
                        .font(FT.small).foregroundStyle(FT.text2)
                }
            }
        }
    }
}

struct RunFeedbackCard: View {
    let run: RunSummary
    let previous: RunSummary?
    let all: [RunSummary]
    let hrMax: Int
    let recovery: Double?
    let imperial: Bool

    var body: some View {
        let f = RunCoach.feedback(for: run, previous: previous, allRuns: all, hrMax: hrMax,
                                  recoveryToday: recovery, imperial: imperial)
        FTSection("Run · \(run.date.formatted(.dateTime.weekday(.wide).day().month()))") {
            FTCard {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(f.verdict).font(FT.head(24)).foregroundStyle(FT.text)
                        Text(f.effortLabel.uppercased())
                            .font(.system(size: 11, weight: .bold)).tracking(1.2)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(f.effortColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(f.effortColor)
                    }
                    HStack(spacing: 0) {
                        stat("Time", "\(Int(run.minutes.rounded()))", "MIN")
                        if let km = run.km {
                            stat("Distance", String(format: "%.2f", imperial ? km / 1.609344 : km), imperial ? "MI" : "KM")
                        }
                        if let p = run.pace {
                            stat("Pace", RunCoach.paceText(p, imperial: imperial).components(separatedBy: " ").first ?? "",
                                 imperial ? "/MI" : "/KM")
                        }
                        if let hr = run.row.avgHr { stat("Avg HR", "\(hr)", "BPM") }
                    }
                    Divider().overlay(FT.stroke)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(f.points.enumerated()), id: \.offset) { _, p in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(FT.text3).frame(width: 4, height: 4).padding(.top, 7)
                                Text(p).font(FT.small).foregroundStyle(FT.text2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FTLabel("Next run", color: FT.teal)
                        Text(f.nextRun).font(.system(size: 15, weight: .semibold)).foregroundStyle(FT.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FT.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FT.teal.opacity(0.35), lineWidth: 1))
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FTLabel(label, color: FT.text3)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(FT.number(24)).foregroundStyle(FT.text).lineLimit(1).minimumScaleFactor(0.6)
                Text(unit).font(.system(size: 9, weight: .bold)).foregroundStyle(FT.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
