# Cloud help: HTTP contract

Compass's "Cloud help" switch (A7, H1) turns on evening summaries and step ideas from a private
cloud model. The app ships the client (`Packages/CompassCore/Sources/CompassCore/HTTPCloudAssist.swift`);
the repo ships **no server**. This document is the contract a backend must meet.

## Status in the repo

- `COMPASS_CLOUD_ASSIST_ENDPOINT` in `project.yml` is empty, so every repo build has no endpoint.
- With no endpoint, A7 shows "Not set up in this version of Compass…" instead of the switch, H1 shows
  "Cloud help · Not set up" with a footnote, and the app never sends anything. Planning goes straight to
  naming your own step (B4); evening reflections keep the plain transcript.
- To point a build at a backend, set the build setting (it lands in Info.plist as
  `CompassCloudAssistEndpoint`), e.g. `xcodebuild … COMPASS_CLOUD_ASSIST_ENDPOINT=https://assist.example.com/v1`.
  For development only, the `CompassCloudAssistEndpoint` user default overrides it
  (`xcrun simctl spawn booted defaults write app.compass.Compass CompassCloudAssistEndpoint https://…`).

## Transport

- **https only.** `http://`, unexpanded `$(…)`, missing hosts and other schemes count as "not
  configured" (`CloudAssistConfiguration.httpsURL`). A configuration built in code with an http URL is
  refused before sending (`HTTPCloudAssistError.insecureEndpoint`).
- `POST <endpoint>/<path>`, `Content-Type: application/json`, `Accept: application/json`, UTF-8 JSON
  body with sorted keys. 20 s timeout.
- No authentication header, cookies, device identifiers, user IDs, locale or app version are sent.
  If a deployment needs auth, add it at the edge (for example an mTLS or App Attest gateway) and extend
  this document first.
- Success is any 2xx with a JSON body matching the reply shape below. Unknown reply fields are ignored.

## Endpoints

### `POST /summarize` — evening summary (D5)

Request:
```json
{ "transcript": "Called Lena about the pilot and sent the deck.", "goal": "Build a calm, profitable studio" }
```
`goal` may be `null`. Reply:
```json
{ "summary": "Called Lena; deck sent." }
```
One short sentence, in the user's words where possible; no praise, scores or streaks. An empty
`summary` is treated as a malformed reply.

### `POST /step` — a step idea (B3, B6, F1)

Request:
```json
{
  "goal": "Build a calm, profitable studio",
  "parts": [ { "id": "7C1E…-UUID", "title": "Clients" }, { "id": "…", "title": "Health" } ],
  "part": { "id": "7C1E…-UUID", "title": "Clients" },
  "size": "regular",
  "recent": [ { "date": "2026-11-09", "title": "Pitch Ridgeline", "moved": true } ]
}
```
- `parts` are the goal's active parts. `part` is the part the idea should serve (may be `null`).
- `size` is `"regular"` or `"smaller"` (smaller after quiet days, F1).
- `recent` is at most the last 14 days: ISO date, that day's step title (may be `null`), and whether
  it moved.

Reply:
```json
{ "title": "Text Sam about Friday dinner", "partID": "7C1E…-UUID", "size": "smaller", "hint": "about 2 minutes" }
```
`title` is required and non-empty, with no full stop. `partID` must be one of the request's part ids
(anything else falls back to the requested part). `size` and `hint` are optional.

### `POST /clarify` — one question for a vague goal (A4b)

Request: `{ "goal": "Get healthier" }`. Reply: `{ "question": "What would healthier look like by summer?" }`,
or `{ "question": null }` when the goal is concrete enough.

### `POST /parts` — split a goal into parts (A5)

Request: `{ "goal": "Build a calm, profitable studio" }`. Reply:
```json
{ "parts": [ { "title": "Clients", "symbol": "we" }, { "title": "Health", "symbol": "sg" } ] }
```
At most six parts are used. `symbol` is optional and must be a `PartSymbol` raw value (`we`, `sg`, `fr`, … see
`Models.swift`); unknown values get a default symbol.

## Errors and what the user sees

| Situation | Client error | App behaviour |
|---|---|---|
| Switch off or no endpoint | `CloudAssistError.disabled` | Plain transcript, no idea. Never retried. |
| No network (`URLError` not-connected, connection lost, timed out, DNS/host unreachable, data not allowed, roaming off, call active) | `CloudAssistError.offline` | D6 "Offline. Text and summary appear here when you reconnect." Retried automatically when `NWPathMonitor` reports the path is back, when the app becomes active, or on "Try now". |
| Non-2xx status | `HTTPCloudAssistError.badStatus(code)` | Treated as a server problem (`CloudAssistFailure.server`): the plain transcript stands and no idea is offered. Never shown as offline; not retried automatically. |
| Reply isn't the expected JSON | `HTTPCloudAssistError.malformedResponse` | Same as a server problem. |
| http endpoint | `HTTPCloudAssistError.insecureEndpoint` | Same as a server problem; nothing is sent. |

Servers should answer quickly (well under the 20 s timeout) and return 4xx/5xx rather than hanging.

## Privacy requirements for a backend

What is sent: the evening transcript text, the goal text, part titles and ids, and up to 14 recent step
titles with dates. **Audio is never sent.** Today notes are never sent.

A backend that implements this contract must:

- not train or fine-tune any model on request content ("never trains on them", A7);
- not log request bodies, or keep them only transiently for abuse handling, and never link them to an
  identity (the app sends none);
- not share request content with third parties beyond the model provider processing it under the
  same terms;
- serve TLS with a publicly trusted certificate (App Transport Security defaults; no exceptions are
  configured in Info.plist).

The app's privacy manifest (`Compass/Resources/PrivacyInfo.xcprivacy`) declares this as "Other user
content", not linked to identity, not used for tracking, for app functionality. If the contract changes
what is sent, update the manifest and A7's copy with it.
