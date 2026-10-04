import SwiftUI
import Charts
import StrandDesign

// MARK: - Daily weigh-in sheet (asked once a day, first open)

struct WeighInSheet: View {
    @ObservedObject private var log = WeightLog.shared
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    private var unit: String { LiftFormat.weightUnit(unitSystem).uppercased() }
    private var parsed: Double? {
        Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(FT.track).frame(width: 40, height: 5).frame(maxWidth: .infinity).padding(.top, 10)

            VStack(alignment: .leading, spacing: 6) {
                FTLabel(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)), color: FT.text3)
                Text("Morning weigh-in").font(FT.head(30)).foregroundStyle(FT.text)
                Text("After the bathroom, before food or water. The weekly average is what counts.")
                    .font(FT.small).foregroundStyle(FT.text2)
            }
            .padding(.top, 22)

            Spacer(minLength: 24)

            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(placeholder, text: $text)
                        .zeeDecimalKeyboard()
                        .multilineTextAlignment(.center)
                        .font(FT.number(80, weight: .bold))
                        .foregroundStyle(FT.text)
                        .focused($fieldFocused)
                        .fixedSize()
                    Text(unit).font(FT.head(22)).foregroundStyle(FT.text3)
                }
                if let delta = deltaText {
                    Text(delta).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(FT.text2)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                stepButton("−0.5", -0.5)
                stepButton("−0.1", -0.1)
                stepButton("+0.1", 0.1)
                stepButton("+0.5", 0.5)
            }
            .padding(.top, 22)

            Spacer(minLength: 24)

            Button { save() } label: { Text("Save weight") }
                .buttonStyle(FTPrimaryButtonStyle())
                .disabled(parsed == nil)
                .opacity(parsed == nil ? 0.4 : 1)

            Button {
                log.markPrompted()
                dismiss()
            } label: { Text("Skip today") }
                .buttonStyle(FTSecondaryButtonStyle())
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 22)
        .background(FT.bg.ignoresSafeArea())
        .zeeSheetFrame()
        .preferredColorScheme(.dark)
        .onAppear {
            if text.isEmpty, let last = log.latest {
                text = LiftFormat.trim(LiftFormat.display(fromKilograms: last.kg, system: unitSystem))
            }
            fieldFocused = true
        }
        .onDisappear { log.markPrompted() }
    }

    private var placeholder: String { unitSystem == .imperial ? "180.0" : "80.0" }

    private var deltaText: String? {
        guard let v = parsed, let last = log.entries.last(where: { $0.day != WeightLog.dayKey() }) else { return nil }
        let lastDisp = LiftFormat.display(fromKilograms: last.kg, system: unitSystem)
        let d = ((v - lastDisp) * 10).rounded() / 10
        let sign = d > 0 ? "▲ " : (d < 0 ? "▼ " : "")
        return "\(sign)\(LiftFormat.trim(abs(d))) \(unit) VS \(last.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())"
    }

    private func stepButton(_ label: String, _ delta: Double) -> some View {
        Button {
            let current = parsed ?? (log.latest.map { LiftFormat.display(fromKilograms: $0.kg, system: unitSystem) } ?? 0)
            let next = ((current + delta) * 10).rounded() / 10
            text = LiftFormat.trim(max(0, next))
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(FT.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(FT.stroke, lineWidth: 1))
                .foregroundStyle(FT.text)
        }
        .buttonStyle(.plain)
    }

    private func save() {
        guard let v = parsed else { return }
        let kg = LiftFormat.kilograms(fromDisplay: v, system: unitSystem)
        log.log(kg: kg)
        // Keep the profile weight current so calorie / effort maths use today's body weight.
        if kg > 30 && kg < 250 { profile.weightKg = (kg * 10).rounded() / 10 }
        dismiss()
    }
}

// MARK: - Weight chart (used on Focus + history)

struct WeightChart: View {
    let entries: [WeightEntry]
    let unitSystem: UnitSystem

    private func disp(_ kg: Double) -> Double { LiftFormat.display(fromKilograms: kg, system: unitSystem) }

    private var smooth: [(date: Date, kg: Double)] {
        var out: [(date: Date, kg: Double)] = []
        for (i, e) in entries.enumerated() {
            let w = entries[max(0, i - 6)...i].map(\.kg)
            out.append((e.date, w.reduce(0, +) / Double(w.count)))
        }
        return out
    }

    var body: some View {
        let vals = entries.map { disp($0.kg) }
        let lo = (vals.min() ?? 0) - 1, hi = (vals.max() ?? 1) + 1
        Chart {
            ForEach(entries) { e in
                PointMark(x: .value("Day", e.date, unit: .day), y: .value("Weight", disp(e.kg)))
                    .foregroundStyle(FT.text3)
                    .symbolSize(16)
            }
            ForEach(Array(smooth.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Day", p.date, unit: .day), y: .value("7-day avg", disp(p.kg)))
                    .foregroundStyle(FT.text)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            if let last = smooth.last {
                PointMark(x: .value("Day", last.date, unit: .day), y: .value("7-day avg", disp(last.kg)))
                    .foregroundStyle(FT.green)
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(FT.track)
                AxisValueLabel().foregroundStyle(FT.text3).font(.system(size: 10, weight: .semibold))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .foregroundStyle(FT.text3).font(.system(size: 10, weight: .semibold))
            }
        }
    }
}

// MARK: - Weight history screen

struct WeightHistoryView: View {
    @ObservedObject private var log = WeightLog.shared
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var range = 90
    @State private var showingAdd = false
    @State private var pendingDelete: WeightEntry?

    private let ranges: [(String, Int)] = [("30D", 30), ("90D", 90), ("1Y", 365), ("ALL", 100_000)]

    var body: some View {
        let shown = range >= 100_000 ? log.entries : log.recent(days: range)
        FTPage {
            HStack {
                Text("Body weight").font(FT.head(30)).foregroundStyle(FT.text)
                Spacer()
                Button { showingAdd = true } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 38, height: 38).background(Color.white, in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(ranges.indices, id: \.self) { i in
                    let r = ranges[i]
                    Button { range = r.1 } label: {
                        Text(r.0)
                            .font(.system(size: 12, weight: .bold)).tracking(1.2)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(range == r.1 ? Color.white : FT.card, in: Capsule())
                            .foregroundStyle(range == r.1 ? Color.black : FT.text2)
                    }
                    .buttonStyle(.plain)
                }
            }

            FTCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 22) {
                        stat("Current", log.latest.map { fmt($0.kg) } ?? "—")
                        stat("7-day avg", log.average(lastDays: 7).map(fmt) ?? "—")
                        stat("Weekly", log.weeklyTrendKg.map { t in
                            (t >= 0 ? "+" : "−") + fmt(abs(t))
                        } ?? "—")
                    }
                    if shown.count >= 2 {
                        WeightChart(entries: shown, unitSystem: unitSystem).frame(height: 220)
                    } else {
                        Text("Log a few days to see your trend line.").font(FT.small).foregroundStyle(FT.text2)
                    }
                }
            }

            FTSection("Entries") {
                FTCard(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(Array(log.entries.reversed().prefix(120))) { e in
                            HStack {
                                Text(e.date.formatted(.dateTime.weekday(.abbreviated).day().month().year()))
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(FT.text2)
                                Spacer()
                                Text(fmt(e.kg)).font(FT.number(20)).foregroundStyle(FT.text)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 11)
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(role: .destructive) { log.delete(day: e.day) } label: {
                                    Label("Delete entry", systemImage: "trash")
                                }
                            }
                            Divider().overlay(FT.stroke)
                        }
                    }
                }
                FTLabel("Long-press an entry to delete it", color: FT.text3)
            }
        }
        .zeeInlineTitle()
        .sheet(isPresented: $showingAdd) { WeighInSheet() }
    }

    private func fmt(_ kg: Double) -> String {
        "\(LiftFormat.trim((LiftFormat.display(fromKilograms: kg, system: unitSystem) * 10).rounded() / 10)) \(LiftFormat.weightUnit(unitSystem))"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FTLabel(label, color: FT.text3)
            Text(value).font(FT.number(22)).foregroundStyle(FT.text).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}
