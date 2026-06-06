import SwiftUI

/// Calculator component view. Renders a titled list of rows whose results
/// are recomputed live every render by `CalculatorResolver` — never read
/// from persisted state — so tuning a variable or editing a source tracker
/// updates downstream values immediately.
///
/// - **Variable** rows show an inline tuning control (slider / stepper /
///   field) bound through `MyAppStore.setCalculatorVariable`.
/// - **Aggregate** rows show the computed scalar with a transparent source
///   subtitle ("sum of amount where cuisine=African").
/// - **Formula** rows show the computed scalar with the expression as
///   subtitle, plus a status note when something can't resolve (a deleted
///   source tracker renders "(source removed)" rather than crashing).
public struct CalculatorView: View {
    @Bindable var store: MyAppStore
    let data: CalculatorData
    let myAppId: UUID
    let componentId: String

    public init(store: MyAppStore, data: CalculatorData, myAppId: UUID, componentId: String) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    /// Sibling components in the same MyApp — the pool aggregate rows pull
    /// their source trackers from.
    private var siblingComponents: [Component] {
        store.myApps.first(where: { $0.id == myAppId })?.components ?? []
    }

    private var resolved: CalculatorResolver.Resolved {
        CalculatorResolver.resolve(data, components: siblingComponents)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CalculatorTitleBar(data: data)

            if data.rows.isEmpty {
                CalculatorEmptyHint()
            } else {
                let results = resolved
                VStack(spacing: 0) {
                    ForEach(data.rows) { row in
                        CalcRowView(
                            store: store,
                            myAppId: myAppId,
                            componentId: componentId,
                            row: row,
                            result: results.result(forKey: row.key),
                            sourceName: sourceName(for: row)
                        )
                        if row.id != data.rows.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Embedded chart (Phase 2, #22) — same store-free ChartView a
            // standalone chart component uses, resolved live against siblings.
            if let chart = data.inlineChart {
                ChartContainerView(store: store, data: chart, myAppId: myAppId)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Display name of an aggregate row's source tracker component (for the
    /// transparent subtitle). Nil for non-aggregate rows.
    private func sourceName(for row: CalcRow) -> String? {
        guard case .aggregate(let spec) = row.kind else { return nil }
        return store.componentName(spec.sourceComponentId, myAppId: myAppId)
    }
}

// MARK: - Title bar

private struct CalculatorTitleBar: View {
    let data: CalculatorData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "function")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(data.title.isEmpty ? "Calculator" : data.title)
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Text(rowCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rowCountLabel: String {
        let n = data.rows.count
        return n == 1 ? "1 row" : "\(n) rows"
    }
}

// MARK: - Row

private struct CalcRowView: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let componentId: String
    let row: CalcRow
    let result: CalculatorResolver.RowResult?
    let sourceName: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name.isEmpty ? row.key : row.name)
                    .font(.body)
                    .fontWeight(isFormula ? .medium : .regular)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }

    private var isFormula: Bool {
        if case .formula = row.kind { return true }
        return false
    }

    /// The transparent "how this number was computed" subtitle.
    private var subtitle: String? {
        switch row.kind {
        case .variable:
            return nil
        case .aggregate(let spec):
            var s = "\(spec.reduce.rawValue) of \(spec.fieldName)"
            if !spec.filter.isEmpty {
                let clauses = spec.filter
                    .map { "\($0.key)=\($0.value)" }
                    .sorted()
                    .joined(separator: ", ")
                s += " where \(clauses)"
            }
            if let sourceName { s += " · \(sourceName)" }
            return s
        case .formula(let expression):
            return expression
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.kind {
        case .variable(let value, let control):
            VariableControl(
                value: value,
                control: control,
                unit: row.unit,
                format: row.format,
                onChange: { newValue in
                    _ = store.setCalculatorVariable(
                        key: row.key,
                        value: newValue,
                        myAppId: myAppId,
                        componentId: componentId
                    )
                }
            )
        case .aggregate, .formula:
            ComputedValueLabel(result: result, unit: row.unit, format: row.format)
        }
    }
}

// MARK: - Variable control

/// Inline tuning affordance for a variable row. Drives `onChange` on every
/// edit; the parent routes that through the store, which re-renders with the
/// new value so downstream formula rows update live.
private struct VariableControl: View {
    let value: Double
    let control: CalcControl
    let unit: String?
    let format: String?
    let onChange: (Double) -> Void

    var body: some View {
        switch control {
        case .plain:
            HStack(spacing: 6) {
                if let prefix = CalcFormat.unitPrefix(unit) {
                    Text(prefix).foregroundStyle(.secondary)
                }
                TextField("", value: boundValue, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                if let suffix = CalcFormat.unitSuffix(unit) {
                    Text(suffix).foregroundStyle(.secondary)
                }
            }
        case .stepper(let step):
            HStack(spacing: 8) {
                Text(CalcFormat.string(value, unit: unit, format: format))
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 70, alignment: .trailing)
                Stepper("", value: boundValue, step: step)
                    .labelsHidden()
            }
        case .slider(let lo, let hi, let step):
            VStack(alignment: .trailing, spacing: 2) {
                Text(CalcFormat.string(value, unit: unit, format: format))
                    .font(.body.monospacedDigit())
                Slider(
                    value: boundValue,
                    in: lo...max(hi, lo + step),
                    step: step
                )
                .frame(width: 180)
            }
        }
    }

    private var boundValue: Binding<Double> {
        Binding(get: { value }, set: { onChange($0) })
    }
}

// MARK: - Computed value label

/// Read-only result label for aggregate / formula rows. Shows the formatted
/// value when resolved, or a short status note (`(source removed)`,
/// `(circular reference)`, …) when it couldn't compute.
private struct ComputedValueLabel: View {
    let result: CalculatorResolver.RowResult?
    let unit: String?
    let format: String?

    var body: some View {
        if let result, let value = result.value, result.status == .ok {
            Text(CalcFormat.string(value, unit: unit, format: format))
                .font(.body.monospacedDigit())
                .fontWeight(.medium)
                .textSelection(.enabled)
        } else {
            Text(statusNote)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var statusNote: String {
        switch result?.status {
        case .brokenRef: return "(source removed)"
        case .cycle: return "(circular reference)"
        case .nonNumeric: return "(no numeric values)"
        case .divisionByZero: return "(division by zero)"
        case .unknownIdentifier: return "(unknown reference)"
        case .ok, .none: return "—"
        }
    }
}

// MARK: - Empty hint

private struct CalculatorEmptyHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "function")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No rows yet")
                .font(.headline)
            Text("Ask the chat to build a calculation — try \"Estimate my monthly mortgage payment\" or \"Total my expenses by category\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }
}

// MARK: - Value formatting

/// Shared number-with-unit formatting for calculator rows. `format` is an
/// optional printf-style hint (e.g. "%.2f"); without it values render with
/// up to two decimals, trailing zeros trimmed. Currency-symbol units sit in
/// front of the number, everything else behind it (`%` with no space).
enum CalcFormat {
    static func string(_ value: Double, unit: String?, format: String?) -> String {
        let number: String
        if let format, format.contains("%") {
            number = String(format: format, value)
        } else {
            number = defaultNumber(value)
        }
        if let prefix = unitPrefix(unit) {
            return prefix + number
        }
        if let suffix = unitSuffix(unit) {
            return number + suffix
        }
        return number
    }

    static func defaultNumber(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Currency-ish units render in front of the number.
    static func unitPrefix(_ unit: String?) -> String? {
        guard let unit, ["$", "€", "£", "¥"].contains(unit) else { return nil }
        return unit
    }

    /// Non-currency units render behind the number — `%` snug, words spaced.
    static func unitSuffix(_ unit: String?) -> String? {
        guard let unit = unit?.nonEmpty, unitPrefix(unit) == nil else { return nil }
        return unit == "%" ? "%" : " \(unit)"
    }
}
