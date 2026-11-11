# Libre 3 minute readings – fork notes (DIAforMary/Trio)

This fork is a personal test version, not an upstream contribution. The code in
the branch `libre-1min-display` was written with Claude (AI) and is marked as
such in every commit. It is not intended for a pull
request to nightscout/Trio, whose contribution guidelines exclude largely
AI-generated code.

## Branches

| Branch | Content |
|---|---|
| `main` | Unchanged upstream Trio, synced and built on schedule as usual |
| `libre-1min-display` | The single test branch: minute readings uploaded to the main Nightscout (experimental), shown in the home chart and, optionally, in the glucose bubble |

Both use the same App ID and the same Core Data model, so TestFlight builds of
either can replace each other without data loss. (The former second test branch
`libre-1min-export` and its "second server" option were merged into this branch
and removed.)

## Where the minute readings come from

LibreLoop (the Libre 3 driver) receives a reading from the sensor every minute.
It forwards a reading to Trio only every ~5 minutes (270 s throttle). Trio stores
those forwarded readings in Core Data (`GlucoseStored`), and that table feeds
the algorithm and everything else.

LibreLoop also offers a public observer, `LibreLoopStateObserver`, which is
notified (on the main thread) after every state change, including each new
minute reading. `MinuteGlucoseExporter` registers as this observer whenever the
active CGM is LibreLoop (`PluginSource` calls `attach(to:)` when its CGM manager
is set). For every live reading (`source == .realtime`) without a blocking
sensor issue it:

1. records the reading in `MinuteGlucoseStore` (only if a display option is on), and
2. queues it for upload (only if the export is on).

The minute readings are never written to `GlucoseStored`, never passed to
`FetchGlucoseManager`, and never trigger a loop.

## What the minute readings may touch, and what they may not

Minute readings are used in exactly three places:

| Place | File | Effect |
|---|---|---|
| Upload | `MinuteGlucoseExporter.swift` | POST to `/api/v1/entries.json` of Trio's main Nightscout |
| Home chart | `MinuteGlucoseChartView.swift`, `MainChartView.swift` | Small faded dots behind the 5-minute dots |
| Glucose bubble | `CurrentGlucoseView.swift` | Optional small line or main value (see below) |

Everything else keeps reading `GlucoseStored` (5-minute data) exactly as in
original Trio. That includes oref (determination), autosens, carbs on board,
smoothing, the loop trigger (heartbeat), the bolus calculator, glucose alarms,
freshness and staleness checks, statistics (TIR, averages, GMI), Apple Watch,
Live Activity, Garmin, calendar, contact image, Shortcuts, HealthKit, Tidepool,
and Trio's own Nightscout upload. None of their source files were changed.

Changes outside the new files:

- `PluginSource.swift`: two calls to `MinuteGlucoseExporter.shared.attach(to:)`. No other change.
- `NightscoutConfigStateModel.swift` (button "Backfill Glucose"): fetched
  readings are now thinned to ≥ 3.5 minutes apart and stored with
  `backfillGlucose` (3.5-minute buffer against existing readings) instead of
  `storeGlucose` (1-second buffer). This makes the button stricter. It prevents
  1-minute entries on the main Nightscout from ever reaching `GlucoseStored`.
- `NightscoutConfigRootView.swift`: one navigation link to the settings screen.
- `HomeStateModel.swift`: three display-only properties (`minuteGlucose`,
  `minuteGlucoseRecent`, `minuteBubbleMode`) filled from `MinuteGlucoseStore`.
- `MainChartView.swift`: one extra chart layer, drawn before the 5-minute dots.
- `CurrentGlucoseView.swift`, `HomeRootView+Header.swift`: optional minute
  display in the bubble. With the setting off, the bubble code path is unchanged.
- `build_trio.yml`: branch builds sync from upstream `main`.
- `check_1min_export.yml` (new): compile + unit tests, no TestFlight upload.

## Settings (Settings > Nightscout > 1-Minute Readings (Libre 3))

All options are off by default. With everything off, the app behaves like original Trio.

### Upload to main Nightscout (experimental)
- **Upload minute readings** (then **Save**): uses Trio's existing Nightscout
  connection (URL and API secret from Settings > Nightscout) and sends only the
  minute readings LibreLoop did not forward to Trio. Trio's own 5-minute entries
  are not touched and nothing is duplicated. Document format matches Trio's
  uploads (`type`, `sgv`, `date`, `dateString`, `direction`; no `device`, no
  `identifier`; millisecond timestamp truncated like Trio's).
- Not possible without a main Nightscout configured in Trio.
- LoopFollow then shows deltas about 5 times smaller, and its fast-drop alarm
  (drop per reading) may not fire. Nightscout's own web page handles 1-minute
  data (delta from 5-minute blocks).
- Settings of the former "second server" option (URL, API secret, target) are
  removed automatically on first start of this build, together with readings
  still queued for it. If the export was set to the second server, the upload
  is switched off, so it never starts sending to the main Nightscout without
  being turned on deliberately.
- Queue: up to 24 h of readings kept in `Application Support/MinuteGlucoseExport/queue.json`
  while the server is unreachable; retries with backoff 1, 2, 4, 8, 15 minutes.
  HTTP 400/413/422 drops the rejected batch; 401/403 shows "check API secret".
- **Test connection** calls `/api/v1/verifyauth` on the main Nightscout and reports write access.

### Trio display
- **Show minute readings in chart**: small faded dots behind the 5-minute dots.
- **Glucose bubble**:
  - **5-minute value only**: original Trio.
  - **Small line with minute reading**: the big number stays the 5-minute value.
    A small line below shows the newest minute reading and its minute after the
    last 5-minute reading, e.g. `1-min 118 · +3 min` (+1 … +4). Hidden when the
    newest minute reading is the 5-minute reading itself.
  - **Minute reading as main value**: the big number is the newest minute
    reading, marked `1-min` above it. "Minutes ago" refers to that reading. The
    delta is the newest minute reading minus the minute reading about 5 minutes
    earlier (± 90 s), so it keeps the usual 5-minute meaning ("--" if none).
    The arrow still comes from the last 5-minute reading. The bolus calculator
    still uses the last 5-minute value, which can be up to 4 minutes older.
- Fallbacks: the bubble shows original 5-minute data whenever no minute reading
  is younger than 3 minutes, when the 5-minute reading is not fresh (stale/
  sensor states unchanged), or when the CGM is not LibreLoop.
- Storage: `Application Support/MinuteGlucoseExport/chart-readings.json`, last
  24 h, separate from Core Data. Deleted when chart dots and bubble are both off.

## Switching versions (TestFlight)

No Core Data model change in either branch, so any build can replace any other.
Files and settings of the fork (`MinuteGlucoseExport/*.json`, UserDefaults keys
`MinuteGlucoseExport.*`) are simply ignored by original Trio.

## Verification so far

- Compiles in GitHub Actions (iOS Simulator, Xcode 26.2).
- Unit tests (`MinuteGlucoseExportTests`, `MinuteReadingBufferTests`,
  `MinuteBubbleInfoTests`): queue, request format, URL checks, store, bubble logic.
- Not yet tested on a real device with a sensor. Test during the day first.
