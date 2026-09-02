import Foundation

/// Seeded "Fashion Companion" MyApp.
///
/// Demonstrates personalised style learning: a wardrobe tracker becomes
/// the agent's knowledge base, a style inspiration board collects looks
/// to aspire to, a capsule-wardrobe checklist tracks intentional
/// shopping goals, and a multi-agent Style Room (Stylist / Trend Scout /
/// Personal Shopper) helps the user learn to dress well and discover new
/// pieces that complement what they already own.
enum FashionCompanionExample: ExampleMyApp {
    static let name = "Fashion Companion"
    static let iconSystemName = "hanger"
    static let tagline = "Wardrobe, inspiration board and a style room"

    static func make() -> MyApp {
        Builder().build()
    }

    @MainActor
    static func seedAgentsMd(globalMemory: MemoryStore?, appRoot: URL) {
        let appMemory = MemoryStore(rootOverride: appRoot)
        var wroteAny = false
        if !appMemory.fileExists(at: "pupa/AGENTS.md") {
            _ = try? appMemory.writeFile(path: "pupa/AGENTS.md", content: appAgentsMd)
            wroteAny = true
        }
        for (slug, body) in slackAgentDocs {
            let path = "pupa/agents/\(slug)/AGENTS.md"
            if !appMemory.fileExists(at: path) {
                _ = try? appMemory.writeFile(path: path, content: body)
                wroteAny = true
            }
        }
        if wroteAny { globalMemory?.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        // Wardrobe items referenced by inspiration board
        let itemWhiteShirt = UUID()
        let itemDarkJeans = UUID()
        let itemBlazer = UUID()
        let itemChinos = UUID()
        let itemWhiteSneakers = UUID()
        let itemLeatherBelt = UUID()
        let itemCashmereKnit = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "hanger",
                typeId: "tracker",
                components: [
                    wardrobeTracker(),
                    styleInspiration(),
                    capsuleChecklist(),
                    outfitCalendar(),
                    styleRoom(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        private func wardrobeTracker() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "item", label: "Item", type: .text),
                FieldDef(name: "category", label: "Category", type: .select,
                         options: ["Top", "Bottom", "Outerwear", "Knitwear", "Shoes", "Accessories", "Formal"]),
                FieldDef(name: "color", label: "Colour", type: .select,
                         options: ["White", "Black", "Navy", "Grey", "Beige", "Brown", "Blue", "Green", "Other"]),
                FieldDef(name: "season", label: "Season", type: .select,
                         options: ["All year", "Spring/Summer", "Autumn/Winter"]),
                FieldDef(name: "how_often", label: "Worn", type: .select,
                         options: ["Weekly", "Monthly", "Rarely", "Never"]),
                FieldDef(name: "brand", label: "Brand", type: .text),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: itemWhiteShirt, values: [
                    "item": "White Oxford shirt",
                    "category": "Top",
                    "color": "White",
                    "season": "All year",
                    "how_often": "Weekly",
                    "brand": "Uniqlo",
                    "notes": "The cornerstone piece. Works with everything.",
                ]),
                TrackerItem(id: itemDarkJeans, values: [
                    "item": "Dark indigo slim jeans",
                    "category": "Bottom",
                    "color": "Navy",
                    "season": "All year",
                    "how_often": "Weekly",
                    "brand": "Levi's 511",
                    "notes": "Smart-casual bridge — dressier than regular blue denim.",
                ]),
                TrackerItem(id: itemBlazer, values: [
                    "item": "Navy unstructured blazer",
                    "category": "Outerwear",
                    "color": "Navy",
                    "season": "All year",
                    "how_often": "Monthly",
                    "brand": "Sandro",
                    "notes": "Instantly elevates any casual outfit. Needs a lint roller.",
                ]),
                TrackerItem(id: itemChinos, values: [
                    "item": "Stone chinos",
                    "category": "Bottom",
                    "color": "Beige",
                    "season": "Spring/Summer",
                    "how_often": "Monthly",
                    "brand": "Reiss",
                    "notes": "Great summer alternative to jeans. Pair with white shirt or knit.",
                ]),
                TrackerItem(id: itemWhiteSneakers, values: [
                    "item": "White leather low-top sneakers",
                    "category": "Shoes",
                    "color": "White",
                    "season": "Spring/Summer",
                    "how_often": "Weekly",
                    "brand": "Common Projects",
                    "notes": "The most versatile shoe I own. Keep them clean.",
                ]),
                TrackerItem(id: itemLeatherBelt, values: [
                    "item": "Dark brown leather belt",
                    "category": "Accessories",
                    "color": "Brown",
                    "season": "All year",
                    "how_often": "Weekly",
                    "brand": "Anderson's",
                    "notes": "Match with brown shoes. Never mix black belt + brown shoes.",
                ]),
                TrackerItem(id: itemCashmereKnit, values: [
                    "item": "Mid-grey cashmere crewneck",
                    "category": "Knitwear",
                    "color": "Grey",
                    "season": "Autumn/Winter",
                    "how_often": "Weekly",
                    "brand": "John Smedley",
                    "notes": "Best over a shirt collar. Hand wash cold.",
                ]),
            ]
            return Component(
                id: "tracker-1",
                name: "My Wardrobe",
                iconSystemName: "tshirt",
                body: .tracker(TrackerData(title: "My Wardrobe", fields: fields, items: items)),
                summary: "Personal wardrobe inventory. The agent uses this as context for outfit suggestions and gap analysis — it knows what you own, what colours you have, and what you rarely reach for."
            )
        }

        private func styleInspiration() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "description", label: "Look / vibe", type: .text),
                FieldDef(name: "style", label: "Style", type: .select,
                         options: ["Smart casual", "Business casual", "Casual", "Formal", "Streetwear", "Minimalist", "Classic"]),
                FieldDef(name: "occasion", label: "Occasion", type: .select,
                         options: ["Work", "Weekend", "Evening out", "Date", "Travel", "Active"]),
                FieldDef(name: "source", label: "Inspiration source", type: .text),
                FieldDef(name: "replicable", label: "Can replicate with my wardrobe?", type: .select,
                         options: ["Yes", "Mostly", "Need one piece", "Not yet"]),
                FieldDef(name: "notes", label: "Notes", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(values: [
                    "description": "White shirt, dark jeans, white sneakers, no-show socks",
                    "style": "Smart casual",
                    "occasion": "Weekend",
                    "source": "Luca Faloni Instagram",
                    "replicable": "Yes",
                    "notes": "The baseline — clean and effortless. Shirt tucked half-in.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: itemWhiteShirt),
                        ComponentItemRef(componentId: "tracker-1", itemId: itemDarkJeans),
                        ComponentItemRef(componentId: "tracker-1", itemId: itemWhiteSneakers),
                    ]
                ),
                TrackerItem(values: [
                    "description": "Navy blazer over grey crewneck, stone chinos, white sneakers",
                    "style": "Smart casual",
                    "occasion": "Work",
                    "source": "He Spoke Style blog",
                    "replicable": "Yes",
                    "notes": "Office-ready without being formal. Works for client meetings.",
                    ],
                    linkedItems: [
                        ComponentItemRef(componentId: "tracker-1", itemId: itemBlazer),
                        ComponentItemRef(componentId: "tracker-1", itemId: itemCashmereKnit),
                        ComponentItemRef(componentId: "tracker-1", itemId: itemChinos),
                    ]
                ),
                TrackerItem(values: [
                    "description": "Tailored trousers + roll-neck + loafers",
                    "style": "Minimalist",
                    "occasion": "Evening out",
                    "source": "Personal Pinterest board",
                    "replicable": "Need one piece",
                    "notes": "Missing a good pair of tailored trousers and loafers. Gap to fill.",
                ]),
            ]
            return Component(
                id: "tracker-2",
                name: "Style Inspiration",
                iconSystemName: "sparkles",
                body: .tracker(TrackerData(title: "Style Inspiration", fields: fields, items: items)),
                summary: "Looks and outfits to aspire to, cross-linked to the wardrobe pieces that can replicate them. 'Need one piece' rows flag shopping priorities for @PersonalShopper."
            )
        }

        private func capsuleChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(text: "Tailored dark grey or navy trousers — fills the evening gap"),
                ChecklistItem(text: "Leather loafers (dark brown or tan) — versatile third shoe"),
                ChecklistItem(text: "Lightweight merino polo — summer alternative to shirts"),
                ChecklistItem(text: "Dark olive overshirt / shirt jacket — layering piece for autumn"),
                ChecklistItem(text: "Quality canvas tote bag — functional and clean"),
                ChecklistItem(text: "Classic watch with leather or NATO strap"),
            ]
            return Component(
                id: "checklist-1",
                name: "Capsule Goals",
                iconSystemName: "checklist",
                body: .checklist(ChecklistData(title: "Capsule Goals", items: items)),
                summary: "Intentional shopping list — pieces identified as gaps in the current wardrobe. The agent updates this based on Style Inspiration 'Need one piece' rows and @PersonalShopper suggestions."
            )
        }

        private func outfitCalendar() -> Component {
            let now = Date()
            func iso(_ daysFromNow: Int, hour: Int) -> String {
                let cal = Calendar(identifier: .gregorian)
                var comps = cal.dateComponents([.year, .month, .day], from: now)
                comps.day = (comps.day ?? 0) + daysFromNow
                comps.hour = hour; comps.minute = 0; comps.second = 0
                let date = cal.date(from: comps) ?? now
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
                return f.string(from: date)
            }
            let events: [CalendarEvent] = [
                CalendarEvent(
                    title: "Client presentation — plan outfit",
                    start: iso(2, hour: 9),
                    end: iso(2, hour: 9),
                    notes: "Smart casual, office-appropriate. Ask the agent to suggest a look from wardrobe + inspiration board."
                ),
                CalendarEvent(
                    title: "Weekend wardrobe review",
                    start: iso(5, hour: 10),
                    end: iso(5, hour: 10),
                    notes: "15 min review: identify 'never worn' items, update how_often fields, ask agent for a gap analysis."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Outfit Planner",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Outfit Planner", events: events)),
                summary: "Upcoming occasions that need outfit planning and periodic wardrobe review sessions."
            )
        }

        private func styleRoom() -> Component {
            // Agents are filesystem subagents seeded by `seedAgentsMd` at
            // `pupa/agents/<slug>/AGENTS.md`; the channel references them by slug.
            let general = SlackChannel(
                id: "general",
                name: "general",
                type: .channel,
                memberAgentIds: ["stylist", "trendscout", "shopper"]
            )
            return Component(
                id: "slack-1",
                name: "Style Room",
                iconSystemName: "bubble.left.and.bubble.right",
                body: .slack(SlackData(
                    channels: [general],
                    messagesByChannel: [:],
                    activeChannelId: general.id
                )),
                summary: "Three-agent style room. @Stylist puts outfits together from your wardrobe; @TrendScout researches current trends and seasonal looks; @PersonalShopper finds specific items to fill gaps."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension FashionCompanionExample {
    fileprivate static var slackAgentDocs: [(slug: String, content: String)] {
        [("stylist", stylistAgentsMd), ("trendscout", trendScoutAgentsMd), ("shopper", shopperAgentsMd)]
    }

    fileprivate static let stylistPersona = "You are a personal stylist. You build outfits from what the user already owns (read the Wardrobe tracker) and teach them why combinations work — proportion, colour harmony, occasion-appropriateness. Give specific outfit formulas, not generic advice. Your full AGENTS.md persona lives at example-fashion-companion/pupa/agents/stylist/AGENTS.md."

    fileprivate static let trendScoutPersona = "You research current fashion trends, seasonal colour palettes, and what styles are gaining or fading. When asked about trends, be specific — name the pieces, the silhouettes, the brands leading it. If tavily_search is available, use it for live lookups. Your full AGENTS.md persona lives at example-fashion-companion/pupa/agents/trendscout/AGENTS.md."

    fileprivate static let shopperPersona = "You analyse the user's wardrobe gaps and style goals, then suggest specific pieces to buy — with brand, approximate price, and why it fills the gap. Prioritise versatile 'cost-per-wear' pieces over trend-chasing. Read the Capsule Goals checklist and Style Inspiration 'Need one piece' rows before suggesting. Your full AGENTS.md persona lives at example-fashion-companion/pupa/agents/shopper/AGENTS.md."

    fileprivate static let appAgentsMd = """
        # Example: Fashion Companion

        A demo workspace for building a personal style intentionally. The agent
        uses your wardrobe inventory as its knowledge base and helps you get
        more out of what you own before suggesting what to buy.

        ## Components

        - **My Wardrobe** (`tracker-1`) — inventory of what you own: category,
          colour, season, how often it's worn. The agent reads this before
          suggesting outfits or gaps. "Never" rows are candidates for removal.
        - **Style Inspiration** (`tracker-2`) — looks you want to replicate,
          cross-linked to the wardrobe pieces that can do it. "Need one piece"
          rows flow into the Capsule Goals checklist.
        - **Capsule Goals** (`checklist-1`) — intentional shopping list. Only
          items that genuinely fill a gap, ranked by versatility. The agent
          updates this based on the inspiration board and @PersonalShopper.
        - **Outfit Planner** (`calendar-1`) — upcoming occasions needing a
          planned look, and periodic wardrobe review sessions.
        - **Style Room** (`slack-1`) — three agents: `@Stylist` for outfit
          formulas from your existing wardrobe, `@TrendScout` for current
          trends and seasonal looks, `@PersonalShopper` for specific items
          to fill gaps.

        ## How to use

        Getting an outfit for a specific occasion:

        1. Describe the occasion in chat ("I have a smart-casual dinner
           on Friday, what should I wear?").
        2. The agent reads your wardrobe and suggests a complete outfit,
           explaining why each piece works together.
        3. If you want more options, `@Stylist` in the Style Room for
           3–4 variants.
        4. If a piece is missing ("I don't have a good blazer"), ask
           `@PersonalShopper` for specific recommendations.

        Building your style over time:

        - After wearing an outfit you liked, tell the agent — it logs it
          as an inspiration row.
        - After trying something that didn't work, note it in chat — the
          agent records what to avoid for your body type / lifestyle.
        - Every few weeks, do a wardrobe review: ask the agent to identify
          "never worn" items, flag gaps, and update the Capsule Goals list.

        ## Agent behaviour

        - The agent reads the Wardrobe tracker before every suggestion —
          it works with what you own, not an idealised version.
        - Style preferences and what works for your lifestyle are stored in
          memory. Tell the agent once ("I work in a creative office, smart
          casual is the baseline") and it applies this every session.
        - The agent teaches you the *why* behind style choices — proportion,
          colour harmony, occasion signals — so you build your own judgment,
          not dependence on the agent.
        """

    fileprivate static let stylistAgentsMd = """
        # Stylist

        **Role:** Personal stylist

        ## Persona

        You help the user build outfits from what they already own. You teach
        the principles behind why outfits work — proportion, colour harmony,
        occasion-appropriateness — so the user develops their own taste.

        ## How you work

        - Before suggesting an outfit, read the Wardrobe tracker to see what
          the user owns. Suggest complete looks, not individual pieces.
        - For each outfit, briefly explain the logic: why this colour
          combination works, what the silhouette does, why it fits the
          occasion. One sentence per principle — don't lecture.
        - Give 2–3 outfit options when asked, ranging from safe to more
          interesting. Name the pieces from the wardrobe tracker by their
          `item` field.
        - Flag easy wins: "your grey knit works better here than the blazer
          because the occasion is casual."
        - When the user shares a photo of a look they like, identify the
          key pieces and check whether the wardrobe has equivalents.

        ## What you don't do

        - You don't recommend things to buy — that's `@PersonalShopper`.
        - You don't research trends — that's `@TrendScout`.
        - You don't tell the user their existing clothes are wrong without
          explaining why and offering a fix.
        """

    fileprivate static let trendScoutAgentsMd = """
        # TrendScout

        **Role:** Style trend researcher

        ## Persona

        You stay current on what's happening in menswear and womenswear —
        seasonal colour palettes, silhouette shifts, what's gaining momentum
        and what's fading. You translate trends into actionable, specific
        guidance rather than vague "oversized is in" non-advice.

        ## How you work

        - When asked about a trend, be specific: name the pieces, the
          silhouettes, the brands leading it, and the price tier. Give 3–4
          concrete examples, not a wall of adjectives.
        - Distinguish between micro-trends (6–12 months) and macro shifts
          (3–5 years). Flag which is which so the user can decide how much
          to invest.
        - If `tavily_search` is available, use it to pull recent editorial
          coverage, runway summaries, or street-style reports. Always note
          the source.
        - Connect trends to the user's existing wardrobe when possible:
          "the quiet luxury wave suits what you already own — your grey
          knit and dark jeans are exactly the aesthetic."

        ## What you don't do

        - You don't recommend specific products to buy — that's
          `@PersonalShopper`.
        - You don't build outfits from the wardrobe — that's `@Stylist`.
        - You don't push the user to follow trends they find unappealing.
          Your job is information, not persuasion.
        """

    fileprivate static let shopperAgentsMd = """
        # PersonalShopper

        **Role:** Wardrobe gap analyst and smart shopper

        ## Persona

        You find the specific pieces that fill real gaps in the user's
        wardrobe — prioritising versatility and cost-per-wear over trend
        chasing.

        ## How you work

        - Before suggesting anything, read:
          - Wardrobe tracker — what they own, what they wear rarely.
          - Capsule Goals checklist — what they've identified as missing.
          - Style Inspiration "Need one piece" rows — what's blocking a
            look they want to replicate.
        - For each suggestion, give: item name, brand, approximate price
          range, and *why* it fills a gap (1 sentence — make it specific).
        - Suggest 2–3 options at different price points where possible
          (budget / mid / investment). Never suggest only the expensive
          option.
        - Ask about the user's budget before making recommendations if they
          haven't volunteered it.
        - If `tavily_search` is available, use it to find current stock or
          verify availability.

        ## What you don't do

        - You don't push quantity. One great versatile piece beats three
          mediocre trend pieces.
        - You don't suggest items that duplicate something they already
          own well.
        - You don't build outfits — that's `@Stylist`.
        - You don't speculate about trends — that's `@TrendScout`.
        """
}
