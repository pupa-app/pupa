# Opening Animation + First-Install Onboarding for Pupa

## Context

Pupa launches today straight into the app: `PupaHostApp` renders `AppView()` with
no splash, no welcome, and no guidance ([PupaHostApp.swift](../PupaHost/PupaHost/PupaHostApp.swift),
[AppView.swift](../Pupa/Sources/PupaApp/App/AppView.swift)). A first-time user lands on a
pre-seeded "Example: Job Search" canvas with zero explanation of the three things that
make Pupa special — **MyApps** (living agent-driven canvases), **Chat** (natural-language
control of the canvas), and the **backend** that powers the agent. Chat does nothing until
a backend is paired ([SettingsStore.swift](../Pupa/Sources/PupaApp/Settings/SettingsStore.swift),
[BackendEditSheet.swift](../Pupa/Sources/PupaApp/Settings/BackendEditSheet.swift)), so a new
user can hit a dead end with no signpost.

**Goal:** Add (1) a brief animated-logo splash on every cold launch, and (2) a one-time,
first-install marketing-grade onboarding that tells the Pupa story, gets the backend paired
(skippable), and drops the user into a guided first chat. The marketing aim is *aha-in-under-60-seconds*:
make the value obvious, the setup painless, and the first real action successful.

**Decisions locked with the user:**
- Onboarding style: **marketing carousel** (value slides) **+ live backend setup**, then drop into the seeded example.
- Backend step: **skippable** ("Skip for now") with a persistent gentle reminder until paired.
- Splash: plays on **every cold launch**, ~1.5s, tap-to-skip.

---

## Marketing narrative (the "why" behind each step)

The flow is engineered as a funnel: **Hook → Value → Proof → Setup → First Win**. Each
screen has exactly one job and one primary action. Copy is benefit-first, not feature-first.

| # | Screen | Marketing job | One-line copy (draft) |
|---|--------|---------------|------------------------|
| 0 | **Splash** | Brand imprint | *(logo animates in, no text needed)* |
| 1 | **Welcome / Hook** | Promise the outcome | "Meet Pupa — apps that build themselves around you." |
| 2 | **MyApps value** | Show the core object | "Every workspace is a living app. Trackers, calendars, checklists — reshaped on demand." |
| 3 | **Chat value** | Show the magic | "Just ask. Pupa rebuilds the canvas in real time — no forms, no menus." |
| 4 | **Memory value** | Show the moat | "Pupa remembers. It learns your goals and gets sharper every session." |
| 5 | **Connect backend** | Remove the blocker | "Pair your Pupa backend to bring your agent to life." → Scan QR / Enter code / **Skip for now** |
| 6 | **First win** | Activation | Drop into "Example: Job Search", chat pre-filled with a suggested prompt: *"Add a prep task for my Friday interview"* |

Principles applied: **progressive disclosure** (one idea per slide), **show-don't-tell**
(slides 2–4 use real in-app component thumbnails/animations, not stock art), **friction
removal** (backend skippable, prompt pre-filled), **single CTA per screen**, **always
escapable** ("Skip" on every slide so it never feels like a wall).

---

## Architecture

Insert a small root coordinator above `AppView` so onboarding/splash state lives outside
the heavy app graph. Keep `AppView` untouched except for one optional hook (suggested
first-chat prompt + a "needs backend" reminder banner).

### New persistence flags
Add a tiny `@Observable OnboardingState` (mirrors the `SettingsStore` UserDefaults-JSON
pattern, key `pupa.onboarding.v1`) — or, simplest, two `@AppStorage` keys read in the root:
- `pupa.onboarding.completed` : Bool — gates the onboarding flow.
- `pupa.onboarding.backendSkipped` : Bool — drives the "connect your backend" reminder banner inside the app.

Reuse the existing UserDefaults snapshot convention seen in
[SettingsStore.swift](../Pupa/Sources/PupaApp/Settings/SettingsStore.swift) (`storageKey` +
JSON `Snapshot`) rather than inventing a new persistence mechanism.

### New root coordinator
**New file:** `Pupa/Sources/PupaApp/App/RootView.swift`
```swift
public struct RootView: View {
    @State private var showSplash = true
    @AppStorage("pupa.onboarding.completed") private var onboardingDone = false

    public var body: some View {
        ZStack {
            AppView()                                  // always built underneath
            if !onboardingDone { OnboardingFlowView(...) }   // covers app until finished
            if showSplash { SplashView(isPresented: $showSplash) }  // top-most, every launch
        }
    }
}
```
Splash sits on top of everything and fades out on every launch; onboarding covers the app
only on first install. Building `AppView` underneath means the seeded example is ready the
instant onboarding dismisses (the "first win" feels instant).

**Edit:** [PupaHostApp.swift](../PupaHost/PupaHost/PupaHostApp.swift) — swap `AppView()` for `RootView()`.

---

## Components to build

### 1. SplashView — animated logo (every launch)
**New file:** `Pupa/Sources/PupaApp/App/SplashView.swift`
- Render `AppIcon.swiftUIImage` from [AppIcon.swift](../Pupa/Sources/PupaApp/App/AppIcon.swift) (already bundle-loaded, cross-platform).
- Animation: scale `0.6 → 1.0` + opacity `0 → 1` with a gentle settle, then hold ~0.5s, then fade the whole view out. Reuse the app's existing spring idiom `(.spring(response: 0.35, dampingFraction: 0.85))` seen in `ChatOverlay`.
- Background: brand gradient using `MemoryTheme.orchestratorColor` (purple) — see [MemoryTheme.swift](../Pupa/Sources/PupaApp/Memory/MemoryTheme.swift).
- Total ~1.5s; `onTapGesture` skips immediately; flips `isPresented = false` via `withAnimation`.
- Honor Reduce Motion (`@Environment(\.accessibilityReduceMotion)`): fall back to a plain fade.

### 2. OnboardingFlowView — carousel + setup container
**New file:** `Pupa/Sources/PupaApp/App/OnboardingFlowView.swift`
- A `TabView(selection:)` with `.page` style (paging dots) holding slides 1–5, plus a final transition that sets `onboardingDone = true`.
- Persistent chrome: page-dots indicator, "Skip" top-trailing on every slide (jumps to the backend step, or finishes), and a primary "Continue" button per slide.
- New value-slide subview `OnboardingSlide(title:subtitle:art:)` for slides 1–4. "Art" should use **real app surfaces**: render shrunken, non-interactive previews of an actual tracker/checklist card and the chat bubble UI so the slides demo the product, not clip-art. Pull visual styling from existing component views and `MemoryTheme` palette.
- Light entrance animation per slide (content slides/fades in) reusing the spring idiom; respect Reduce Motion.

### 3. Backend connect step (slide 5) — reuse, don't rebuild
- **Reuse the existing pairing UI/logic** rather than duplicating it:
  - QR scan + code entry + `/auth/pair` POST already implemented in [BackendEditSheet.swift](../Pupa/Sources/PupaApp/Settings/BackendEditSheet.swift) and [BackendPairingClient.swift](../Pupa/Sources/PupaApp/Settings/BackendPairingClient.swift); token stored via [BackendCredentialStore.swift](../Pupa/Sources/PupaApp/Settings/BackendCredentialStore.swift); reachability/paired badges via [BackendConfigClient.swift](../Pupa/Sources/PupaApp/Settings/BackendConfigClient.swift).
  - Default URL `http://localhost:8004/` and label already exist as `SettingsStore.defaultBackendURL` / `defaultBackendLabel`.
- Implementation: present `BackendEditSheet` (seeded with the default entry) from the onboarding step, OR extract its pairing body into a shared subview embeddable both in the sheet and the slide. Prefer the **sheet-presentation** route first (lowest risk, no refactor); factor out a shared view only if layout demands it.
- On success → show a green "Paired ✓" confirmation, advance to first-win. On "Skip for now" → set `pupa.onboarding.backendSkipped = true`, advance anyway.

### 4. First-win handoff + reminder banner (light touch to AppView)
- On completion, set `onboardingDone = true`. `AppView` already initializes selection to
  `.myAppHome(store.activeMyAppId)` and chat scope to `.myApp(...)` — the seeded
  "Example: Job Search" is already the landing canvas, so the "first win" context is free.
- **Suggested first prompt:** add an optional pre-filled draft to the chat composer so the
  user's first action is one tap away. Wire a new optional parameter through
  [AppView.swift](../Pupa/Sources/PupaApp/App/AppView.swift) → `ChatOverlay` →
  `ChatPanel` `draft`. (Smallest change: have onboarding write a suggested-prompt value
  into a shared place the chat composer reads on first appearance.)
- **Reminder banner:** when `pupa.onboarding.backendSkipped == true` and no backend is
  paired, show a slim dismissible banner ("Pair your backend to start chatting →" opening
  Settings) above the canvas in `AppView`. Hide once paired (reuse the paired-status check
  from `BackendConfigClient`/credential store).

---

## Files

**New**
- `Pupa/Sources/PupaApp/App/RootView.swift` — splash/onboarding/app coordinator
- `Pupa/Sources/PupaApp/App/SplashView.swift` — animated logo
- `Pupa/Sources/PupaApp/App/OnboardingFlowView.swift` — carousel + setup
- `Pupa/Sources/PupaApp/App/OnboardingSlide.swift` — reusable value-slide + in-app preview art
- *(optional)* `Pupa/Sources/PupaApp/App/OnboardingState.swift` — if not using bare `@AppStorage`

**Edited**
- [PupaHostApp.swift](../PupaHost/PupaHost/PupaHostApp.swift) — `AppView()` → `RootView()`
- [AppView.swift](../Pupa/Sources/PupaApp/App/AppView.swift) — optional suggested-prompt param + skipped-backend reminder banner
- *(possibly)* [BackendEditSheet.swift](../Pupa/Sources/PupaApp/Settings/BackendEditSheet.swift) — extract a shared pairing subview only if embedding (not needed if presented as a sheet)

**Reused as-is**
- `AppIcon.swiftUIImage`, `MemoryTheme` palette, existing spring animation idioms,
  full backend pairing stack (`BackendEditSheet` / `BackendPairingClient` /
  `BackendCredentialStore` / `BackendConfigClient`), `SettingsStore` defaults & persistence pattern.

---

## Verification

Build/run the iOS host (the project ships via the `testflight-release` archive flow; for dev use the `run` skill or `xcodebuild`/simulator).

1. **Splash, every launch:** Cold-launch → logo animates in over brand gradient, ~1.5s, fades to app. Tap mid-animation → skips immediately. Relaunch → splash plays again.
2. **First-install onboarding:** Reset state (delete app / clear `pupa.onboarding.*` UserDefaults keys), launch → splash → slide 1. Swipe through 1–4; paging dots update; "Skip" jumps to the backend step from any slide.
3. **Backend — happy path:** On slide 5, run `make pair` on the backend, enter/scan the code → green "Paired ✓" → advance. Confirm token landed in Keychain and a turn streams in the seeded chat.
4. **Backend — skip path:** Tap "Skip for now" → lands in "Example: Job Search" with the reminder banner visible; tapping it opens Settings → Backend; pairing there dismisses the banner.
5. **First win:** After completion the chat composer shows the suggested prompt; sending it (with a paired backend) mutates the example canvas.
6. **Persistence:** Force-quit and relaunch a completed install → splash only, no onboarding (`pupa.onboarding.completed == true`).
7. **Accessibility:** Enable Reduce Motion → splash & slide entrances degrade to fades, no scale/spring.
8. **Regression:** Existing users (flag already true via migration default) never see onboarding; existing Settings/backends untouched.
