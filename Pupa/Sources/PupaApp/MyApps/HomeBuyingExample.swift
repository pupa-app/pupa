import Foundation

/// Seeded "Example: Home Buying" MyApp.
///
/// Demonstrates the linked-field calculator: a tracker of candidate houses
/// feeding a mortgage model that pulls each input off ONE selected house via
/// `linkedField` rows. Swapping the linked house (tap a row's link pill, or
/// `setCalcRowLink`) re-runs every formula. A `linkedCompare` list row +
/// embedded bar chart compares the houses on their computed monthly payment.
///
/// - **`tracker-1` — Candidate Houses.** Kanban grouped by `status`; each row
///   carries the numeric fields the mortgage model needs (price, down
///   payment %, interest rate, term, property tax, HOA).
/// - **`calculator-1` — Mortgage Model.** Six `linkedField` rows (all seeded
///   to the first house) feed formula rows for the monthly P&I, total monthly
///   cost, and total interest. A `linkedCompare` row + bar chart compares
///   every house on total monthly cost.
enum HomeBuyingExample: ExampleMyApp {
    static let name = "Example: Home Buying"
    static let iconSystemName = "house"
    static let tagline = "Compare mortgages by linking houses into a live calculator — swap the house, the model updates"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore, appRootOverride: URL? = nil) {
        let appRoot = appRootOverride ?? MemoryStore.appRoot(myAppName: name)
        let appMemory = MemoryStore(rootOverride: appRoot)
        if !appMemory.fileExists(at: "AGENTS.md") {
            _ = try? appMemory.writeFile(path: "AGENTS.md", content: appAgentsMd)
            globalMemory.rescan()
        }
    }

    // MARK: - Builder

    private struct Builder {
        // House rows referenced by the calculator's linkedField + compare rows.
        let houseA = UUID()
        let houseB = UUID()
        let houseC = UUID()
        let houseD = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: iconSystemName,
                typeId: "tracker",
                components: [
                    housesTracker(),
                    mortgageCalculator(),
                ],
                activeComponentId: "calculator-1"
            )
        }

        /// Numeric truth for one house. Single source feeding both the
        /// tracker rows and the cumulative-cost line chart, so the two can
        /// never drift.
        struct HouseSpec {
            let id: UUID
            let name: String
            let price: Double
            let downPct: Double
            let ratePct: Double
            let termYears: Int
            let propertyTaxYr: Double
            let hoaMonthly: Double
            let status: String
        }

        var houseSpecs: [HouseSpec] {
            [
                HouseSpec(id: houseA, name: "Maple St bungalow", price: 520000, downPct: 20,
                          ratePct: 6.5, termYears: 30, propertyTaxYr: 6800, hoaMonthly: 0, status: "Toured"),
                HouseSpec(id: houseB, name: "Birch Ave condo", price: 445000, downPct: 10,
                          ratePct: 6.9, termYears: 30, propertyTaxYr: 5200, hoaMonthly: 250, status: "Considering"),
                HouseSpec(id: houseC, name: "Cedar Ct family home", price: 610000, downPct: 25,
                          ratePct: 6.2, termYears: 30, propertyTaxYr: 8100, hoaMonthly: 180, status: "Offer"),
                HouseSpec(id: houseD, name: "Dogwood Ln cottage", price: 389000, downPct: 15,
                          ratePct: 7.1, termYears: 15, propertyTaxYr: 4400, hoaMonthly: 0, status: "Considering"),
            ]
        }

        /// `20.0` → `"20"`, `6.5` → `"6.5"` — keeps the seeded tracker strings
        /// clean (no trailing `.0` on whole numbers).
        private func num(_ d: Double) -> String {
            d == d.rounded() ? String(Int(d)) : String(d)
        }

        // MARK: Houses tracker

        private func housesTracker() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "name", label: "House", type: .text),
                FieldDef(name: "price", label: "Price", type: .number),
                FieldDef(name: "down_payment_pct", label: "Down payment %", type: .number),
                FieldDef(name: "interest_rate", label: "Interest rate %", type: .number),
                FieldDef(name: "term_years", label: "Term (years)", type: .number),
                FieldDef(name: "property_tax", label: "Property tax (yr)", type: .number),
                FieldDef(name: "hoa", label: "HOA (mo)", type: .number),
                FieldDef(name: "status", label: "Status", type: .select,
                         options: ["Considering", "Toured", "Offer", "Rejected"]),
            ]
            let items: [TrackerItem] = houseSpecs.map { h in
                TrackerItem(id: h.id, values: [
                    "name": h.name,
                    "price": num(h.price),
                    "down_payment_pct": num(h.downPct),
                    "interest_rate": num(h.ratePct),
                    "term_years": String(h.termYears),
                    "property_tax": num(h.propertyTaxYr),
                    "hoa": num(h.hoaMonthly),
                    "status": h.status,
                ])
            }
            return Component(
                id: "tracker-1",
                name: "Candidate Houses",
                iconSystemName: "house",
                body: .tracker(TrackerData(
                    title: "Candidate Houses",
                    fields: fields,
                    items: items,
                    viewMode: .kanban,
                    columnField: "status"
                )),
                summary: "Houses under consideration with the numbers the mortgage model needs (price, down payment %, rate, term, tax, HOA). The Mortgage Model calculator links one of these rows at a time; swap the link to re-run the model for a different house."
            )
        }

        // MARK: Mortgage calculator

        /// Every linkedField row is seeded to the SAME house (`houseA`) so the
        /// `linkedCompare` row's "swap every row sharing the anchor ref" logic
        /// moves all six fields together when it compares houses.
        private func mortgageCalculator() -> Component {
            func linked(_ field: String) -> CalcRowKind {
                .linkedField(LinkedFieldSpec(ref: ComponentItemRef(componentId: "tracker-1", itemId: houseA), fieldName: field))
            }
            let rows: [CalcRow] = [
                CalcRow(key: "selected_house", name: "Selected house", kind: .header),
                CalcRow(key: "price", name: "Price", unit: "$", kind: linked("price")),
                CalcRow(key: "down_pct", name: "Down payment", unit: "%", kind: linked("down_payment_pct")),
                CalcRow(key: "rate_annual", name: "Interest rate", unit: "%", kind: linked("interest_rate")),
                CalcRow(key: "term_years", name: "Term", unit: "yr", kind: linked("term_years")),
                CalcRow(key: "prop_tax_annual", name: "Property tax (yr)", unit: "$", kind: linked("property_tax")),
                CalcRow(key: "hoa_monthly", name: "HOA (mo)", unit: "$", kind: linked("hoa")),

                CalcRow(key: "payment", name: "Payment", kind: .header),
                CalcRow(key: "principal", name: "Loan principal", unit: "$", format: "%.2f",
                        kind: .formula(expression: "price * (1 - down_pct / 100)")),
                CalcRow(key: "r", name: "Monthly rate",
                        kind: .formula(expression: "rate_annual / 100 / 12")),
                CalcRow(key: "n", name: "Payments",
                        kind: .formula(expression: "term_years * 12")),
                CalcRow(key: "pi", name: "Principal & interest / mo", unit: "$", format: "%.2f",
                        kind: .formula(expression: "principal * r * (1 + r)^n / ((1 + r)^n - 1)")),
                CalcRow(key: "monthly", name: "Total monthly cost", unit: "$", format: "%.2f",
                        kind: .formula(expression: "pi + prop_tax_annual / 12 + hoa_monthly")),
                CalcRow(key: "total_interest", name: "Total interest", unit: "$", format: "%.2f",
                        kind: .formula(expression: "pi * n - principal")),

                CalcRow(key: "compare", name: "Monthly cost by house",
                        kind: .list(.linkedCompare(
                            refs: [
                                ComponentItemRef(componentId: "tracker-1", itemId: houseA),
                                ComponentItemRef(componentId: "tracker-1", itemId: houseB),
                                ComponentItemRef(componentId: "tracker-1", itemId: houseC),
                                ComponentItemRef(componentId: "tracker-1", itemId: houseD),
                            ],
                            targetKey: "monthly",
                            linkedRowKey: "price"
                        ))),
            ]
            let chart = ChartData(
                title: "Monthly cost by house",
                kind: .bar,
                source: .calculatorList(componentId: "calculator-1", key: "compare")
            )
            return Component(
                id: "calculator-1",
                name: "Mortgage Model",
                iconSystemName: "function",
                body: .calculator(CalculatorData(
                    title: "Mortgage Model",
                    rows: rows,
                    inlineChart: chart,
                    extraCharts: [cumulativeCostChart()]
                )),
                summary: "Live mortgage model. The 'Selected house' rows pull each input off ONE linked house in Candidate Houses — tap a row's link pill (or use setCalcRowLink) to switch houses and re-run the payment formulas. The bar chart compares every linked house on total monthly cost. A second line chart projects cumulative cost over 30 years, one line per house."
            )
        }

        // MARK: Cumulative-cost line chart

        /// Projected total cash outlay by year, one `inline` line series per
        /// house: down payment up front, then monthly cost (P&I + tax/12 +
        /// HOA) accumulated month by month. P&I stops once a house's term is
        /// paid off, so a 15-year loan's line bends flatter past year 15.
        /// Seed-static (inline points) — illustrative, unlike the live bar
        /// chart above; edits to a house don't redraw it.
        private func cumulativeCostChart() -> ChartData {
            let series = houseSpecs.map { h in
                ChartSeriesSpec(name: h.name, source: .inline(points: cumulativeOutlay(h)))
            }
            return ChartData(
                title: "Cumulative cost over 30 years",
                kind: .line,
                series: series
            )
        }

        /// Standard fixed-rate amortization → cumulative spend at each year end.
        private func cumulativeOutlay(_ h: HouseSpec, years: Int = 30) -> [ChartPoint] {
            let principal = h.price * (1 - h.downPct / 100)
            let r = h.ratePct / 100 / 12
            let n = Double(h.termYears * 12)
            let pi: Double = r == 0 ? principal / n
                                    : principal * r * pow(1 + r, n) / (pow(1 + r, n) - 1)
            var cumulative = h.price * h.downPct / 100   // down payment up front
            var month = 0
            var points: [ChartPoint] = []
            for year in 1...years {
                for _ in 1...12 {
                    month += 1
                    let piThisMonth = Double(month) <= n ? pi : 0
                    cumulative += piThisMonth + h.propertyTaxYr / 12 + h.hoaMonthly
                }
                points.append(ChartPoint(label: "\(year)", x: Double(year),
                                         y: (cumulative * 100).rounded() / 100))
            }
            return points
        }
    }
}

// MARK: - AGENTS.md content

extension HomeBuyingExample {
    fileprivate static let appAgentsMd = """
        # Example: Home Buying

        A demo workspace for comparing mortgages. Shows the linked-field
        calculator: a tracker of houses driving a live mortgage model.

        ## Components

        - **Candidate Houses** (`tracker-1`) — kanban of houses grouped by
          `status`. Each row holds the numeric inputs the model needs.
        - **Mortgage Model** (`calculator-1`) — the "Selected house" rows are
          `linkedField` rows that pull one field each off a single linked
          house. The formula rows compute monthly P&I, total monthly cost, and
          total interest. The `compare` list row + bar chart compares every
          house on total monthly cost; a second line chart projects cumulative
          cost over 30 years, one line per house (seed-static — illustrative).

        ## How to use

        1. In the Mortgage Model, tap a "Selected house" row's link pill to
           pick which house the model runs for — every formula re-runs.
        2. Tune the houses in Candidate Houses; the model and chart update live.
        3. The bar chart compares the houses in the `compare` row's set.

        To swap the linked house from chat, call
        `setCalcRowLink(key, ref:{componentId, itemId})` on any linkedField row
        (they share one house, so update them together or via the picker).

        ## Anti-patterns

        - Don't point the linkedField rows at different houses — they must
          share one house so the comparison swaps all fields together.
        - Don't store computed payments in the tracker — the calculator
          resolves them live.
        """
}
