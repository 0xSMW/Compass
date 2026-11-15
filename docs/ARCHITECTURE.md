# Compass architecture (brief for flow agents)

Native iOS 18+ app, SwiftUI, Swift 5 language mode (Swift 6 compiler). Design source of truth:
`design/compass-v3/` (boards, `source/tools/kit.css`, `source/boards/spec.html`, renders).

## Folder map

```
project.yml                     XcodeGen spec (CI generates Compass.xcodeproj; never commit it)
Packages/CompassCore/           Pure Swift, Linux-buildable. `swift test` runs here.
  Sources/CompassCore/
    Models.swift                Goal, GoalPart, PartSymbol, Day, DayKey, Intention, Step, Note,
                                Reflection, TimeOfDay, Rhythm (07:00/21:00), Settings, CompassSnapshot
    DayEngine.swift             DayPhase / MorningPlan / EveningKind: phase from clock + history
    History.swift               DayMark (moved/missed/empty), HistoryWeek, HistoryBuilder, GoalMarker
    Store.swift                 Store protocol, InMemoryStore, JSONFileStore
    Services.swift              AudioRecorder, SpeechTranscriber, CloudAssist protocols (+ errors)
    Fakes.swift                 FakeAudioRecorder, FakeSpeechTranscriber, FakeCloudAssist (deterministic)
    ScreenID.swift              Flow + ScreenID (all 66 board states), captions, design render names
    Fixtures.swift              Board copy, history, SystemConditions, ScreenFixture, fixture(for:)
  Tests/CompassCoreTests/       DayEngine, Store, History, Fixture tests
Compass/
  App/                          CompassApp + RootView, AppModel, LaunchOptions      (shared)
  Navigation/                   ScreenRegistry (ID → flow), ScreenStub, TodayStub  (shared)
  DesignSystem/
    Tokens/                     Colors, Typography, Metrics (Space/Radius/ControlSize/IconSize/Motion),
                                Icons (also compiled into the widget)
    Icons.xcassets              34 template SVG icons "icon-<id>" from symbols.html (scripts/gen_icons.py)
    Layout/                     Regions (ScreenMetrics, Region, .region()), FlowScreen, TodayScaffold
    Components/                 Buttons, Voice, Navigation, Controls, StepCard (+ Feedback, CompassSheet)
  Features/<Flow>/              ONE FOLDER PER FLOW, owned by that flow's agent
    Onboarding/OnboardingScreens.swift   A1–A8, R1–R3
    Morning/MorningScreens.swift         B1–B8
    Today/TodayScreens.swift             C1–C11b
    Evening/EveningScreens.swift         D1–D8
    History/HistoryScreens.swift         E1–E6
    Return/ReturnScreens.swift           F1–F3
    Goal/GoalScreens.swift               G1–G3
    Settings/SettingsScreens.swift       H1–H2
    System/SystemScreens.swift           I1–I6
  Resources/                    Fonts (Inter Tight 400/500/600, IBM Plex Mono 400/500 + OFL), Assets, click.wav
CompassWidget/                  WidgetKit extension: TodayStepWidget + CompleteStepIntent (interactive)
Shared/                         SharedStorage (App Group JSON file), compiled into app and widget
CompassUITests/                 ScreenshotTests: launches every ScreenID, saves <ID>.png
renders/ios/<ID>.png            Screenshots committed by CI (390×844, compare to design renders)
```

## Rules for flow agents

- Edit only your `Features/<Flow>/` folder. Keep `static func view(for: ScreenID) -> some View` in the
  entry file; add as many files as you like next to it. Need a new shared action? Add
  `extension AppModel { … }` in your folder. Need a new component or token? Ask, or add it in your
  folder first; do not fork the design system.
- Shared files (ScreenID, ScreenRegistry, AppModel, LaunchOptions, DesignSystem) already know all 66
  screens. If you truly must change one, keep it additive.
- **The only local check for SwiftUI files is `swiftc -parse <file>`** (Linux has no SwiftUI). It catches
  syntax only. Real type-checking happens in CI; push and read the logs.
  `export PATH=/opt/swift/usr/bin:$PATH` first. CompassCore changes: `cd Packages/CompassCore && swift test`.
- No streaks or scores anywhere. One sound: the completion click. Every icon button gets an
  accessibility label. Respect `@Environment(\.motionReduced)` (Reduce Motion, forced on in screenshots).

## Adding / building a screen

1. Find the ID's board in `design/compass-v3/source/boards/<flow>.html` (exact copy) and its render
   `design/compass-v3/renders/screens/<ID.designRender>` (e.g. `ScreenID.c4.designRender == "V3Today-04.png"`).
2. In your entry file, switch on the ID:
   ```swift
   @MainActor @ViewBuilder
   static func view(for id: ScreenID) -> some View {
       switch id {
       case .d1, .d1L, .d7: EveningQuestionView(id: id)
       default: ScreenStub(id: id)
       }
   }
   ```
3. Build the view from `FlowScreen` (or `TodayScaffold`) + components, reading data from
   `@Environment(AppModel.self) private var model` (`model.today`, `model.goal`, `model.part(id)`,
   `model.conditions`, `model.fixture?.transcript`, `model.fixture?.selectedDay`).
4. Navigate with `model.go(.e2)` (push), `model.back()`, `model.replace(with: .b2)` (turn-taking in place),
   `model.reset(to:)`, `model.closeRitual()` (Close on morning/evening), `model.goToEntry()`.
5. Transient states (keyboard up, sheet open, recording, transcript expanded) are drawn by your view for
   that ID: e.g. C6 renders the card with `.compassSheet(isPresented: .constant(true), height: 312)`.
   The simulator has no software keyboard in CI, so draw keyboard states with the field focused-looking
   (`UnderlineField(showsFocus: true)`) and a placeholder keyboard block (#1C1C1F, 508–844) if needed.

## ScreenID, fixtures, launch arguments

- `ScreenID` (CompassCore) has a case per board state; raw value = board ID (`"C11b"`, `"D1L"`).
  `id.flow`, `id.title`, `id.caption`, `id.label` ("C4 · Just completed"), `id.isLargestText`,
  `id.designRender`, `Flow.today.screens`.
- `Fixtures.fixture(for: id)` → `ScreenFixture { now, calendar, snapshot, conditions, transcript, selectedDay }`.
  Reference day: Tuesday 10 Nov 2026, Europe/London (I3 uses Asia/Tokyo). Goal since 14 Apr; the last
  9 weeks of history match history.html. Copy constants: `Fixtures.goalText`, `.intentionText`,
  `.stepTitle`, `.noteText`, `.reflectionSummary`, `.longStepTitle`, `.pitchStepTitle`, …
- Launch args: `-screen <ID>` loads the fixture into `AppModel` (in-memory store, fake services, fixed
  clock) and shows that screen; `-ax5` forces Dynamic Type AX5 (automatic for A8, B8, C11, C11b, D7, D8,
  E6); `-uitest` forces reduced motion. Without `-screen`, the app loads the JSON store and opens on
  `ScreenID.entry(for: model.phase, today:)`.
- `DayEngine` rules: no goal → onboarding; ≥30 quiet days → F3; 3–29 → F2; 1–2 → smaller suggested step
  (F1 frame); ≥ evening time (21:00) → D1 / D2 / D2b until reflected; before noon, morning not
  handled → B1 (B7 on day 3, B4-style naming in the first week); noon–21:00 → B6; else Today.

## Design system (SwiftUI port of kit.css)

Tokens: colours `.ground .surface .raised .line .line2 .ink .noticeInk .ink2 .ink3 .dim .destructive .scrim`
(`ShapeStyle` statics, so `.foregroundStyle(.ink2)` and `Color.ink` both work).
Type: `.compassFont(.display | .title | .live | .heading | .body | .caption | .micro, weight:)` —
Inter Tight / Plex Mono, spec line heights, Dynamic Type scaled to the spec's AX5 column.
`Space.xs/s/m/l/xl = 8/16/24/32/48`, `Radius.card 24 / tile 12 / pill(h)`, `ControlSize`, `IconSize`, `Motion`.
Layout: `FlowScreen { … }` + `.region(.nav | .subject | .focal | .focalTop | .middle(top:) | .wave | .dock |
.buttonDock | .buttonDockHigh | .linkDock | .labels | .player | .todayDock | .aboveKeyboard |
.custom(top:bottom:inset:) | .growsUp(bottom:))`; `TodayScaffold(onHistory:onSettings:header:notes:card:dock:overlay:)`.

| Component | kit.css | Notes |
|---|---|---|
| `MicButton(mode: .idle/.rings/.breathing/.listening/.recording, size:icon:label:action:)` | `.mic` `.ringw` `.glow` `.stop` | breath 4 s, still when reduced |
| `Waveform(levels:lit:count:)`, `LevelBar(level:)`, `MiniWaveform(levels:)` | `.wavebar`, `.minw` | level bar when reduced |
| `ChoiceCircles(yes:no:yesIcon:onYes:onNo:)` | `.dockc` `.choice` | 96 circles; 72pt buttons at AX sizes |
| `VoiceDock(micMode:keyboardLabel:onKeyboard:onMic:side:)` | `.dock` `.side` | keyboard left, Skip right |
| `Player(duration:isPlaying:levels:showsRedo:onPlay:onRedo:)` | `.player` | 80 tall on 712 |
| `PrimaryButton(_:icon:role:height:action:)` | `.btn` `.btn.danger` | `role: .destructive` |
| `SecondaryButton(_:icon:height:action:)` | `.btn2` | |
| `LinkButton(_:tone: .quiet/.ink, action:)` | `.lnk` `.lnk.ink` | |
| `ButtonDock(primary:primaryIcon:role:link:onPrimary:onLink:)` | `.dockb` + `.dockl` | places itself |
| `CircleButton(_:label:style: .outline/.ink, action:)` | `.c56` `.c56.ink` | |
| `IconButton(_:label:bare:tint:action:)` | `.ic44` `.ic44.bare` | |
| `NotePill(title:recording:levels:action:)`, `TodayDock(recording:onKeyboard:onNote:)` | `.pill` `.tdock` | |
| `NoteRow(text:duration:action:)` | `.note` | |
| `Chip(title:icon:trailing:accessibilityLabel:action:)` | `.chip` | |
| `Tile(icon:)` | `.tile` | |
| `ListRow(icon:tile:title:value:showsTopLine:tint:action:accessory:)` | `.lr` | |
| `CompassSwitch(label:isOn:)` | `.sw` | |
| `UnderlineField(prompt:text:style:axis:focused:showsFocus:)` | `.field` `.field.focus` | |
| `.compassSheet(isPresented:height:label:content:)`, `CompassSheet` | `.sheet` `.scrim` `.grab` | |
| `Notice(icon:text:actionTitle:action:)` | `.notice` | |
| `StepCard(title:partTitle:partIcon:state: .empty/.open/.justDone/.done, onToggle:onUndo:onOptions:onPlan:showsOptions:)` | `.slot` | min 176, grows up |
| `CompletionCircle(isDone:onChange:)` + `Feedback` | `.c56.done(.on)` | 240 ms fill, click (silent switch), light haptic, "Done, undo available" |
| `NavBar(leading:trailing:progress:solid:)`, `NavItem.close/.back/.text/.icon` | `.nav` `.navb` | |
| `ProgressDots(total:current:)` | `.prog` | 4 segments |
| `SubjectLine(icon:text:)` | `.ctx` | |
| `LiveTranscript(settled:pending:style:)` | `.live` + `.dim` | |
| `SegmentedPill(options:selection:)`, `OptionCard(selected:action:content:)` | history `.seg` `.opt` | |
| `DayMarkView(mark:size:)`, `GoalEndMarker(achieved:)` | history `.dot` `.dr` `.tm` | |
| `Icon(_ :size:)`, `CompassIcon` (34 cases, `.sfSymbol`, `init(PartSymbol)`) | `symbols.html` | |

## CI loop and screenshots

`.github/workflows/ios.yml` runs on every push to `claude/friendly-ritchie-5q2nh9` (and manual dispatch,
optional `screens` input like `C3,C4`):
1. `core` (ubuntu, swift:6.2): `swift test` in `Packages/CompassCore`.
2. `app` (macos-26, Xcode 26.6): `xcodegen generate`, build app + widget + UI tests on the iPhone 16e
   simulator (iOS 26.2, 390×844 pt; falls back to 17e), run `ScreenshotTests`, scale each PNG to
   390×844 with `sips`, commit `renders/ios/<ID>.png` (+ `README.txt` with run URL) back to the branch
   with `[skip ci]`.

Loop: push → watch the run (GitHub MCP `actions_list` / `get_job_logs` with `failed_only`) → `git pull`
→ open `renders/ios/<ID>.png` next to `design/compass-v3/renders/screens/<designRender>` and compare.
Build errors appear in the "Build app, widget and UI tests" step (grep for `error:`). Always
`git pull --rebase` before pushing: CI commits screenshots to the same branch.
