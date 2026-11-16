# Design deviations

Places where the app deliberately differs from `design/compass-v3` renders, and why. Everything else
should match its render within 1pt with the same line breaks (compare `renders/ios/<ID>.png` with
`design/compass-v3/renders/screens/<ScreenID.designRender>`).

| Screen | Render | App | Why |
|---|---|---|---|
| G1, G2 | "Since 14 Apr · 212 steps", "212 steps over seven months." | "Since 14 Apr · 166 steps", "167 steps over seven months." | One step a day: 14 Apr to 10 Nov 2026 is 211 days (17 in April, 184 from May to October, 10 in November), so this goal can't hold 212 steps whatever the history. The fixture keeps the boards' history (E1/E3 patterns) and shows its true count. The totals boards (R1, R2, H2) don't show a start date and read 212 · 186 from a store kept since 20 Feb (`Fixtures.totalsSnapshot`). |
| C10 | Settings icon top-right | "Cancel" top-right | Typing a note needs a visible way out (spec: no hidden gestures; review item 33). It replaces Settings in the same slot and type as the nav's quiet text. |
| C10 | Field 24–308, save circle 324–380 | Field 24–293, save circle 309–365 | The board's input keeps its browser minimum width and pushes the circle to 10pt from the edge. The app keeps the 24pt inset on both sides. |
| B5 on iPhone SE | (not drawn) | Part chip beside "Add step" | Planned reflow: on a 667pt phone a two-line step, the chip and the lifted action don't fit above the keyboard, so the chip joins the action's row. The 844pt layout is the board's. |
| E3 | Nine weeks, to 9–15 Sep | Same, from a goal that began 9 Sep | E3's fixture goal starts 9 Sep, so the list ends where the board's does; a goal started 14 Apr lists every week back to 14 Apr. |
| Sheets (E4, H2, C6, part and time sheets) | Fixed heights | Board height at Large, taller when text needs it | Sheets grow with Dynamic Type up to the safe top and scroll beyond it; Cancel (744–792) is always drawn. |
| Settings time sheet | (not drawn) | A6's − 07:00 + row | No wheel picker: the time is set with the board's own control and A6's limits. |
