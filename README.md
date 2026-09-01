# eva-ext-desktop-mac

A macOS-only [Eva](https://github.com/aayushmau5/eva) project extension named `desktop_mac`.
It lets an Eva agent inspect the current macOS desktop — screenshot it, read the frontmost
application's accessibility hierarchy — and act on it by clicking controls or coordinates,
typing text and shortcuts, scrolling, dragging, and waiting, then verifying the result with
a fresh screenshot.

A menu-bar app (`EvaDesktopHelper.app`) owns macOS permissions, holds the automation
enabled/paused state, and is the only place automation can be turned on.

## Status

The extension registers exactly three sequential tools:

- `desktop_status` reports permission, automation, foreground-app, and display state.
- `desktop_observe` returns a JPEG screenshot plus a bounded accessibility snapshot and
  ephemeral element references.
- `desktop_action` performs one click, type, key, scroll, wait, double-click, or drag and
  returns a fresh observation.

Accessibility element frames and coordinate actions use pixels in the latest screenshot.
They are mapped into the selected display's global macOS point coordinates, including Retina
scaling and displays whose origins are not `(0, 0)`. Prefer semantic element references over
coordinates when a matching reference exists. The screenshot cursor is hidden.

The helper requests enhanced accessibility from Chromium-based browsers so their webpage
controls are included alongside browser chrome when the browser supports it.

Observation payloads are intentionally bounded: screenshots use JPEG quality 0.68 with a
1280-pixel longest edge, accessibility snapshots return at most 200 elements, and text
fields are capped at 200 characters. At most 50 static-text/row/cell entries are returned so
controls retain most of the snapshot budget.

Before each provider request, the extension replaces superseded screenshot-bearing desktop
observations with a short marker and keeps only the latest observation. The saved transcript,
desktop errors, and images returned by other tools remain unchanged.

The helper starts paused. Only its menu-bar menu can enable automation, and enablement
expires after ten minutes. It also pauses when the extension disconnects. Actions reject a
stale foreground app/window, secure accessibility values are redacted, and screenshots are
not retained in tool-result metadata.

Distribution work—Developer ID signing, hardened runtime, notarization, installers, and a
universal binary—remains intentionally deferred until after local smoke testing.

## Development

```bash
EVA_CORE_PATH=../eva/core mix deps.get
./scripts/build_helper
EVA_CORE_PATH=../eva/core mix compile --warnings-as-errors
EVA_CORE_PATH=../eva/core mix test
swift test --package-path native/EvaDesktopHelper
```

`mix precommit` runs all of the above (helper build, warnings-as-errors compile, unused-dep
check, format, Elixir tests, Swift tests).

## Running the helper

Normally, start the extension through Eva; its supervised Elixir process launches the app
bundle executable with the required private stdin/stdout connection. For a standalone menu
and protocol check, run the bundled executable directly from a terminal:

```bash
./scripts/build_helper
priv/EvaDesktopHelper.app/Contents/MacOS/EvaDesktopHelper
```

The helper remains open while that terminal input is connected. Press Control-D to close
stdin and stop it. Do not launch it with `open`: that supplies no persistent protocol stdin,
so the helper correctly pauses and exits immediately.

## Registering with Eva

```bash
cd /path/to/eva
mix eva.ext.add ../eva-ext-desktop-mac
mix eva.ext.start desktop_mac
mix eva.ext.list
```

## Permissions

The helper must be granted Accessibility and Screen Recording access before `desktop_observe`
and `desktop_action` work. Those permissions are requested from the menu, never from a tool
call.

> Note: ad-hoc rebuilds of the helper bundle can cause macOS to request permissions again,
> because the ad-hoc signature changes. Proper Developer ID signing and notarization belong
> to the distribution milestone.
