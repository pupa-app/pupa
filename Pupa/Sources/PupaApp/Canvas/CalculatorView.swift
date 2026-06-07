import SwiftUI

/// Calculator component view. Renders a titled list of rows whose results
/// are recomputed live every render by `CalculatorResolver`.
///
/// - **Variable** rows show an inline tuning control.
/// - **Aggregate / formula / list** rows show the computed result. Formula
///   and list subtitles are collapsed by default — tap the chevron to expand.
/// - **Header** rows are section labels; tap to collapse/expand the rows
///   below until the next header.
public struct CalculatorView: View {
    @Bindable var store: MyAppStore
    let data: CalculatorData
    let myAppId: UUID
    let componentId: String

    /// Header row IDs whose sections are collapsed. Persists across renders
    /// because row IDs are stable.
    @State private var collapsedHeaders: Set<UUID> = []

    public init(store: MyAppStore, data: CalculatorData, myAppId: UUID, componentId: String) {
        self.store = store
        self.data = data
        self.myAppId = myAppId
        self.componentId = componentId
    }

    private var siblingComponents: [Component] {
        store.myApps.first(where: { $0.id == myAppId })?.components ?? []
    }

    private var resolved: CalculatorResolver.Resolved {
        CalculatorResolver.resolve(data, components: siblingComponents)
    }

    /// Build the list of rows to display, skipping any whose containing
    /// section is collapsed. A row is in the section of the last header
    /// above it; rows before the first header are always visible.
    private var visibleRows: [CalcRow] {
        var visible: [CalcRow] = []
        var currentHeaderCollapsed = false
        for row in data.rows {
            if case .header = row.kind {
                currentHeaderCollapsed = collapsedHeaders.contains(row.id)
                visible.append(row)        // headers always shown
            } else if !currentHeaderCollapsed {
                visible.append(row)
            }
        }
        return visible
    }

    /// The single tracker every `linkedField` row points at (when they share
    /// one), plus the currently-common selection. Drives the top-of-calculator
    /// "source" dropdown — pick once, the whole model follows. `nil` when there
    /// are no linked rows, or they span more than one tracker.
    private var linkedSource: (componentId: String, items: [TrackerItem], selectedId: UUID?)? {
        let refs: [ComponentItemRef] = data.rows.compactMap {
            if case .linkedField(let s) = $0.kind { return s.ref }
            return nil
        }
        guard !refs.isEmpty else { return nil }
        let trackerIds = Set(refs.map(\.componentId))
        guard trackerIds.count == 1, let compId = trackerIds.first,
              let comp = siblingComponents.first(where: { $0.id == compId }),
              case .tracker(let tracker) = comp.body else { return nil }
        let distinct = Set(refs.map(\.itemId))
        return (compId, tracker.items, distinct.count == 1 ? distinct.first : nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CalculatorTitleBar(data: data)

            if let src = linkedSource {
                CalcLinkedSourcePicker(
                    store: store, myAppId: myAppId, componentId: componentId,
                    trackerId: src.componentId, items: src.items, selectedId: src.selectedId
                )
            }

            if data.rows.isEmpty {
                CalculatorEmptyHint()
            } else {
                let results = resolved
                let rows = visibleRows
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        if case .header = row.kind {
                            CalcHeaderRow(
                                row: row,
                                collapsed: collapsedHeaders.contains(row.id),
                                onToggle: {
                                    if collapsedHeaders.contains(row.id) {
                                        collapsedHeaders.remove(row.id)
                                    } else {
                                        collapsedHeaders.insert(row.id)
                                    }
                                }
                            )
                        } else {
                            CalcRowView(
                                store: store,
                                myAppId: myAppId,
                                componentId: componentId,
                                row: row,
                                result: results.result(forKey: row.key),
                                sourceName: sourceName(for: row),
                                // When the top dropdown owns the source, hide the
                                // per-row link pills so the model is driven by one
                                // selection (no per-datapoint drift).
                                hideLinkPill: linkedSource != nil
                            )
                        }
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
                .background(Color.gray.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let chart = data.inlineChart {
                ChartContainerView(store: store, data: chart, myAppId: myAppId)
                    .padding(.top, 4)
            }
            ForEach(Array(data.extraCharts.enumerated()), id: \.offset) { _, chart in
                ChartContainerView(store: store, data: chart, myAppId: myAppId)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
        let n = data.rows.filter { if case .header = $0.kind { return false } else { return true } }.count
        return n == 1 ? "1 row" : "\(n) rows"
    }
}

// MARK: - Header row

/// Section label row. Tapping the chevron collapses/expands all rows below
/// until the next header.
private struct CalcHeaderRow: View {
    let row: CalcRow
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(row.name.isEmpty ? "Section" : row.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    /// Hide the per-row link pill (the calculator's top dropdown owns the
    /// linked source instead). Defaults to showing it.
    var hideLinkPill: Bool = false

    /// Formula and list subtitles collapsed by default.
    @State private var subtitleExpanded = false

    private var hasExpandableSubtitle: Bool {
        switch row.kind {
        case .formula, .list: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                // Left: name + always-visible subtitle (aggregate only)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if hasExpandableSubtitle {
                            Button(action: { subtitleExpanded.toggle() }) {
                                Image(systemName: subtitleExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 12)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(row.name.isEmpty ? row.key : row.name)
                            .font(.body)
                            .fontWeight(isFormula ? .medium : .regular)
                    }
                    if let sub = alwaysVisibleSubtitle {
                        Text(sub)
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

            // Expandable subtitle for formula / list rows
            if hasExpandableSubtitle, subtitleExpanded, let sub = expandableSubtitle {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 28)   // indent under chevron
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        .contentShape(Rectangle())
    }

    private var isFormula: Bool {
        if case .formula = row.kind { return true }
        return false
    }

    /// Subtitle always visible (aggregate source description). Nil for rows
    /// where the subtitle is collapsed behind a chevron.
    private var alwaysVisibleSubtitle: String? {
        guard case .aggregate(let spec) = row.kind else { return nil }
        var s = "\(spec.reduce.rawValue) of \(spec.fieldName)"
        if !spec.filter.isEmpty {
            let clauses = spec.filter.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            s += " where \(clauses)"
        }
        if let sourceName { s += " · \(sourceName)" }
        return s
    }

    /// Subtitle shown only when the row is expanded (formula expression /
    /// list spec description).
    private var expandableSubtitle: String? {
        switch row.kind {
        case .formula(let expression):
            return expression
        case .list(let spec):
            switch spec {
            case .sweep(let variableKey, let from, let to, let step, let targetKey):
                return "sweep \(variableKey) \(CalcFormat.defaultNumber(from))→\(CalcFormat.defaultNumber(to)) ×\(CalcFormat.defaultNumber(step)) · \(targetKey)"
            case .trackerColumn(_, let valueField, _, let filter):
                var s = "column \(valueField)"
                if !filter.isEmpty {
                    s += " where " + filter.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                }
                return s
            case .linkedCompare(let refs, let targetKey, _):
                return "compare \(refs.count) · \(targetKey)"
            case .linkedSweep(let refs, _, let variableKey, let from, let to, let step, let targetKey):
                return "sweep \(refs.count)× \(variableKey) \(CalcFormat.defaultNumber(from))→\(CalcFormat.defaultNumber(to)) ×\(CalcFormat.defaultNumber(step)) · \(targetKey)"
            }
        default:
            return nil
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
        case .linkedField(let spec):
            if hideLinkPill {
                ComputedValueLabel(result: result, unit: row.unit, format: row.format)
            } else {
                LinkedFieldControl(
                    store: store,
                    myAppId: myAppId,
                    componentId: componentId,
                    rowKey: row.key,
                    spec: spec,
                    result: result,
                    unit: row.unit,
                    format: row.format
                )
            }
        case .list:
            ListSparkline(points: result?.list ?? [], status: result?.status)
        case .header:
            EmptyView()
        }
    }
}

// MARK: - Linked-field control

/// Trailing control for a `linkedField` row: a tappable chain-link pill
/// naming the linked tracker item (or "Link…" when unset) plus the extracted
/// value. Tapping opens the shared `ComponentItemPickerSheet`; the first
/// picked ref replaces the row's link (swap the item → the model re-runs).
// MARK: - Linked-source dropdown

/// One dropdown at the top of the calculator that points EVERY `linkedField`
/// row at the same tracker item — "pick the house, the whole model follows".
/// Replaces per-row link pills when all linked rows share one tracker, so a
/// user (or the agent's seed) can't accidentally bind each input to a
/// different item.
private struct CalcLinkedSourcePicker: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let componentId: String
    let trackerId: String
    let items: [TrackerItem]
    let selectedId: UUID?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(items, id: \.id) { item in
                    Button {
                        store.setAllCalcRowLinks(
                            to: ComponentItemRef(componentId: trackerId, itemId: item.id),
                            myAppId: myAppId,
                            componentId: componentId
                        )
                    } label: {
                        if item.id == selectedId {
                            Label(item.displayName, systemImage: "checkmark")
                        } else {
                            Text(item.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    private var selectedLabel: String {
        if let id = selectedId, let item = items.first(where: { $0.id == id }) {
            return item.displayName
        }
        return "Pick a source…"
    }
}

private struct LinkedFieldControl: View {
    @Bindable var store: MyAppStore
    let myAppId: UUID
    let componentId: String
    let rowKey: String
    let spec: LinkedFieldSpec
    let result: CalculatorResolver.RowResult?
    let unit: String?
    let format: String?

    @State private var pickerPresented = false

    private var linkedName: String? {
        guard let ref = spec.ref else { return nil }
        return store.displayNameForRefTarget(
            componentId: ref.componentId,
            itemId: ref.itemId,
            myAppId: myAppId
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { pickerPresented = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "link")
                        .font(.caption2)
                    Text(linkedName ?? "Link…")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.15))
                .foregroundStyle(Color.accentColor)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            ComputedValueLabel(result: result, unit: unit, format: format)
        }
        .sheet(isPresented: $pickerPresented) {
            ComponentItemPickerSheet(
                store: store,
                myAppId: myAppId,
                excludeRef: nil,
                alreadyLinked: [],
                onPick: { refs in
                    if let ref = refs.first {
                        _ = store.setCalcRowLinkedRef(
                            key: rowKey,
                            ref: ref,
                            myAppId: myAppId,
                            componentId: componentId
                        )
                    }
                    pickerPresented = false
                },
                onClose: { pickerPresented = false }
            )
        }
    }
}

// MARK: - List sparkline

private struct ListSparkline: View {
    let points: [ChartPoint]
    let status: CalculatorResolver.RowStatus?

    var body: some View {
        if points.isEmpty {
            Text(note)
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 8) {
                ChartView(series: [ChartSeries(name: "", points: points)], kind: .line)
                    .frame(width: 120, height: 36)
                Text("\(points.count) pts")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var note: String {
        switch status {
        case .brokenRef: return "(unknown rows)"
        case .nonNumeric: return "(bad range)"
        default: return "(no data)"
        }
    }
}

// MARK: - Variable control

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

    static func unitPrefix(_ unit: String?) -> String? {
        guard let unit, ["$", "€", "£", "¥"].contains(unit) else { return nil }
        return unit
    }

    static func unitSuffix(_ unit: String?) -> String? {
        guard let unit = unit?.nonEmpty, unitPrefix(unit) == nil else { return nil }
        return unit == "%" ? "%" : " \(unit)"
    }
}
