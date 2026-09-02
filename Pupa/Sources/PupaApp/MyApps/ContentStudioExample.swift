import Foundation

/// Seeded "Content Studio" MyApp.
///
/// Demonstrates a personal editorial pipeline: ideas flow through a
/// kanban from Idea → Published, a Publish Checklist keeps quality
/// consistent, a Publishing Calendar shows upcoming deadlines, and a
/// multi-agent Studio Room (Researcher / Editor / Ideator) helps produce
/// content. Showcases kanban view mode + local notifications as
/// publish-day reminders.
enum ContentStudioExample: ExampleMyApp {
    static let name = "Content Studio"
    static let iconSystemName = "square.and.pencil"
    static let tagline = "An editorial pipeline from idea to published"

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
        // Self-provisioning setup *skill* + reel build recipe. The skill exists
        // simply by living in `pupa/skills/setup/`, which makes `/setup`
        // available; the agent loads it (and the recipe on a reel request),
        // then writes the embedded scripts onto the backend host via the shell
        // tool — no backend code ships them.
        for (path, body) in [
            ("pupa/skills/setup/SKILL.md", setupSkillMd),
            ("reels/RECIPE.md", reelsRecipeMd),
        ] {
            if !appMemory.fileExists(at: path) {
                _ = try? appMemory.writeFile(path: path, content: body)
                wroteAny = true
            }
        }
        if wroteAny { globalMemory?.rescan() }
    }

    // MARK: - Builder

    private struct Builder {
        let itemAIAgents = UUID()
        let itemRemoteWork = UUID()
        let itemProductivity = UUID()
        let itemDeepWork = UUID()

        func build() -> MyApp {
            MyApp(
                name: name,
                iconSystemName: "square.and.pencil",
                typeId: "tracker",
                components: [
                    contentPipeline(),
                    publishChecklist(),
                    publishingCalendar(),
                    studioRoom(),
                ],
                activeComponentId: "tracker-1"
            )
        }

        private func contentPipeline() -> Component {
            let fields: [FieldDef] = [
                FieldDef(name: "title", label: "Title / working headline", type: .text),
                FieldDef(name: "format", label: "Format", type: .select,
                         options: ["Thread", "Long post", "Newsletter", "Short video", "Article"]),
                FieldDef(name: "platform", label: "Platform", type: .select,
                         options: ["LinkedIn", "Twitter / X", "Substack", "YouTube", "Blog"]),
                FieldDef(name: "stage", label: "Stage", type: .select,
                         options: ["Idea", "Research", "Draft", "Review", "Scheduled", "Published"]),
                FieldDef(name: "publish_date", label: "Publish date", type: .text),
                FieldDef(name: "notes", label: "Notes / angle", type: .text),
            ]
            let items: [TrackerItem] = [
                TrackerItem(id: itemAIAgents, values: [
                    "title": "How I use AI agents to double my content output",
                    "format": "Thread",
                    "platform": "Twitter / X",
                    "stage": "Draft",
                    "publish_date": "This Thursday",
                    "notes": "Personal workflow — show before/after time breakdown. @Researcher to pull stats on AI tool adoption.",
                ]),
                TrackerItem(id: itemRemoteWork, values: [
                    "title": "5 remote-work habits that actually stuck after 3 years",
                    "format": "Long post",
                    "platform": "LinkedIn",
                    "stage": "Review",
                    "publish_date": "Monday",
                    "notes": "Draw from personal experience. Strong hook needed — @Editor review.",
                ]),
                TrackerItem(id: itemProductivity, values: [
                    "title": "The productivity tool graveyard",
                    "format": "Newsletter",
                    "platform": "Substack",
                    "stage": "Idea",
                    "publish_date": "",
                    "notes": "Tools I tried and abandoned and why. Self-deprecating angle works well for this audience.",
                ]),
                TrackerItem(id: itemDeepWork, values: [
                    "title": "Deep work is dead — and that's okay",
                    "format": "Article",
                    "platform": "Blog",
                    "stage": "Research",
                    "publish_date": "Next week",
                    "notes": "Counter-narrative piece. @Researcher pull recent data on attention spans + Cal Newport rebuttals.",
                ]),
            ]
            var data = TrackerData(title: "Content Pipeline", fields: fields, items: items)
            data.viewMode = .kanban
            data.columnField = "stage"
            return Component(
                id: "tracker-1",
                name: "Content Pipeline",
                iconSystemName: "rectangle.stack",
                body: .tracker(data),
                summary: "Editorial kanban. Columns are stages (Idea → Published). Each card carries format, platform, publish date, and a notes/angle field. @Researcher is the go-to for research; @Editor reviews before scheduling."
            )
        }

        private func publishChecklist() -> Component {
            let items: [ChecklistItem] = [
                ChecklistItem(text: "Headline passes the 'would I click this?' test"),
                ChecklistItem(text: "Opening hook lands in ≤ 2 sentences"),
                ChecklistItem(text: "CTA is clear and placed at the end"),
                ChecklistItem(text: "Images / graphics attached and correctly sized"),
                ChecklistItem(text: "Links checked — no broken or placeholder URLs"),
                ChecklistItem(text: "Hashtags / tags reviewed for relevance"),
                ChecklistItem(text: "Scheduled in publishing tool (Buffer / Later / native)"),
                ChecklistItem(text: "Notification set for day-of reminder"),
            ]
            return Component(
                id: "checklist-1",
                name: "Publish Checklist",
                iconSystemName: "checklist",
                body: .checklist(ChecklistData(title: "Publish Checklist", items: items)),
                summary: "Reusable pre-publish review. Tick each item before a piece goes live. Reset between pieces."
            )
        }

        private func publishingCalendar() -> Component {
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
                    title: "Publish — Remote work habits (LinkedIn)",
                    start: iso(1, hour: 9),
                    end: iso(1, hour: 9),
                    notes: "Monday morning slot — peak LinkedIn engagement. Final check before posting.",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemRemoteWork)]
                ),
                CalendarEvent(
                    title: "Publish — AI agents thread (Twitter/X)",
                    start: iso(3, hour: 8),
                    end: iso(3, hour: 8),
                    notes: "Thursday 8am — best engagement window for tech threads.",
                    linkedItems: [ComponentItemRef(componentId: "tracker-1", itemId: itemAIAgents)]
                ),
                CalendarEvent(
                    title: "Content planning session",
                    start: iso(7, hour: 10),
                    end: iso(7, hour: 11),
                    notes: "Weekly planning: review pipeline, pick next Idea to move to Research, brainstorm with @Ideator."
                ),
            ]
            return Component(
                id: "calendar-1",
                name: "Publishing Calendar",
                iconSystemName: "calendar",
                body: .calendar(CalendarData(title: "Publishing Calendar", events: events)),
                summary: "Scheduled publish slots and planning sessions. Calendar events are cross-linked to the pipeline items they correspond to."
            )
        }

        private func studioRoom() -> Component {
            // Agents are filesystem subagents seeded by `seedAgentsMd` at
            // `pupa/agents/<slug>/AGENTS.md`; the channel references them by slug.
            let general = SlackChannel(
                id: "general",
                name: "general",
                type: .channel,
                memberAgentIds: ["researcher", "editor", "ideator"]
            )
            return Component(
                id: "slack-1",
                name: "Studio Room",
                iconSystemName: "bubble.left.and.bubble.right",
                body: .slack(SlackData(
                    channels: [general],
                    messagesByChannel: [:],
                    activeChannelId: general.id
                )),
                summary: "Multi-agent editorial room. @Researcher fetches live facts and data; @Editor tightens structure, hooks, and CTAs; @Ideator brainstorms fresh angles and formats."
            )
        }
    }
}

// MARK: - AGENTS.md content

extension ContentStudioExample {
    fileprivate static var slackAgentDocs: [(slug: String, content: String)] {
        [("researcher", researcherAgentsMd), ("editor", editorAgentsMd), ("ideator", ideatorAgentsMd)]
    }

    fileprivate static let researcherPersona = "You research facts, data, and context to support content creation. When asked about a topic, pull statistics, recent trends, counter-narratives, and notable voices worth citing. If tavily_search is available, use it for live web lookups. Be specific — point at concrete data, not vague advice to 'do more research'. Your full AGENTS.md persona lives at example-content-studio/pupa/agents/researcher/AGENTS.md."

    fileprivate static let editorPersona = "You are an editorial coach who reviews content for clarity, structure, and impact. When shown a draft, assess the hook, body flow, and CTA. Give line-level feedback — rewrite weak sentences directly, don't just describe what's wrong. Push for specificity and remove filler. Your full AGENTS.md persona lives at example-content-studio/pupa/agents/editor/AGENTS.md."

    fileprivate static let ideatorPersona = "You generate creative angles, formats, and content ideas. When given a topic, suggest 3–5 distinct angles — contrarian, personal story, listicle, data-driven, Q&A — with a one-line hook for each. Think about what would make someone stop scrolling. Your full AGENTS.md persona lives at example-content-studio/pupa/agents/ideator/AGENTS.md."

    fileprivate static let appAgentsMd = """
        # Example: Content Studio

        A demo workspace for managing a personal content pipeline. Chat with
        the agent to move content through stages, schedule pieces, and work
        with the studio agents on research, editing, and ideation.

        ## Components

        - **Content Pipeline** (`tracker-1`) — kanban board. Each card is a
          piece of content with format, platform, stage (Idea → Published),
          publish date, and notes. Move cards by asking the agent to change
          the stage field.
        - **Publish Checklist** (`checklist-1`) — reusable pre-publish review.
          Reset it between pieces; the agent can tick items as you work through
          them together.
        - **Publishing Calendar** (`calendar-1`) — scheduled publish slots and
          planning sessions. Events are cross-linked to pipeline cards so you
          can navigate from calendar → content card in one tap.
        - **Studio Room** (`slack-1`) — three-agent room. Use `@Researcher`
          for live data and facts, `@Editor` for line-level draft feedback, and
          `@Ideator` to brainstorm fresh angles.

        ## How to use

        Moving a piece from idea to published:

        1. Ask the agent to add a new idea to the Content Pipeline. Describe
           the topic and platform — the agent picks format and stage.
        2. Go to Studio Room, `@Ideator` for 3–5 angle variants; pick one and
           ask the agent to update the pipeline card's notes field.
        3. `@Researcher` for facts and data to back up the angle.
        4. Draft the piece. When ready, paste the draft into chat and ask
           `@Editor` to review. Iterate.
        5. Ask the agent to move the card to "Scheduled" and add a calendar
           event with a publish-day notification.
        6. On publish day, run through the Publish Checklist together, then
           move the card to "Published".

        ## Tips

        - Notifications: ask the agent to "remind me an hour before each
          publish slot" — it will call `sendNotification` for each calendar
          event linked to a scheduled card.
        - Memory: tell the agent your brand voice, target audience, and
          content pillars once — it will write them to memory and apply them
          every session.

        ## First-time setup

        This workspace can produce **short-video reels** (the faceless
        TikTok/Reels format), but the backend needs provisioning first:
        ffmpeg, a voiceover provider, and a synced output folder.

        Run `/setup` (or just say "let's set up") — the agent follows the
        **setup** skill and walks the steps. It runs
        each backend command through the shell-approval card, or, if the shell
        tool is off, tells you exactly what to run. You only need to do this
        once per backend.

        ## Making a reel

        For a `Short video` card in the Content Pipeline, ask the agent to
        "make the reel". It follows `reels/RECIPE.md` in memory: builds the
        slides, voiceover, and captions, assembles the mp4 with ffmpeg, and
        drops the finished file into the synced output folder agreed at setup
        (so it lands in your Google Drive / Dropbox automatically). Iterate by
        asking for script, pacing, or caption tweaks.
        """

    fileprivate static let researcherAgentsMd = """
        # Researcher

        **Role:** Content researcher

        ## Persona

        You find the facts, data, and context that make content credible and
        specific. Your job is to give the creator concrete material — not to
        write the content itself.

        ## How you work

        - When asked about a topic, surface: recent statistics, counter-
          narratives, notable practitioners worth citing, and anything
          surprising that would make a reader stop scrolling.
        - If `tavily_search` is available, use it to pull live data. Prefer
          recent sources (< 12 months). Always note the source so the creator
          can link or attribute.
        - Look at the Content Pipeline tracker for context about the piece's
          angle before you start researching — the notes field often tells you
          what kind of data is needed.
        - Give 3–5 concrete data points, not a wall of text. Quality over
          quantity.

        ## What you don't do

        - You don't write the content — that's the creator's voice.
        - You don't give style or structure advice — that's `@Editor`.
        - You don't speculate without noting it as speculation.
        """

    fileprivate static let editorAgentsMd = """
        # Editor

        **Role:** Editorial coach

        ## Persona

        You review content for clarity, structure, and impact. You give direct,
        specific feedback — rewriting weak sentences rather than describing
        what's wrong with them.

        ## How you work

        - **Hook first.** Does the opening sentence make you want to keep
          reading? If not, rewrite it — show the creator 2–3 alternatives.
        - **Structure.** Does the piece flow? Where does the reader's attention
          drop? Name the paragraph, not just "it loses momentum".
        - **CTA.** Is there one? Is it clear? Is it placed where it'll be seen?
        - **Specificity.** Flag vague sentences ("this is important",
          "many people") and ask for the specific fact or story behind them.
        - **Trim.** Identify the 20% that could be cut without losing meaning.

        ## What you don't do

        - You don't research or add new content — that's `@Researcher`.
        - You don't generate new ideas — that's `@Ideator`.
        - You don't flatten the creator's voice to generic corporate copy.
        """

    fileprivate static let ideatorAgentsMd = """
        # Ideator

        **Role:** Creative angle generator

        ## Persona

        You help find the angle that will make a piece of content stand out.
        You think in hooks, contrasts, and surprising framings.

        ## How you work

        - When given a topic, suggest 3–5 distinct angles:
          - **Contrarian** — argue the opposite of the conventional wisdom.
          - **Personal story** — what's the creator's lived experience here?
          - **Data-first** — lead with a surprising statistic.
          - **Listicle** — structured, scannable, shareable.
          - **Q&A / myth-bust** — address the question everyone is afraid to ask.
        - For each angle, write a one-line hook — the first sentence that would
          stop someone scrolling.
        - Ask about the platform and audience before suggesting — a LinkedIn
          angle is different from a Twitter thread angle.

        ## What you don't do

        - You don't write the full piece — you hand off to the creator.
        - You don't critique drafts — that's `@Editor`.
        - You don't research the facts behind the ideas — that's `@Researcher`.
        """

    // Raw strings (flush-left content) so the embedded python/bash keeps its
    // exact whitespace and backslashes. The agent reads these from memory and
    // writes them onto the backend host via the shell tool during `/setup`.
    fileprivate static let setupSkillMd = #"""
---
description: Provision this backend to build short-video reels (one-time setup)
when_to_use: when the user runs /setup or asks to set up reels / the backend
---
# Reels backend setup

Goal: make this backend able to build short-video reels
and drop the finished mp4 into a cloud-synced folder. Do each step with the
`shell` tool, showing me the command first (the approval card). If the shell
tool is disabled, print the command and ask me to run it myself.

## 0. Prereqs
Reels need a self-hosted backend on the user's own Mac — the `shell` tool is
pinned off in the cloud image. If `shell` is unavailable, explain that and stop.

## 1. ffmpeg + Pillow
- `ffmpeg -version` — if missing: `brew install ffmpeg`.
- Caption support: `ffmpeg -hide_banner -filters | grep -E 'drawtext|subtitles'`.
  If EMPTY (typical on stock homebrew GPL builds), captions are baked with
  Pillow — the recipe already does this. Do NOT use `drawtext`/`subtitles=.ass`.
- `python3 -c 'import PIL' || pip3 install pillow` (a venv is fine too).

## 2. Voiceover MCP (ElevenLabs)
- Add it (key stays an env placeholder — never inline a key):
  `pupa-backend mcp add --name elevenlabs --command uvx --arg elevenlabs-mcp --env ELEVENLABS_API_KEY='${ELEVENLABS_API_KEY}' --description "Text-to-speech voiceover — writes an audio file." --force`
- Tell the user: `export ELEVENLABS_API_KEY=...` in the backend shell, then
  restart the backend (config.yml is read at startup — no hot-reload).
- No key? Fall back to macOS `say -v Samantha` for placeholder voiceover.
- Optional: add an image MCP (Pexels/fal) the same way; otherwise the user's
  own images / thumbnails work directly.

## 3. Synced output folder (the agreed drive drop)
- Probe, in order:
  - `ls -d ~/Library/CloudStorage/GoogleDrive-* 2>/dev/null`
  - `ls -d ~/Dropbox 2>/dev/null`
  - `ls -d ~/'Google Drive' 2>/dev/null`
- Create `PupaReels` inside the first match: `mkdir -p "<match>/PupaReels"`.
  If none is found, ask the user for their Drive/Dropbox path, or fall back to
  `~/PupaReels`.
- Report the chosen absolute path and save it to memory as `reels/OUTPUT.md` —
  every finished reel is copied there.

## 4. Install the build recipe as a backend skill
- `mkdir -p ~/.pupa-backend/skills/reels`
- Read `reels/RECIPE.md` from this app's memory and write its embedded files
  onto the backend via shell heredocs (`cat > <path> <<'EOF' … EOF`):
  - recipe body → `~/.pupa-backend/skills/reels/SKILL.md` (prepend the
    `name: reels` frontmatter shown in RECIPE.md)
  - `make_slides.py`, `make_captions.py`, `build_v3.sh` →
    `~/.pupa-backend/skills/reels/`
- A NEW chat session will then surface a `reels` skill the agent can `skill_view`.

## 5. Verify
- `pupa-backend mcp list` shows `elevenlabs`.
- `ls ~/.pupa-backend/skills/reels` shows SKILL.md + the three scripts.
- `ffmpeg -version` works.
Tell the user setup is done, where reels will be saved, and that a fresh session
is needed for the `reels` skill to appear.
"""#

    fileprivate static let reelsRecipeMd = #"""
# Reels build recipe

Build recipe for vertical short-video reels (1080x1920, 9:16). When installed
as a backend skill it lives at `~/.pupa-backend/skills/reels/SKILL.md`. Prepend
this frontmatter when writing SKILL.md:

```
---
name: reels
description: Build a vertical 1080x1920 short-video reel from images + text + voiceover with ffmpeg (Ken Burns, crossfades, baked captions, synced VO). Use when the user asks to make a reel, short video, or TikTok/Reels-style clip.
---
```

## Pipeline
idea → per-slide script → one image per slide (own / stock MCP / AI MCP / game
thumbnail) → per-slide voiceover (ElevenLabs or `say`) → Pillow bakes the slides
and caption PNGs → ffmpeg assembles → `cp` to the synced output folder.

## Hard-won rules (do NOT skip)
- **No `drawtext`/libass** on stock homebrew ffmpeg. Bake text with Pillow
  (`make_slides.py` for titles, `make_captions.py` for caption overlays) and
  `overlay` the PNGs. Never use `subtitles=.ass`.
- **zoompan**: feed a SINGLE image (no `-loop 1 -t N`) and set `d=<frames>` +
  `fps=30`. `-loop 1 -t` multiplies output frames per input frame and explodes
  the file (hundreds of seconds, huge size).
- **Audio sync**: one VO per slide; `ffprobe` each VO and set that slide's
  length to its own VO length (+ pads). Don't stretch one long VO over equal
  slides.
- **Crossfades eat speech**: wrap each VO in lead/tail silence ≥ the xfade
  duration (`adelay` + `apad`), so `xfade`/`acrossfade` overlap silence, not
  words.
- **Black-video fix**: JPEG sources make ffmpeg emit full-range `yuvj420p`,
  which QuickTime/QuickLook render BLACK. Always finish with
  `scale=in_range=full:out_range=tv,format=yuv420p` + `-color_range tv` +
  `-movflags +faststart`.
- **Loudness**: `loudnorm I=-14:TP=-1.5:LRA=11` for social.

## Per-reel steps
1. Write a tight script — one short, natural line per slide; vary the openers;
   say the topic name once. ElevenLabs voice, or `say -v Samantha -r 168`.
2. Gather one image per slide.
3. Adapt the `games` / `slides` / script arrays in the three scripts to this
   reel, then run:
   `python3 make_slides.py && python3 make_captions.py && bash build_v3.sh`
4. `cp reel_v3.mp4 "<output folder>/<slug>.mp4"` (path from `reels/OUTPUT.md`);
   report it — it syncs to Drive/Dropbox. Verify it plays and `ffprobe` shows
   `pix_fmt=yuv420p`, `color_range=tv`.

The three scripts below are a COMPLETE working example (a "top Roblox games"
reel). The `games` / `slides` / caption arrays are the parts to edit per topic.

### make_slides.py
```python
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1080, 1920
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FONT_REG = "/System/Library/Fonts/Supplemental/Arial.ttf"

title_font = ImageFont.truetype(FONT_BOLD, 96)
sub_font = ImageFont.truetype(FONT_REG, 50)
badge_font = ImageFont.truetype(FONT_BOLD, 130)
intro_font = ImageFont.truetype(FONT_BOLD, 120)

# game slides: (out, thumb, badge, title, sub)
games = [
    ("slide0.jpg", "game_garden.jpg", "#1", "GROW A GARDEN", "Roblox's farming hit"),
    ("slide1.jpg", "game_blox.jpg",   "#2", "BLOX FRUITS",   "Top action RPG"),
    ("slide2.jpg", "game_brook.jpg",  "#3", "BROOKHAVEN",    "Roleplay favorite"),
    ("slide3.jpg", "game_adopt.jpg",  "#4", "ADOPT ME!",     "Pet sim classic"),
]


def cover(img, w, h):
    sr, dr = img.width / img.height, w / h
    if sr > dr:
        nw, nh = int(h * sr), h
    else:
        nw, nh = w, int(w / sr)
    img = img.resize((nw, nh), Image.LANCZOS)
    l, t = (nw - w) // 2, (nh - h) // 2
    return img.crop((l, t, l + w, t + h))


def centered(draw, text, font, y, fill="white", stroke=5):
    b = draw.textbbox((0, 0), text, font=font, stroke_width=stroke)
    draw.text(((W - (b[2] - b[0])) / 2 - b[0], y), text, font=font,
              fill=fill, stroke_width=stroke, stroke_fill="black")


for out, thumb, badge, title, sub in games:
    src = Image.open(thumb).convert("RGB")

    # blurred + darkened fill background from the same art
    bg = cover(src, W, H).filter(ImageFilter.GaussianBlur(40))
    bg = Image.blend(bg, Image.new("RGB", (W, H), "black"), 0.5)

    # sharp thumbnail card, full width, centered upper
    cw = W - 120
    ch = int(cw * src.height / src.width)
    card = src.resize((cw, ch), Image.LANCZOS)
    cy = int(H * 0.22)
    bg.paste(card, ((W - cw) // 2, cy))

    draw = ImageDraw.Draw(bg)
    # border around card
    draw.rectangle([(W - cw) // 2, cy, (W - cw) // 2 + cw, cy + ch],
                   outline="white", width=6)

    centered(draw, badge, badge_font, H * 0.07, fill="#ffd54f", stroke=6)
    centered(draw, title, title_font, cy + ch + 70)
    centered(draw, sub, sub_font, cy + ch + 190)

    bg.save(out, quality=92)

# intro slide over neon bg
intro = cover(Image.open("bg_intro.jpg").convert("RGB"), W, H)
intro = Image.blend(intro, Image.new("RGB", (W, H), "black"), 0.55)
d = ImageDraw.Draw(intro)
centered(d, "TOP 4", intro_font, H * 0.30, fill="#ffd54f", stroke=6)
centered(d, "ROBLOX GAMES", intro_font, H * 0.42)
centered(d, "Playing right now", sub_font, H * 0.55)
intro.save("intro.jpg", quality=92)

print("done")
```

### make_captions.py
```python
from PIL import Image, ImageDraw, ImageFont

W, H = 1080, 1920
FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
font = ImageFont.truetype(FONT_BOLD, 52)

# clip name -> spoken caption (verbatim VO, for muted viewing)
caps = {
    "intro": "Here are the four Roblox games everyone is playing right now.",
    "s0": "First up, Grow a Garden. Plant your crops, then watch them grow even when you log off.",
    "s1": "Next, Blox Fruits. Fast combat, wild power-ups, and a grind you can't put down.",
    "s2": "Then Brookhaven, where you just hang out, role-play, and build your own little life.",
    "s3": "And Adopt Me. Raise adorable pets, trade them, and design your dream home.",
}

MAXW = 960  # text wrap width in px


def wrap(draw, text, font, maxw):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=font) <= maxw:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


for name, text in caps.items():
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    lines = wrap(d, text, font, MAXW)
    lh = font.size + 18
    block_h = lh * len(lines)
    y0 = int(H * 0.80) - block_h // 2  # caption band low in frame

    # translucent rounded box behind text
    pad = 36
    box = [(W - MAXW) // 2 - pad, y0 - pad,
           (W + MAXW) // 2 + pad, y0 + block_h + pad]
    d.rounded_rectangle(box, radius=28, fill=(0, 0, 0, 150))

    for i, line in enumerate(lines):
        tw = d.textlength(line, font=font)
        x = (W - tw) / 2
        y = y0 + i * lh
        d.text((x, y), line, font=font, fill="white",
               stroke_width=4, stroke_fill="black")

    img.save(f"cap_{name}.png")

print("captions done:", ", ".join(caps))
```

### build_v3.sh
```bash
#!/usr/bin/env bash
# reel_v3: pacing floor + crossfade transitions + alternating Ken Burns +
# fade in/out + loudnorm. Speech protected from the crossfade by wrapping each
# VO in lead/tail silence (>= XF), so transitions overlap silence, not words.
# Caption PNG overlaid per slide if cap_<name>.png exists (make_captions.py).
set -euo pipefail
cd "$(dirname "$0")"

FPS=30
XF=0.4          # crossfade duration
LEAD=0.45       # silence before speech  (>= XF so xfade region is silent)
TAIL=0.65       # silence after speech   (>= XF)
VOMIN=1.8       # floor on the speech window itself

# name image seg motion
slides=(
  "intro intro.jpg seg_intro.aiff in"
  "s0    slide0.jpg seg0.aiff      out"
  "s1    slide1.jpg seg1.aiff      in"
  "s2    slide2.jpg seg2.aiff      out"
  "s3    slide3.jpg seg3.aiff      in"
)

durs=(); clips=()

for row in "${slides[@]}"; do
  read -r name img seg motion <<<"$row"
  vo=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$seg")
  # total slide time = lead + max(vo,VOMIN) + tail
  T=$(awk -v a="$vo" -v m="$VOMIN" -v l="$LEAD" -v t="$TAIL" \
        'BEGIN{w=(a>m?a:m); printf "%.3f", l+w+t}')
  frames=$(awk -v t="$T" -v f="$FPS" 'BEGIN{printf "%d", t*f}')
  ms=$(awk -v l="$LEAD" 'BEGIN{printf "%d", l*1000}')
  durs+=("$T")

  if [ "$motion" = "in" ]; then
    zp="z='min(zoom+0.0016,1.18)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
  else
    zp="z='if(eq(on,0),1.18,max(zoom-0.0016,1.0))':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
  fi

  cap="cap_${name}.png"
  if [ -f "$cap" ]; then
    capin=(-i "$cap")
    vchain="[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,\
zoompan=${zp}:d=${frames}:fps=${FPS}:s=1080x1920,setsar=1[bg];\
[bg][2:v]overlay=0:0:format=auto[v];"
  else
    capin=()
    vchain="[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,\
zoompan=${zp}:d=${frames}:fps=${FPS}:s=1080x1920,setsar=1[v];"
  fi

  ffmpeg -y -loglevel error \
    -i "$img" -i "$seg" "${capin[@]}" \
    -filter_complex "${vchain}\
[1:a]aformat=sample_rates=44100:channel_layouts=stereo,adelay=${ms}|${ms},\
apad,atrim=0:${T},asetpts=N/SR/TB[a]" \
    -map "[v]" -map "[a]" -t "$T" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -ar 44100 "clip_${name}.mp4"
  clips+=("clip_${name}.mp4")
done

# xfade + acrossfade chain (transitions sit inside the silent pads)
inputs=(); for c in "${clips[@]}"; do inputs+=(-i "$c"); done
fc=""; prevV="[0:v]"; prevA="[0:a]"; acc=${durs[0]}
for i in 1 2 3 4; do
  off=$(awk -v a="$acc" -v x="$XF" 'BEGIN{printf "%.3f", a-x}')
  fc+="${prevV}[${i}:v]xfade=transition=fade:duration=${XF}:offset=${off}[vx${i}];"
  fc+="${prevA}[${i}:a]acrossfade=d=${XF}[ax${i}];"
  prevV="[vx${i}]"; prevA="[ax${i}]"
  acc=$(awk -v a="$acc" -v d="${durs[$i]}" -v x="$XF" 'BEGIN{printf "%.3f", a+d-x}')
done

total=$acc
fadeout=$(awk -v t="$total" 'BEGIN{printf "%.3f", t-0.6}')
# scale range full->tv + format yuv420p so players don't render black (jpeg src = full range)
fc+="${prevV}fade=t=in:st=0:d=0.4,fade=t=out:st=${fadeout}:d=0.6,scale=in_range=full:out_range=tv,format=yuv420p[vout];"
fc+="${prevA}loudnorm=I=-14:TP=-1.5:LRA=11[aout]"

ffmpeg -y -loglevel error "${inputs[@]}" \
  -filter_complex "$fc" -map "[vout]" -map "[aout]" \
  -c:v libx264 -profile:v high -level 4.0 -pix_fmt yuv420p -crf 20 \
  -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
  -c:a aac -b:a 192k -movflags +faststart reel_v3.mp4

echo "built reel_v3.mp4 total~${total}s"
ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 reel_v3.mp4
```
"""#
}
