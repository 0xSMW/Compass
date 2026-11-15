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
    Store.swift                 Store protocol, InMemoryStore, JSONFileStore (schema check, quarantine)
    Sync.swift                  SyncEnvelope, SnapshotMerger (per-item updatedAt, wipe generations, E5)
    SyncLocal.swift             DeviceIdentity (E5 labels), LocalEdits (stamping), AudioSyncPlan
    Backup.swift                BackupRestoring, BackupReader (waits for iCloud placeholders), R3 reasons
    Services.swift              AudioRecorder, SpeechTranscriber, CloudAssist protocols (+ errors)
    Fakes.swift                 FakeAudioRecorder, FakeSpeechTranscriber, FakeCloudAssist (deterministic)
    ScreenID.swift              Flow + ScreenID (all 66 board states), captions, design render names
    Fixtures.swift              Board copy, history, SystemConditions, ScreenFixture, fixture(for:)
  Tests/CompassCoreTests/       DayEngine, Store, History, Fixture tests
Compass/
  App/                          CompassApp + RootView, AppModel, LaunchOptions      (shared)
  Navigation/                   ScreenRegistry (ID → flow)                         (shared)
  DesignSystem/
    Tokens/                     Colors, Typography, Metrics (Space/Radius/ControlSize/IconSize/Motion),
                                Icons (also compiled into the widget)
    Icons.xcassets              34 template SVG icons "icon-<id>" from symbols.html (scripts/gen_icons.py)
    Layout/                     Regions (ScreenMetrics, Region, .region()), FlowScreen, TodayScaffold
    Components/                 CompassText, CompassTextEditor, Buttons, Voice, Navigation, Controls,
                                StepCard (+ Feedback, CompassSheet, confirm / part-picker sheets)
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
CompassTests/                   App-target unit tests (hosted, `@testable import Compass`): AppModel save path, store
CompassUITests/                 ScreenshotTests: launches every ScreenID, saves <ID>.png; fails if `screen-<ID>` is missing
renders/ios/<ID>.png            Screenshots committed by CI (390×844, compare to design renders)
```

## Saving: one path

`AppModel.snapshot` is `private(set)`. Change it only with `mutate { snapshot in … }`, the helpers built
on it (`updateToday`, `updateDay(_:_:)`, `updateSettings`, `setGoal`, …) or `commit(_:origin:)` for a
whole snapshot (restore, sync merge with `.remote`, the widget's copy). Every change saves to the store,
tells sync (`.local` only) and reloads the widget timelines (`SnapshotEffects`, spied in `CompassTests`).
`deleteEverything()` clears the store and reloads the widget; sync hears about a wipe through
`LiveSync.wipeEverywhere`. There is no other save call: never call `store.save` from a feature.

`commit` stamps `.local` changes (`LocalEdits`): every changed item gets `updatedAt`, new notes and
reflections get this install's `deviceID` and model. That is what sync merges on, item by item; restores
commit as `.restored` (synced, not stamped). Deleting a recording goes through `VoiceStorage.delete`,
which leaves an audio tombstone so the file leaves iCloud and every device. Only recordings the
snapshot refers to are uploaded or downloaded.

## Platform services (live path only)

- Cloud help: `HTTPCloudAssist` (Core), https only, contract in `docs/CLOUD_ASSIST.md`. No endpoint in repo
  builds, so `model.cloudHelpConfigured` is false and A7/H1 say "Not set up"; use `model.cloudHelpOn`, not
  `settings.cloudAssist`, to decide whether to ask. `NetworkMonitor` (NWPathMonitor) retries D6 on reconnect.
- Recording: `LiveAudioRecorder` ends a take on interruption/route loss and keeps it for `stop()`; the level
  stream finishing while listening makes `VoiceCapture` call `onSilence` (save as after a pause).
- Reminders: weekly repeating calendar triggers (`NotificationPlanner.schedule`) plus a background app refresh
  (`ReminderRefresh`, task id in project.yml).
- Export: one zip in `tmp/CompassExport`, removed after the share sheet (`DataExport`).
- `Compass/Resources/PrivacyInfo.xcprivacy` lists the required-reason APIs; update it with new API use.

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
       default: EmptyView() // ScreenRegistry sends only this flow's IDs
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
- `DayEngine` rules: no goal and no history → onboarding; an achieved/ended goal (or history without a
  goal) → `goalEnded`, Today's frame with "Set the next goal" (never A1); ≥30 quiet days → F3; 3–29 →
  F2; 1–2 → smaller suggested step (F1 frame); ≥ evening time (21:00) → D1 / D2 / D2b until reflected;
  before noon, morning not handled → B1 (B7 on day 3, B4-style naming in the first week); noon–21:00 →
  B6; else Today. The rhythm is clamped to A6's limits (morning 04:00–11:45, evening 17:00–23:45).
  `phase` and `morningPlan` share one planning function.
- The entry screen follows the clock (`AppModel+Clock.swift`): on becoming active, on clock/zone changes
  and at each boundary (noon, the evening time, midnight; `SystemServices` arms the timer), a morning,
  Today, evening or return root is replaced by the new entry screen when `DayEngine.clockMoved` says the
  day or its part moved on. It waits while something is said or typed; an evening answer saves to the
  day the evening opened on (`EveningSession.dayKey`).
- Notes: a voice note takes its recording's id (`<note id>.m4a`, `NoteRules`); Today's notes row, the
  notes list and E2 open `NoteDetailSheet` (plays, Edit note, Delete note).

## Design system (SwiftUI port of kit.css)

Deliberate differences from the renders are listed in `docs/DESIGN_DEVIATIONS.md`.
Everything on screen comes from `Compass/DesignSystem`. Features compose these pieces; they don't set
fonts, draw their own docks, notices, chips or sheets, or use system menus, alerts or pickers.

**Tokens.** Colours `.ground .surface .raised .line .line2 .ink .noticeInk .ink2 .ink3 .dim .destructive .scrim`
(`ShapeStyle` statics). Text is never `.dim` (3.8:1): placeholders use `.ink3` (5.7:1).
`Space.xs/s/m/l/xl = 8/16/24/32/48`, `Radius.card 24 / tile 12 / pill(h)`, `ControlSize`, `IconSize`
(`xs 16 · s 20 · i 24 · m 28 · l 36`, kit.css `svg.*`), `Motion` (`turnTaking` 200 ms, `answerToRecord` 240 ms,
`complete` 240 ms, `breath` 4 s; every one cut with Reduce Motion / `-uitest`).

**Type.** `CompassType`: `display 44/48 · title 34/40 · live 24/32 · heading 22/28 · body 17/24 · caption 15/20 ·
micro 13/16 mono` plus the board-only tokens `label` (13/16 Inter 500, History day labels), `nav` (17 → 22 at
AX), `bodyMono` (Settings times), `time` (28/32 mono, A6), `numeral` (96, −0.05em, F2) and `clock` (96,
−0.04em, I5). Each scales along the spec's curve to its AX5 size (micro is `mono axC` 22/28 at AX).

**Text: one primitive.** `CompassText(_:style:weight:color:)` (or `runs:` for live words) sets every style on
the spec's exact line boxes: a UILabel with a fixed paragraph line height, glyphs centred in each box as CSS
does, and no line-break strategy, so lines break like the boards (SwiftUI's `Text` can't go below the font's
natural line, so title/display grew 1–2pt a line, and it pushes a word down to avoid orphans). It reads the
environment like `Text`: Dynamic Type, `.lineLimit`, `.multilineTextAlignment`, `.truncationMode(.head)`
(keeps the newest words), `.minimumScaleFactor`; colour is a parameter. Typed text uses
`CompassTextEditor` (UITextView, same line boxes, ink3 placeholder, `lines:` range, Return submits) through
`UnderlineField` and `BoxedField`. `.compassFont` remains only for the widget extension (no UIKit there; the
app's I6 board passes `CompassText` into `TodayWidgetContent`).

**Layout.** `FlowScreen { … }` + `.region(.nav | .subject | .focal | .focalTop | .middle(top:) | .wave | .dock |
.buttonDock | .buttonDockHigh | .linkDock | .labels | .player | .todayDock | .aboveKeyboard | .keyboard |
.custom(top:bottom:inset:) | .growsUp(bottom:))`. `.aboveKeyboard` is keyboard-relative (16 above the real
keyboard via `KeyboardFrame`, or the estimated one: 508 on 844, 260pt tall on iPhone SE); draw screenshot
keyboards with `KeyboardPlaceholder().region(.keyboard)`. `.scrollingRegion(_:)` places text that can
outgrow its region at large sizes: it sits on the region's lines, and scrolls inside it (starting at the top)
instead of running into the dock (A1, A2, A5–A7, R1–R3, F2, F3, G2). `TodayScaffold(onHistory:onSettings:
trailing:header:notes:card:dock:overlay:)`; `trailing` swaps Settings for a visible escape (C10 "Cancel").

**Sheets.** `CompassSheet(height:label:dismissTitle:contentTop:onDismiss:content:actions:)` /
`.compassSheet(isPresented:…) { content } actions: { … }`. `height` is the board's height at Large; the sheet
grows to fit its content up to the safe top and the content scrolls beyond that. Actions sit bottom-anchored
(last one on 684–740, the 712 line) and the escape link (`dismissTitle`, "Cancel"/"Close") is always drawn on
744–792: no hidden gestures (the scrim tap and VoiceOver escape also dismiss). Levels inside a sheet (C6 →
Counts toward, E4 → part / delete) swap its content; Cancel goes one level back. Built on it:
`.confirmSheet(isPresented:title:message:confirm:role:onConfirm:)` (replaces `confirmationDialog`),
`.partPickerSheet(isPresented:parts:selected:onPick:)` and `PartPickerRows` (replace `Menu`), and
`TimeStepperRow` (A6's − 07:00 + row, used by Settings instead of a wheel `DatePicker`).

| Component | kit.css | Notes |
|---|---|---|
| `MicButton(mode: .idle/.rings/.breathing/.listening/.recording, size:icon:label:action:)` | `.mic` `.ringw` `.glow` `.stop` | breath 4 s, still when reduced |
| `Waveform(levels:lit:count:isStatic:)`, `LevelBar(level:)`, `MiniWaveform(levels:)` | `.wavebar`, `.minw` | level bar when reduced unless `isStatic` (fixture bars) |
| `ChoiceCircles(yes:no:yesIcon:onYes:onNo:)` | `.dockc` `.choice` | check 36; the tapped circle becomes the mic in 240 ms; 72pt buttons at AX |
| `VoiceDock(micMode:micLabel:keyboardLabel:onKeyboard:onMic:side:)`, `DockSkip` | `.dock` `.side` | the one voice dock; keyboard glyph 28 at AX |
| `TodayDock(recording:typingFirst:levels:onKeyboard:onNote:)`, `NotePill` | `.tdock` `.pill` | `typingFirst` swaps the jobs (Start with: Typing) |
| `Player(duration:isPlaying:levels:showsRedo:onPlay:onRedo:)` | `.player` | 80 tall on 712; redo 20 (28 at AX); duration micro |
| `PrimaryButton`, `SecondaryButton` | `.btn` `.btn2` | icon 20 (28 at AX); `role: .destructive` |
| `LinkButton(_:tone: .quiet/.ink/.destructive, style:padding:minHeight:)` | `.lnk` | never under 44 × 44 |
| `ButtonDock(primary:primaryIcon:role:link:onPrimary:onLink:)` | `.dockb` + `.dockl` | places itself |
| `CircleButton(_:label:style: .outline/.ink/.fill, size:iconSize:)` | `.c56` | |
| `IconButton(_:label:bare:tint:iconSize:)` | `.ic44` | |
| `NoteRow(note:count:action:)` / `NoteRow(text:spoken:meta:…)` | `.note` | the one note row; meta drops at AX |
| `Chip(title:icon:iconTint:trailing:accessibilityLabel:tint:action:)` | `.chip` | the one chip; no action = static (E2); grows at AX |
| `Notice(icon:text:actions:layout: .inline/.stacked, actionSpacing:actionHeight:centred:onDismiss:)` | `.notice` | the one notice (I1–I4, D6, D6b, Today); 44pt action targets |
| `Tile`, `ListRow(icon:tile:title:value:valueStyle:showsTopLine:lineColor:tint:action:accessory:)`, `RowChevron` | `.tile` `.lr` | |
| `CompassSwitch(label:isOn:)` | `.sw` | |
| `UnderlineField(prompt:text:style:lines:focused:showsFocus:label:onSubmit:)`, `BoxedField` | `.field` | on `CompassTextEditor` |
| `StepCard(…)`, `CompletionCircle` + `Feedback` | `.slot` `.c56.done` | min 176, grows up; 240 ms fill, one click |
| `NavBar(leading:trailing:progress:solid:scalesText:)`, `NavItem.close(_:)/.back/.quietBack/.text/.icon` (`iconSize`) | `.nav` `.navb` | `scalesText`: 24 → 28 icons, 17 → 22 text, 16 → 20 chevrons at AX |
| `ProgressDots`, `SubjectLine(icon:text:redoLabel:onRedo:)` | `.prog` `.ctx` | symbol 20 (28 at AX), redo 20 |
| `LiveTranscript(settled:pending:style:)` | `.live` + `.dim` | |
| `SegmentedPill`, `OptionCard` | history `.seg` `.opt` | 44pt segment targets |
| `DayMarkView(mark:size: .week/.line)`, `GoalEndMarker(achieved:size:)` | history `.dot` `.dr` `.tm` | the one history mark (E1 rows, E3 weeks, E2 subject) |
| `KeyboardPlaceholder` | `.keys` | screenshots only |
| `Icon(_:size:)`, `CompassIcon` (34 cases) | `symbols.html` | |

## CI loop and screenshots

`.github/workflows/ios.yml` runs on pushes to `main` and `claude/friendly-ritchie-5q2nh9`, on pull requests,
and on manual dispatch (optional `screens` input like `C3,C4`). Only pushes to the screenshot branch commit
PNGs back:
1. `core` (ubuntu, swift:6.2): `swift test` in `Packages/CompassCore`.
2. `app` (macos-26, Xcode 26.6): `xcodegen generate`, build app + widget + UI tests on the iPhone 16e
   simulator (iOS 26.2, 390×844 pt; falls back to 17e), run `CompassTests` (unit), run `ScreenshotTests`, scale each PNG to
   390×844 with `sips`, commit `renders/ios/<ID>.png` (+ `README.txt` with run URL) back to the branch
   with `[skip ci]`.

Last green run: https://github.com/0xSMW/Compass/actions/runs/43740739724 (66/66 screenshots).
`renders/ios/README.txt` names the run and commit that produced the current PNGs.

Loop: push → watch the run (GitHub MCP `actions_list` / `get_job_logs` with `failed_only`) → `git pull`
→ open `renders/ios/<ID>.png` next to `design/compass-v3/renders/screens/<designRender>` and compare.
Build errors appear in the "Build app, widget and UI tests" step (grep for `error:`). Always
`git pull --rebase` before pushing: CI commits screenshots to the same branch.
