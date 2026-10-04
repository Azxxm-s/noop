import Foundation
import SwiftUI
import Charts

// MARK: - Body-fat maths (pure)
//
// Tape:     U.S. Navy circumference method (Hodgdon & Beckett), metric form.
// Calipers: Jackson–Pollock 3-site and 7-site body density, converted with the Siri equation.
// All inputs in cm / mm / years. Results are estimates (typically ±3–4 %); trend matters more than
// the absolute number, so always measure the same way, same time of day.

enum BodyFatSex: String, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var label: String { self == .male ? "Male" : "Female" }
}

enum BodyFatMethod: String, Codable, CaseIterable, Identifiable {
    case tape, caliper3, caliper7
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tape: return "Tape"
        case .caliper3: return "Caliper 3-site"
        case .caliper7: return "Caliper 7-site"
        }
    }
}

enum CaliperSite: String, CaseIterable, Identifiable {
    case chest, abdomen, thigh, triceps, suprailiac, subscapular, midaxillary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chest: return "Chest"
        case .abdomen: return "Abdomen"
        case .thigh: return "Thigh"
        case .triceps: return "Triceps"
        case .suprailiac: return "Suprailiac"
        case .subscapular: return "Subscapular"
        case .midaxillary: return "Midaxillary"
        }
    }
    var how: String {
        switch self {
        case .chest: return "Diagonal fold halfway between the armpit crease and the nipple (men) — one-third of the way for women."
        case .abdomen: return "Vertical fold 2 cm (about 1 inch) to the right of the belly button."
        case .thigh: return "Vertical fold on the front of the thigh, halfway between hip crease and top of the kneecap. Leg relaxed."
        case .triceps: return "Vertical fold on the back of the upper arm, halfway between shoulder and elbow. Arm hanging loose."
        case .suprailiac: return "Diagonal fold just above the front of the hip bone, following its natural line."
        case .subscapular: return "Diagonal fold just below the lower tip of the shoulder blade, at about 45°."
        case .midaxillary: return "Vertical fold on the side of the torso, level with the bottom of the breastbone, in line with the armpit."
        }
    }

    static func sites(_ method: BodyFatMethod, sex: BodyFatSex) -> [CaliperSite] {
        switch method {
        case .tape: return []
        case .caliper3: return sex == .male ? [.chest, .abdomen, .thigh] : [.triceps, .suprailiac, .thigh]
        case .caliper7: return [.chest, .abdomen, .thigh, .triceps, .suprailiac, .subscapular, .midaxillary]
        }
    }
}

enum BodyFatCalc {
    static func siri(_ density: Double) -> Double { 495 / density - 450 }

    /// U.S. Navy. Women need 'hipCm'.
    static func navy(sex: BodyFatSex, heightCm: Double, neckCm: Double, waistCm: Double, hipCm: Double?) -> Double? {
        guard heightCm > 0, neckCm > 0, waistCm > 0 else { return nil }
        switch sex {
        case .male:
            guard waistCm > neckCm else { return nil }
            return 495 / (1.0324 - 0.19077 * log10(waistCm - neckCm) + 0.15456 * log10(heightCm)) - 450
        case .female:
            guard let hipCm, hipCm > 0, waistCm + hipCm > neckCm else { return nil }
            return 495 / (1.29579 - 0.35004 * log10(waistCm + hipCm - neckCm) + 0.22100 * log10(heightCm)) - 450
        }
    }

    /// Jackson–Pollock. 'sumMm' = sum of the skinfolds for the method's sites.
    static func jacksonPollock(method: BodyFatMethod, sex: BodyFatSex, sumMm s: Double, age: Int) -> Double? {
        guard s > 0 else { return nil }
        let a = Double(age)
        let d: Double
        switch (method, sex) {
        case (.caliper3, .male):   d = 1.10938 - 0.0008267 * s + 0.0000016 * s * s - 0.0002574 * a
        case (.caliper3, .female): d = 1.0994921 - 0.0009929 * s + 0.0000023 * s * s - 0.0001392 * a
        case (.caliper7, .male):   d = 1.112 - 0.00043499 * s + 0.00000055 * s * s - 0.00028826 * a
        case (.caliper7, .female): d = 1.097 - 0.00046971 * s + 0.00000056 * s * s - 0.00012828 * a
        default: return nil
        }
        return siri(d)
    }

    static func category(_ pct: Double, sex: BodyFatSex) -> (String, Color) {
        let cuts: [Double] = sex == .male ? [6, 14, 18, 25] : [14, 21, 25, 32]
        switch pct {
        case ..<cuts[0]: return ("Contest lean", FT.teal)
        case ..<cuts[1]: return ("Athletic", FT.green)
        case ..<cuts[2]: return ("Fit", FT.green)
        case ..<cuts[3]: return ("Average", FT.yellow)
        default: return ("Above average", FT.red)
        }
    }
}

// MARK: - Log

struct BodyFatEntry: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var ts: Double
    var method: BodyFatMethod
    var percent: Double
    var weightKg: Double?
    var note: String
    var date: Date { Date(timeIntervalSince1970: ts) }
}

@MainActor
final class BodyFatLog: ObservableObject {
    static let shared = BodyFatLog()
    private static let key = "custom.bodyFat.entries"
    private static let lastInputsKey = "custom.bodyFat.lastInputs"
    @Published private(set) var entries: [BodyFatEntry] = []   // oldest → newest

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let e = try? JSONDecoder().decode([BodyFatEntry].self, from: d) {
            entries = e.sorted { $0.ts < $1.ts }
        }
    }

    func add(_ e: BodyFatEntry) {
        entries.append(e)
        entries.sort { $0.ts < $1.ts }
        save()
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    var latest: BodyFatEntry? { entries.last }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Remembered measurements (cm / mm) so the next check-in only needs the changed numbers.
    var lastInputs: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.lastInputsKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastInputsKey) }
    }
}

// MARK: - Calculator screen

struct BodyFatView: View {
    @EnvironmentObject private var profile: ProfileStore
    @ObservedObject private var log = BodyFatLog.shared
    @ObservedObject private var weights = WeightLog.shared

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var imperial: Bool { (UnitSystem(rawValue: unitSystemRaw) ?? .metric) == .imperial }

    @State private var method: BodyFatMethod = .tape
    @State private var sex: BodyFatSex = .male
    @State private var age: Int = 30
    @State private var fields: [String: String] = [:]   // display units
    @State private var savedFlash = false
    @State private var showHow = false

    private var lenUnit: String { imperial ? "in" : "cm" }
    private func toCm(_ v: Double) -> Double { imperial ? v * 2.54 : v }
    private func fromCm(_ v: Double) -> Double { imperial ? v / 2.54 : v }

    private func value(_ key: String) -> Double? {
        fields[key].flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
    }

    private var result: Double? {
        switch method {
        case .tape:
            guard let h = value("height"), let n = value("neck"), let w = value("waist") else { return nil }
            return BodyFatCalc.navy(sex: sex, heightCm: toCm(h), neckCm: toCm(n), waistCm: toCm(w),
                                    hipCm: value("hip").map(toCm))
        case .caliper3, .caliper7:
            let sites = CaliperSite.sites(method, sex: sex)
            let vals = sites.compactMap { value($0.rawValue) }
            guard vals.count == sites.count else { return nil }
            return BodyFatCalc.jacksonPollock(method: method, sex: sex, sumMm: vals.reduce(0, +), age: age)
        }
    }

    private var bodyWeightKg: Double? { (weights.today ?? weights.latest)?.kg ?? (profile.weightKg > 0 ? profile.weightKg : nil) }

    var body: some View {
        FTPage {
            VStack(alignment: .leading, spacing: 4) {
                FTLabel("Body composition", color: FT.text3)
                Text("Body fat").font(FT.head(32)).foregroundStyle(FT.text)
                Text("Estimate from a tailor's tape or skinfold calipers. Measure the same way each time — the trend is what matters.")
                    .font(FT.small).foregroundStyle(FT.text2)
            }

            resultCard

            // Method + sex pickers
            pills(BodyFatMethod.allCases.map { ($0.label, $0.rawValue) }, selected: method.rawValue) {
                method = BodyFatMethod(rawValue: $0) ?? .tape
            }
            pills(BodyFatSex.allCases.map { ($0.label, $0.rawValue) }, selected: sex.rawValue) {
                sex = BodyFatSex(rawValue: $0) ?? .male
            }

            FTSection(title: method == .tape ? "Tape measurements (\(lenUnit))" : "Skinfolds (mm)", trailing: {
                Button { withAnimation { showHow.toggle() } } label: {
                    FTLabel(showHow ? "Hide guide" : "How to measure", color: FT.text)
                }
            }) {
                FTCard {
                    VStack(spacing: 0) {
                        if method == .tape {
                            inputRow("height", "Height", lenUnit, how: "Barefoot, standing tall against a wall.")
                            inputRow("neck", "Neck", lenUnit, how: "Just below the Adam's apple, tape sloping slightly down to the front. Don't flare the neck.")
                            inputRow("waist", "Waist", lenUnit,
                                     how: sex == .male ? "Horizontally at the belly button, relaxed, after a normal breath out. Don't suck in."
                                                       : "At the narrowest point of the waist, relaxed, after a normal breath out.")
                            if sex == .female {
                                inputRow("hip", "Hips", lenUnit, how: "Around the widest part of the buttocks, feet together.")
                            }
                        } else {
                            ForEach(CaliperSite.sites(method, sex: sex)) { site in
                                inputRow(site.rawValue, site.label, "mm", how: site.how)
                            }
                            HStack {
                                FTLabel("Age", color: FT.text2)
                                Spacer()
                                Stepper(value: $age, in: 16...90) {
                                    Text("\(age)").font(FT.number(20)).foregroundStyle(FT.text)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .fixedSize()
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }

            if method != .tape {
                FTCard {
                    FTInsight(title: "Caliper technique",
                              detail: "Right side of the body, skin dry, before training. Pinch skin and fat (not muscle) with thumb and finger, place the caliper 1 cm away from your fingers, read after 2 seconds. Take 2–3 readings per site and use the average.",
                              tint: FT.strain)
                }
            }

            Button { save() } label: { Text(savedFlash ? "Saved ✓" : "Save measurement") }
                .buttonStyle(FTPrimaryButtonStyle())
                .disabled(result == nil)
                .opacity(result == nil ? 0.4 : 1)

            historySection
        }
        .zeeInlineTitle()
        .onAppear(perform: prefill)
    }

    // MARK: Pieces

    private var resultCard: some View {
        FTCard {
            if let r = result, r.isFinite, r > 1, r < 70 {
                let cat = BodyFatCalc.category(r, sex: sex)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.1f", r)).font(FT.number(56, weight: .bold)).foregroundStyle(FT.text)
                        Text("%").font(FT.head(24)).foregroundStyle(FT.text3)
                        Spacer()
                        Text(cat.0)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(cat.1.opacity(0.18), in: Capsule())
                            .foregroundStyle(cat.1)
                    }
                    if let w = bodyWeightKg {
                        let fat = w * r / 100
                        HStack(spacing: 0) {
                            mini("Lean mass", fmtKg(w - fat))
                            mini("Fat mass", fmtKg(fat))
                            mini("Weight", fmtKg(w))
                        }
                    }
                    if let prev = log.latest {
                        let d = r - prev.percent
                        Text("\(d >= 0 ? "+" : "−")\(String(format: "%.1f", abs(d)))% vs last check-in (\(prev.date.formatted(.dateTime.day().month(.abbreviated))))")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(d <= 0 ? FT.green : FT.yellow)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("—").font(FT.number(56, weight: .bold)).foregroundStyle(FT.text3)
                    Text(method == .tape ? "Enter your height, neck and waist\(sex == .female ? " and hips" : "")."
                                         : "Enter all \(CaliperSite.sites(method, sex: sex).count) skinfolds.")
                        .font(FT.small).foregroundStyle(FT.text2)
                }
            }
        }
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            FTLabel(label, color: FT.text3)
            Text(value).font(FT.number(18)).foregroundStyle(FT.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fmtKg(_ kg: Double) -> String {
        imperial ? String(format: "%.1f lb", kg * 2.20462) : String(format: "%.1f kg", kg)
    }

    private func pills(_ items: [(String, String)], selected: String, onPick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                Button { withAnimation(.easeOut(duration: 0.15)) { onPick(it.1) } } label: {
                    Text(it.0)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(selected == it.1 ? Color.white : FT.card, in: Capsule())
                        .foregroundStyle(selected == it.1 ? Color.black : FT.text2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func inputRow(_ key: String, _ label: String, _ unit: String, how: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 15, weight: .semibold)).foregroundStyle(FT.text)
                Spacer()
                TextField("0", text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }))
                    .zeeDecimalKeyboard()
                    .multilineTextAlignment(.trailing)
                    .font(FT.number(22))
                    .foregroundStyle(FT.text)
                    .frame(width: 90)
                Text(unit).font(.system(size: 12, weight: .semibold)).foregroundStyle(FT.text3).frame(width: 26, alignment: .leading)
            }
            if showHow {
                Text(how).font(.system(size: 12)).foregroundStyle(FT.text3).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(FT.stroke).padding(.top, 4)
        }
        .padding(.top, 10)
    }

    private var historySection: some View {
        FTSection("History") {
            FTCard {
                VStack(alignment: .leading, spacing: 12) {
                    if log.entries.count >= 2 {
                        Chart {
                            ForEach(log.entries) { e in
                                LineMark(x: .value("Date", e.date), y: .value("Body fat", e.percent))
                                    .foregroundStyle(FT.text)
                                    .interpolationMethod(.catmullRom)
                                PointMark(x: .value("Date", e.date), y: .value("Body fat", e.percent))
                                    .foregroundStyle(FT.green)
                            }
                        }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartYAxis {
                            AxisMarks(position: .trailing) { _ in
                                AxisGridLine().foregroundStyle(FT.track)
                                AxisValueLabel().foregroundStyle(FT.text3)
                            }
                        }
                        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(FT.text3) } }
                        .frame(height: 160)
                    }
                    if log.entries.isEmpty {
                        Text("No check-ins yet. Measure every 2–4 weeks, same method, same time of day.")
                            .font(FT.small).foregroundStyle(FT.text2)
                    }
                    ForEach(log.entries.reversed()) { e in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.date.formatted(.dateTime.day().month().year()))
                                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(FT.text)
                                Text(e.method.label).font(.system(size: 12)).foregroundStyle(FT.text3)
                            }
                            Spacer()
                            Text(String(format: "%.1f%%", e.percent)).font(FT.number(20)).foregroundStyle(FT.text)
                        }
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) { log.delete(e.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }

    // MARK: State

    private func prefill() {
        sex = profile.sex == "female" ? .female : .male
        age = max(16, min(90, profile.age))
        var f: [String: String] = [:]
        let last = log.lastInputs
        func put(_ key: String, cm: Double?) {
            if let cm, cm > 0 { f[key] = LiftFormat.trim((fromCm(cm) * 10).rounded() / 10) }
        }
        put("height", cm: last["height"] ?? (profile.heightCm > 0 ? profile.heightCm : nil))
        put("neck", cm: last["neck"])
        put("waist", cm: last["waist"] ?? (profile.waistCm > 0 ? profile.waistCm : nil))
        put("hip", cm: last["hip"])
        for s in CaliperSite.allCases { if let mm = last[s.rawValue] { f[s.rawValue] = LiftFormat.trim(mm) } }
        if fields.isEmpty { fields = f }
        if let m = log.latest?.method { method = m }
    }

    private func save() {
        guard let r = result else { return }
        log.add(BodyFatEntry(ts: Date().timeIntervalSince1970, method: method,
                             percent: (r * 10).rounded() / 10, weightKg: bodyWeightKg, note: ""))
        var last = log.lastInputs
        for k in ["height", "neck", "waist", "hip"] { if let v = value(k) { last[k] = toCm(v) } }
        for s in CaliperSite.allCases { if let v = value(s.rawValue) { last[s.rawValue] = v } }
        log.lastInputs = last
        if let h = last["height"], h > 100, h < 250 { profile.heightCm = (h * 10).rounded() / 10 }
        if let w = last["waist"], w > 40, w < 200 { profile.waistCm = (w * 10).rounded() / 10 }
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { savedFlash = false } }
    }
}
