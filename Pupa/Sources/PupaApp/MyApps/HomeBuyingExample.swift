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
                iconSystemName: "house.lodge",
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
            let allRefs = [houseA, houseB, houseC, houseD].map {
                ComponentItemRef(componentId: "tracker-1", itemId: $0)
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
                CalcRow(key: "down_amount", name: "Down payment", unit: "$", format: "%.2f",
                        kind: .formula(expression: "price * down_pct / 100")),
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

                // Global assumptions driving the projection charts. Drag a
                // slider → every curve below redraws live.
                CalcRow(key: "assumptions", name: "Assumptions", kind: .header),
                CalcRow(key: "appreciation_pct", name: "Home appreciation / yr", unit: "%",
                        kind: .variable(value: 3, control: .slider(min: 0, max: 10, step: 0.5))),
                CalcRow(key: "rent_monthly", name: "Rent if not buying", unit: "$",
                        kind: .variable(value: 2500, control: .slider(min: 500, max: 8000, step: 100))),
                CalcRow(key: "invest_return_pct", name: "Investment return / yr", unit: "%",
                        kind: .variable(value: 7, control: .slider(min: 1, max: 15, step: 0.5))),
                CalcRow(key: "year", name: "Projection year", unit: "yr",
                        kind: .variable(value: 15, control: .slider(min: 1, max: 30, step: 1))),

                // --- Apples-to-apples wealth comparison ---
                // Both paths deploy the SAME money: the buyer's down payment +
                // monthly housing cost. So both curves start at the down
                // payment and diverge only by appreciation vs. market return —
                // the standard "rent vs. buy" net-worth comparison.
                //
                // OWN: net worth = home equity = home value − loan still owed.
                CalcRow(key: "months_paid", name: "Months paid by year",
                        kind: .formula(expression: "min(year * 12, n)")),
                CalcRow(key: "home_value", name: "Home value by year", unit: "$", format: "%.2f",
                        kind: .formula(expression: "price * (1 + appreciation_pct / 100)^year")),
                CalcRow(key: "loan_balance", name: "Loan still owed", unit: "$", format: "%.2f",
                        kind: .formula(expression: "principal * ((1 + r)^n - (1 + r)^months_paid) / ((1 + r)^n - 1)")),
                CalcRow(key: "own_wealth", name: "Net worth if owning", unit: "$", format: "%.2f",
                        kind: .formula(expression: "home_value - loan_balance")),
                // RENT: net worth = invest the down payment + invest each
                // month's surplus (owning cost − rent) at the market return.
                CalcRow(key: "monthly_surplus", name: "Monthly surplus invested", unit: "$", format: "%.2f",
                        kind: .formula(expression: "max(monthly - rent_monthly, 0)")),
                CalcRow(key: "rent_wealth", name: "Net worth if renting", unit: "$", format: "%.2f",
                        kind: .formula(expression: "down_amount * (1 + invest_return_pct / 100 / 12)^(year * 12) + monthly_surplus * (((1 + invest_return_pct / 100 / 12)^(year * 12) - 1) / (invest_return_pct / 100 / 12))")),

                CalcRow(key: "compare", name: "Monthly cost by house",
                        kind: .list(.linkedCompare(
                            refs: allRefs,
                            targetKey: "monthly",
                            linkedRowKey: "price"
                        ))),
                // Selected-house wealth curves (Buy vs. Rent chart).
                CalcRow(key: "own_wealth_curve", name: "Own — net worth over time",
                        kind: .list(.sweep(variableKey: "year", from: 1, to: 30, step: 1, targetKey: "own_wealth"))),
                CalcRow(key: "rent_wealth_curve", name: "Rent — net worth over time",
                        kind: .list(.sweep(variableKey: "year", from: 1, to: 30, step: 1, targetKey: "rent_wealth"))),
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
                    extraCharts: [buyVsRentChart()]
                )),
                summary: "Live mortgage model for ONE house at a time. Pick the house from the dropdown at the top of the calculator — every 'Selected house' input repoints together and the formulas re-run. The Assumptions sliders (appreciation, rent, investment return, projection year) drive a live Buy-vs-Rent net-worth comparison: both paths deploy the same money, so owning (home equity) and renting (down payment + monthly surplus invested) start equal and diverge by appreciation vs. market return. The bar chart compares all candidate houses on monthly cost. Edit a house or drag a slider and the curves redraw."
            )
        }

        // MARK: Projection charts (live)

        /// Buy vs. rent for the SELECTED house, as the standard apples-to-apples
        /// NET-WORTH comparison: owning (home value − loan owed) vs. renting
        /// (down payment + monthly surplus invested at the market return). Both
        /// start at the down payment, so the lines are directly comparable and
        /// cross when one strategy overtakes the other. Two live sweep curves.
        private func buyVsRentChart() -> ChartData {
            ChartData(
                title: "Buy vs. rent — net worth over time",
                kind: .line,
                series: [
                    ChartSeriesSpec(name: "Own (home equity)",
                                    source: .calculatorList(componentId: "calculator-1", key: "own_wealth_curve")),
                    ChartSeriesSpec(name: "Rent + invest",
                                    source: .calculatorList(componentId: "calculator-1", key: "rent_wealth_curve")),
                ]
            )
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
          `linkedField` rows pulling one field each off ONE house, all bound
          together via the dropdown at the top of the calculator. The formula
          rows compute monthly P&I, total monthly cost, and total interest. The
          Assumptions sliders (appreciation, rent, investment return, projection
          year) feed a live Buy-vs-Rent net-worth chart for the selected house
          (two `sweep` curves: owning = home equity, renting = down payment +
          monthly surplus invested — both start at the down payment so they're
          directly comparable). The `compare` list row + bar chart compares every
          house on monthly cost.

        ## How to use

        1. In the Mortgage Model, use the source dropdown at the top to pick
           which house the model runs for — every input repoints and the
           formulas re-run.
        2. Tune the houses in Candidate Houses; the model and charts update live.
        3. Drag an Assumptions slider — the Buy-vs-Rent curves redraw.
        4. The bar chart compares all candidate houses on monthly cost.

        To swap the house from chat, call `setCalcRowLink(key, ref:{componentId,
        itemId})` on every linkedField row (or just repoint them all to the same
        house — the dropdown does this in one tap).

        ## Anti-patterns

        - Don't point the linkedField rows at different houses — they must
          share one house so the model is coherent (the dropdown enforces this).
        - Don't store computed payments in the tracker — the calculator
          resolves them live.
        """
}
