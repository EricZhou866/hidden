# Backlog

Durable, committed index of open work. The detailed planning layer
(`_meta/megagoals/issue-list-clearing/` and `.claude/`) is local-only and gitignored,
so this file is the version that survives a machine switch and a fresh clone. Keep it
short: one line per item, pointing at the issue, SPEC, or file that holds the detail.

Source of the current state: the v1.11 issue-clearing pass (2026-06-12), branch
`fix/v1-11-batch` / draft PR #365, and SPEC-003. Core-model changes (separator length
math, collapse state machine) are HIGH RISK and require a mandatory review-team pass.

## macOS 27 (#360) - resolved, needs wider hardware coverage

The capture this was blocked on was run on macOS 27.0 (26A428, 2048pt single display)
and the diagnosis changed: `NSStatusItem.length` is **not** ignored on 27. It is honored
exactly; what changed is the layout response, which *ejects* an item too long to fit
instead of reflowing around it, and an ejected item pushes nothing. `screenWidth * 2`
always lands past that cutoff, which is why nothing was hidden. Neither `windowWidth` nor
`buttonWidth` can detect this - both track the request in either state, so the shipped
diagnostic could never have separated them. Fix shipped: measure the collapse width
against the live bar (binary search on the separator's arrow-facing edge), keep a safety
margin below it, cache per display configuration. See `docs/ARCHITECTURE.md`.

Open follow-ups:

- **Verify on other hardware.** Confirmed only on one machine, one display, no notch,
  LTR. Wanted: a notched built-in display, a wide (3000pt+) external, mixed widths, and
  an RTL locale (the edge signal is mirrored there and has not been exercised).
- **Always-hidden section on 27.** It reuses the regular separator's measurement as a
  proxy instead of calibrating its own item, so on a wide bar its icons can still show.
- **Re-measurement only happens at collapse time.** If another app adds a menu bar icon
  while the bar is already collapsed, the cached length can be ejected and hiding stops
  with no visible sign until the next expand/collapse. A background poll cannot detect
  this (frames only refresh after the length is written). A fix would be a nudge-based
  check - rewrite the length as `cached + 1` and read - on
  `NSWorkspace.didLaunchApplicationNotification`, which is cheap and invisible. Not
  implemented yet; this was the "it stopped working again" report during development.
- **Hidden zone must be to the LEFT of the separator, as always.** Icons that end up to
  its right are simply not in the hidden zone and are correctly not hidden; on a fresh
  install the app's own items land leftmost, so the separator has to be ⌘-dragged right
  once. This is unchanged from macOS 26 but is easy to mistake for the 27 bug when
  triaging reports.
- **Calibration is not persisted.** It re-runs on the first collapse of every launch
  (~1s of separator flicker). Caching in `UserDefaults` keyed by display configuration
  would remove it, at the cost of a stale-cache path.

## Blocked on external-display hardware

- **#351 external-monitor visible-bar (26.4) verification.** The widest-attached-screen
  fix is code-only; the 26.4 + external-display reproduction was never run. Confirm no
  full-width bar leak on a real second monitor.

## Actionable now (no special hardware)

- **UAT + merge draft PR #365.** Per the local `UAT.md` (one row per fix, click-through
  steps). Merge order matters (stacked dependency). Merge is Han's action, not the agent's.
- **Cut the v1.11 release.** Version + CHANGELOG staged in #365. Needs a Developer ID for
  notarization + App Store submission. Shipping answers the "is this still maintained?"
  issues and unblocks the round-2 close sweep.
- **Upgrade-path BTM verification before any signed release.** Install a pre-v1.11 build,
  update to v1.11, confirm Login Items shows no leftover `LauncherApplication` row (the
  one-shot `SMLoginItemSetEnabled(..., false)` deauth was added but never run on hardware).
- **AXPress accessibility defect.** VoiceOver users cannot toggle the bar: the arrow's
  `AXPress` handler reads `NSApp.currentEvent`, which is nil under assistive synthesis.
- **`hoverToExpand` Preferences checkbox.** Shipped as a Terminal-only `defaults write`;
  add a proper checkbox in `PreferencesViewController`.
- **Surface the `SMAppService` error contract in the prefs UI.** On `register()` failure
  (unsigned build, or user denies in System Settings), the checkbox stays on while the
  system says off; the error is swallowed into NSLog. Fix when the prefs UI is next touched.
  `Common/Util.swift:29-31`.
- **Round-2 issue close sweep (~35 issues).** Obsolete-OS + meta/support candidates,
  deferred until v1.11 ships so the closures carry the strongest answer.
- **24h memory dogfood (#361).** Instruments stress-cycling found no leak; run v1.11 as
  the daily driver for 24h on the Air to close the open report.
- **Old branch decision.** `feature/menubarDetection` (PR #115) and `feature/ghost-mode`
  (PR #57) were kept per never-delete. Review or discard, Han's call.

## v1.12 standalone wins (no Option D needed)

- **#207 show clock/date when collapsed.** Loudest single feature ask (18+ comments).
- **#355** prefs window layout overlap. **#324** single-instance guard. **#276** Cmd+W
  closes the prefs window. Appearance bundle via community PR #194.

## Architectural epic (Option D, #366)

- **Managed-overflow / second-bar redesign.** The real fix that gates ~30 issues across
  four clusters: icon-drift (#28, #156, #181, #230, #231, #239, #252, #254, #275, #283,
  #321, #334), always-hidden (#171, #224, #242, #288), notch (#206, #225, #228, #245,
  #267, #269, #280, #292, #330), and macOS 27 (#360, now mitigated but still built on
  a mechanism the OS can withdraw). Replaces length-inflation with a
  managed overflow bar, likely via Accessibility. Needs a design decision from Han +
  macOS 27 hardware. Design + folded M1 (pin icons, persist order) / M2 (decouple
  always-hidden from `areSeparatorsHidden`, recover stuck items) in SPEC-003.
- **Security + behavior review of community PRs #358 and #350 first.** #358 (second bar,
  +1160 lines) and #350 (notch overflow, +429 lines) are the existing starting points.
  Do not merge on description alone; #358 especially needs a real review.
- **#242 permanent icon-loss repro.** Needs a throwaway defaults profile (live repro
  risks losing real menu-bar icons). Required before the always-hidden decouple lands.
