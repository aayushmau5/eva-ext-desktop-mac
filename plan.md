# Implementation Brief: `eva-ext-desktop-mac`

You are implementing a new macOS-only Eva project extension named `desktop_mac`.

Do not merely produce another plan. Inspect the referenced Eva code, implement the extension phase by phase, run its checks, and leave the repository in a working state. Do not commit, push, publish, or modify the main Eva repository unless the user explicitly asks.

## 1. Objective

Create a sibling repository at:

```text
/Users/aayushmau5/Documents/my-projects/eva-ext-desktop-mac
```

The extension will allow an Eva agent to:

- Inspect the current macOS desktop.
- Receive a screenshot.
- Inspect the frontmost application’s accessibility hierarchy.
- Click controls or coordinates.
- Type text and keyboard shortcuts.
- Scroll, double-click, drag, and wait.
- Verify the result through a fresh screenshot.
- Be enabled, paused, and monitored from a macOS menu-bar icon.

The target is the currently logged-in interactive macOS session. It must respect macOS Accessibility and Screen Recording permission boundaries.

## 2. Existing Eva architecture to reuse

The main Eva repository is:

```text
/Users/aayushmau5/Documents/my-projects/eva
```

Read its `AGENTS.md` before changing anything there.

Use the existing project-extension architecture. Relevant references:

```text
eva/core/lib/eva/core/extension.ex
eva/core/lib/eva/core/extension/spec.ex
eva/core/lib/eva/core/extension/node.ex
eva/core/lib/eva/core/agent/tools.ex
eva/core/lib/eva/core/agent/messages.ex
eva/lib/eva/extension/package.ex
../eva-mcp/lib/eva/extension/mcp.ex
../eva-mcp/lib/eva/extension/mcp/application.ex
```

Important existing capabilities:

- A project extension runs as a separate BEAM node.
- Tool executors can return text and image content.
- Tools can set `execution_mode: :sequential`.
- A project extension can own its own supervised OS processes.
- The extension node can run locally over loopback.
- `:eva_core` is available as a sparse Git dependency or local path dependency.

The Mix application name must be:

```elixir
:eva_desktop_mac
```

Eva strips the `eva_` prefix when registering project extensions, producing the extension name:

```text
desktop_mac
```

The extension module must therefore be:

```elixir
Eva.Extension.DesktopMac
```

The application must start:

```elixir
{Eva.Core.Extension.Node,
 name: "desktop_mac",
 module: Eva.Extension.DesktopMac}
```

Do not add macOS desktop functionality to Eva core.

## 3. Architecture

Use two processes:

```text
Eva agent
    ↕ Eva tool calls and results
Eva.Extension.DesktopMac
    ↕ calls
Eva.Extension.DesktopMac.Helper
    ↕ newline-delimited JSON over stdin/stdout
EvaDesktopHelper.app
    ↕ native APIs
macOS Accessibility + ScreenCaptureKit + Core Graphics
```

### Elixir side

The Elixir extension:

- Registers Eva tools.
- Starts and supervises the helper.
- Owns the helper’s stdin/stdout port.
- Converts helper responses into Eva `TextContent` and `ImageContent`.
- Validates arguments before sending them to Swift.
- Serializes concurrent requests through a single helper process.
- Reports clear errors if permissions are missing or the helper exits.

Use the standard Elixir `Port` API. Do not add `erlexec` unless native ports demonstrably cannot manage the helper.

### Swift side

`EvaDesktopHelper.app`:

- Is a real app bundle from the first version.
- Runs as a background/menu-bar app with no Dock icon.
- Owns all macOS permissions.
- Maintains the automation enabled/paused state.
- Reads JSON requests from stdin.
- Writes JSON responses to stdout.
- Writes all diagnostics to stderr.
- Uses only Apple frameworks and the Swift standard library.
- Processes desktop requests sequentially.

Do not build an Elixir NIF. A native crash must not crash the BEAM.

Do not use AppleScript for the initial implementation.

## 4. Deliberate non-goals

Do not implement these in the first version:

- Windows or Linux.
- Cross-platform native abstractions.
- OCR.
- Continuous video streaming.
- Audio capture.
- Browser DOM integration.
- AppleScript or Apple Events.
- Remote-machine control.
- Lock-screen or login-screen control.
- Attempts to bypass secure system prompts.
- Clipboard reading.
- Persistent background launch at login.
- Automatic updates.
- Mac App Store distribution.
- Universal Intel/Apple Silicon packaging unless requested.
- Multi-action macros or arbitrary action batches.
- A general plugin framework inside this extension.

One tool invocation performs at most one desktop action. This keeps state observable and limits runaway automation.

## 5. Suggested repository layout

Keep the file count small and modules cohesive:

```text
eva-ext-desktop-mac/
├── AGENTS.md
├── README.md
├── mix.exs
├── .formatter.exs
├── lib/
│   └── eva/
│       └── extension/
│           ├── desktop_mac.ex
│           └── desktop_mac/
│               ├── application.ex
│               ├── helper.ex
│               └── tools.ex
├── native/
│   └── EvaDesktopHelper/
│       ├── Package.swift
│       ├── Info.plist
│       ├── Sources/
│       │   └── EvaDesktopHelper/
│       │       ├── main.swift
│       │       ├── Protocol.swift
│       │       └── Desktop.swift
│       └── Tests/
│           └── EvaDesktopHelperTests/
│               └── ProtocolTests.swift
├── priv/
│   └── EvaDesktopHelper.app/
├── scripts/
│   └── build_helper
└── test/
    ├── test_helper.exs
    ├── desktop_mac_test.exs
    ├── helper_test.exs
    └── support/
        └── fake_helper.exs
```

If `Desktop.swift` becomes unwieldy, split it by real responsibility into:

```text
Accessibility.swift
ScreenCapture.swift
Input.swift
StatusMenu.swift
```

Do not create protocols, factories, or adapters with only one implementation.

## 6. Mix project

Follow the `eva-mcp` local-development dependency pattern:

```elixir
defp eva_core do
  case System.get_env("EVA_CORE_PATH") do
    nil ->
      {:eva_core,
       git: "https://github.com/aayushmau5/eva.git",
       sparse: "core"}

    path ->
      {:eva_core, path: path}
  end
end
```

Use Elixir `~> 1.20`.

The application module is:

```elixir
Eva.Extension.DesktopMac.Application
```

Its supervision tree should contain:

1. `Eva.Extension.DesktopMac.Helper`
2. `Eva.Core.Extension.Node`

The helper is one global process shared by all Eva sessions attached to this extension node. The helper and its macOS automation state are machine-global, so per-session helper processes would be misleading and could race each other.

The extension itself can remain stateless: `setup/1` returns tool definitions whose executors call the named helper process.

Set every desktop tool to:

```elixir
execution_mode: :sequential
```

The helper GenServer provides serialization across separate Eva sessions as well.

## 7. Building the app bundle

Use Swift Package Manager for the executable and tests. Do not add an Xcode project generator.

Target macOS 15 or newer initially.

The build script must:

1. Run `swift build` for `native/EvaDesktopHelper`.
2. Create:

   ```text
   priv/EvaDesktopHelper.app/Contents/MacOS/
   priv/EvaDesktopHelper.app/Contents/Info.plist
   ```

3. Copy the Swift executable into `Contents/MacOS/EvaDesktopHelper`.
4. Copy the app’s `Info.plist`.
5. Ad-hoc sign the development bundle with `codesign --sign -`.
6. Fail with a clear message when compilation or signing fails.

The app bundle identifier should be stable, for example:

```text
dev.eva.desktop-helper
```

Configure `LSUIElement` so the helper has a menu-bar icon but no Dock icon.

The helper executable path on the Elixir side should normally come from:

```elixir
:code.priv_dir(:eva_desktop_mac)
```

Allow a test-only/application configuration override for the helper command so Elixir tests can launch a fake helper.

For development builds, warn in the README that ad-hoc rebuilds may cause macOS to request permissions again. Proper Developer ID signing and notarization belong to the distribution milestone.

## 8. Menu-bar behavior

Use AppKit `NSStatusItem`. An SF Symbol is sufficient; do not create image assets yet.

Suggested symbol:

```text
cursorarrow.click.2
```

The menu should show:

```text
Eva Desktop
Extension IPC: Connected
Accessibility: Granted / Missing
Screen Recording: Granted / Missing
Automation: Paused / Enabled

[Enable Automation for 10 Minutes]
[Pause Automation]
[Request Accessibility Permission]
[Request Screen Recording Permission]
[Recheck Permissions]
[Quit]
```

Behavior:

- Automation starts paused every time the helper starts.
- Observation may work while actions are paused.
- All mutating actions fail with `automation_paused` until enabled locally.
- Enabling automation is only possible from the menu-bar app.
- There must be no protocol method that lets the agent enable itself.
- Enabling lasts at most ten minutes.
- Automatically pause when the timer expires.
- Automatically pause when stdin closes or the Elixir process disconnects.
- The menu must update immediately when permission or automation state changes.
- Quitting the helper must not cause an endless supervisor restart loop. Treat a clean, user-requested exit differently from a crash. It is acceptable for tools to report that the helper was intentionally stopped until the extension node is restarted.

A separate global emergency shortcut is unnecessary in the first version because only one short action is allowed per tool call. The menu’s Pause action is the emergency control.

## 9. Native permission handling

Accessibility:

- Check using `AXIsProcessTrustedWithOptions`.
- Only prompt when the user selects the corresponding menu item.
- Tool calls must never unexpectedly trigger permission dialogs.

Screen Recording:

- Check using `CGPreflightScreenCaptureAccess`.
- Prompt using `CGRequestScreenCaptureAccess` only from the menu.
- Clearly report when a helper restart is required after permission is granted.

Do not silently fall back to blank screenshots or fake success.

Relevant Apple documentation:

- [AX accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement)
- [AXUIElement actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)
- [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)
- [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

## 10. Stdio protocol

Use newline-delimited JSON.

Stdout is exclusively for protocol frames. Never log to stdout.

### Request

```json
{
  "id": 12,
  "method": "status",
  "params": {}
}
```

### Successful response

```json
{
  "id": 12,
  "ok": true,
  "result": {}
}
```

### Error response

```json
{
  "id": 12,
  "ok": false,
  "error": {
    "code": "screen_recording_permission_missing",
    "message": "Grant Screen Recording permission from the Eva Desktop menu."
  }
}
```

Use monotonically increasing integer request IDs on the Elixir side.

The Elixir port receives arbitrary chunks. Implement a buffer that:

- Appends new bytes.
- Splits complete lines at newline boundaries.
- Preserves the trailing incomplete frame.
- Handles multiple frames in one chunk.
- Rejects malformed JSON without crashing.
- Enforces a maximum response size.

The helper processes one request at a time. The Elixir GenServer may track pending requests by ID and reply asynchronously with `GenServer.reply/2`.

Every request needs a timeout. A reasonable initial default is 30 seconds. `wait` must have a lower validated maximum, such as 10 seconds.

When the helper exits:

- Fail all pending requests.
- Include the exit reason.
- Restart after crashes.
- Do not loop after a clean user-requested quit.

### Required helper methods

```text
status
observe
action
```

An optional internal `ping` method is useful for transport tests.

## 11. Eva tool surface

Expose exactly three tools initially.

### `desktop_status`

Arguments:

```json
{}
```

Returns:

- Helper version.
- macOS version.
- Automation enabled/paused state and expiry.
- Accessibility permission state.
- Screen Recording permission state.
- Frontmost application.
- Available displays.
- Whether the helper is healthy.

### `desktop_observe`

Arguments:

```json
{
  "scope": "display",
  "display_id": "optional"
}
```

Initial behavior:

- Default to the main display.
- Capture a screenshot.
- Inspect the focused window of the frontmost application.
- Return a compact accessibility snapshot.
- Generate a unique `observation_id`.
- Store ephemeral element references for that observation.

Future support for active-window-only screenshots may be added after display capture works.

### `desktop_action`

Use a broad object schema with a `kind` enum rather than a deeply nested JSON Schema `oneOf`; provider support for complex schemas is inconsistent.

Properties:

```json
{
  "kind": "click",
  "observation_id": "obs-...",
  "target": "e12",
  "x": 420,
  "y": 280,
  "button": "left",
  "text": "hello",
  "replace": false,
  "keys": ["CMD", "L"],
  "delta_x": 0,
  "delta_y": -600,
  "path": [
    {"x": 100, "y": 100},
    {"x": 300, "y": 300}
  ],
  "milliseconds": 500
}
```

Validate required fields based on `kind`.

Supported kinds, in implementation order:

1. `click`
2. `type`
3. `key`
4. `scroll`
5. `wait`
6. `double_click`
7. `drag`

Do not support action batches.

All actions require a recent `observation_id`.

Prefer `target` element references. Use `x` and `y` only as a fallback.

After every successful action:

- Wait briefly for the UI to settle.
- Capture a fresh screenshot.
- Return a new `observation_id`.
- Report the current frontmost app and window.
- Do not claim success merely because an event was posted.

## 12. Tool results

Eva currently sends `TextContent` and `ImageContent` to the model, while `details` is primarily transcript/UI metadata. Therefore, model-required observation metadata must be included in text content, not only in `details`.

A successful observation should return:

```elixir
%Tools.AgentToolResult{
  content: [
    %Messages.TextContent{text: JSON.encode!(metadata)},
    %Messages.ImageContent{
      data: screenshot_base64,
      mime_type: "image/jpeg"
    }
  ],
  details: metadata
}
```

The metadata should include:

```json
{
  "observation_id": "obs-...",
  "scope": "display",
  "image": {
    "width": 1600,
    "height": 1040
  },
  "screen_frame_points": {
    "x": 0,
    "y": 0,
    "width": 1512,
    "height": 982
  },
  "frontmost_app": {
    "name": "TextEdit",
    "bundle_id": "com.apple.TextEdit",
    "pid": 1234
  },
  "focused_window": {
    "title": "Untitled",
    "frame": {}
  },
  "elements": [],
  "tree_truncated": false
}
```

Use JPEG at a reasonable quality, approximately 0.75–0.85. Limit the longest image dimension to approximately 1600 pixels initially. Return enough coordinate metadata to map image pixels back to screen points.

## 13. Screen capture

Use ScreenCaptureKit, preferably `SCScreenshotManager`, for individual frames.

Initial capture scope:

- Main display by default.
- Optional display selected by an ID returned from `desktop_status`.
- Exclude the helper’s own application from the capture where supported.

Return cursor visibility deliberately and document the choice. Showing the cursor is useful for debugging; hiding it avoids confusing the model about clickable objects. Default to hidden unless tests show otherwise.

Do not implement continuous `SCStream` capture for this version.

Coordinate rules must be explicit:

- Coordinates supplied by the model refer to pixels in the latest returned screenshot.
- The helper maps screenshot pixels into the captured display’s global point coordinate system.
- Support Retina scale factors correctly.
- Reject coordinates outside the captured image.
- Avoid assuming the main display always starts at global point `(0, 0)`.

Add unit tests for coordinate transformations.

## 14. Accessibility observation

Use `NSWorkspace.shared.frontmostApplication` to find the target process.

Create its accessibility root with:

```swift
AXUIElementCreateApplication(pid)
```

Inspect the focused window first. Avoid traversing the entire system accessibility tree.

For each useful element return:

```json
{
  "ref": "e12",
  "role": "AXButton",
  "subrole": null,
  "title": "Save",
  "description": null,
  "value": null,
  "enabled": true,
  "focused": false,
  "frame": {
    "x": 120,
    "y": 40,
    "width": 80,
    "height": 24
  },
  "actions": ["AXPress"]
}
```

Rules:

- References are ephemeral and only valid with their `observation_id`.
- Clear the reference map when producing a new observation.
- Reject stale references with `stale_element`.
- Redact the value of `AXSecureTextField`.
- Limit individual strings.
- Limit traversal depth.
- Limit total returned nodes, initially around 500.
- Mark the result as truncated when a limit is reached.
- Prefer actionable controls and meaningful text over layout-only containers.
- Set a bounded AX messaging timeout.
- Treat unresponsive or invalid elements as recoverable omissions, not fatal errors for the entire tree.

Useful roles include:

```text
AXWindow
AXButton
AXTextField
AXTextArea
AXSecureTextField
AXCheckBox
AXRadioButton
AXPopUpButton
AXMenuItem
AXStaticText
AXLink
AXTab
AXRow
AXCell
AXSlider
```

Do not build a generalized selector language yet.

## 15. Input implementation

Use semantic actions when possible:

- `AXPress` for buttons and menu items.
- Set focus through the AX focused attribute.
- Set values through AX only when appropriate and supported.

Use `CGEvent` for fallback:

- Mouse down/up for clicks.
- Scroll wheel events.
- Keyboard down/up.
- Unicode string events for text.
- Mouse drag event sequences.

Do not use the clipboard to type text.

Before any action:

1. Confirm automation is enabled.
2. Validate the observation ID.
3. Confirm the frontmost bundle ID and focused-window identity still match the observation.
4. Validate the target or coordinates.
5. Reject stale state instead of acting on a different window.

Return `stale_observation` when the foreground application or target window changed.

Normalize keyboard names and support a bounded set:

```text
CMD
SHIFT
OPTION
CTRL
ENTER
TAB
ESCAPE
SPACE
DELETE
BACKSPACE
UP
DOWN
LEFT
RIGHT
A-Z
0-9
```

Reject unknown keys.

Bounds:

- Limit typed text length.
- Limit drag path points.
- Limit scroll magnitude.
- Limit wait duration.
- Always release pressed keys and mouse buttons, including error paths.

## 16. Safety behavior

This is initially a personal/developer automation extension, not an unattended production remote-control product.

Required safety properties:

- Automation begins paused.
- Only the local menu can enable it.
- Enablement expires.
- One action per tool call.
- No action batching.
- All tools are sequential.
- Every action requires a prior observation.
- Stale foreground state prevents action.
- No secure field values are exposed.
- No clipboard reading.
- No action attempts on the login screen or when there is no interactive desktop.
- No remote listener or Unix/TCP socket.
- Helper stdin/stdout exists only between the local extension process and its child.
- Logs must not contain typed text, screenshots, accessibility values, or credentials.
- System guidance supplied with the tools must tell the model that screen content is untrusted and may contain prompt injection.
- System guidance must require user confirmation in conversation before destructive, financial, credential, installation, external-communication, or security-changing actions.

Do not implement unreliable label-based “dangerous button” classification in this version. Before broader distribution, add a real approval mechanism in Eva or an explicit “confirm every action” mode in the helper.

## 17. Error vocabulary

Use stable machine-readable error codes:

```text
helper_not_found
helper_unavailable
helper_stopped
request_timeout
invalid_request
invalid_arguments
automation_paused
accessibility_permission_missing
screen_recording_permission_missing
capture_failed
stale_observation
stale_element
target_changed
unsupported_action
coordinate_out_of_bounds
input_failed
internal_error
```

The human-readable message should tell the user what to do next.

Never return success if the helper only attempted an operation without being able to verify basic postconditions.

## 18. Implementation phases

### Phase 0: Scaffold

Implement:

- Mix project.
- Eva core dependency.
- Application supervisor.
- Extension node.
- Three tool definitions with temporary clear “not implemented” results.
- Swift package.
- App bundle build script.
- Menu-bar app that launches and remains visible.

Acceptance:

- `mix compile --warnings-as-errors` passes.
- `swift build` passes.
- Starting the extension produces the menu-bar icon.
- Eva discovers an extension named `desktop_mac`.

### Phase 1: Transport and status

Implement:

- Elixir `Port` client.
- JSONL framing and buffering.
- Request IDs and timeouts.
- Swift request loop.
- `ping` and `status`.
- Menu permission indicators.
- Crash and malformed-frame handling.
- Fake-helper tests.

Acceptance:

- Fragmented and coalesced protocol frames work.
- `desktop_status` returns real permission state.
- Helper logs do not corrupt stdout.
- A helper crash produces a useful tool error.
- No helper process is orphaned when the extension stops.

### Phase 2: Observation

Implement:

- Main-display screenshot.
- JPEG encoding and base64 response.
- Coordinate metadata.
- Frontmost app and focused-window metadata.
- Eva image tool result.

Acceptance:

- `desktop_observe` returns an image visible to the model.
- Screenshot dimensions and mapping metadata are correct on Retina.
- Missing Screen Recording permission produces a specific error.
- The helper does not capture endlessly or retain unbounded frame buffers.

### Phase 3: Basic actions

Implement:

- Local ten-minute enable/pause control.
- `click`
- `type`
- `key`
- `scroll`
- `wait`
- Post-action screenshot.
- Observation freshness checks.

Acceptance:

- Automation cannot act while paused.
- Text can be entered into TextEdit without clipboard use.
- A stale observation cannot click another application.
- Every action returns a current screenshot.
- Keys and mouse buttons are released on failures.

### Phase 4: Semantic accessibility

Implement:

- Focused-window AX traversal.
- Compact element metadata.
- Ephemeral element refs.
- `AXPress` targeting.
- Secure-field redaction.
- Tree limits and timeouts.

Acceptance:

- A standard macOS button can be clicked by element reference.
- A text field can be focused by reference.
- Secure text values never appear in output.
- An invalidated element gives `stale_element`.
- An unresponsive accessibility subtree does not hang Eva.

### Phase 5: Remaining input and hardening

Implement:

- `double_click`
- `drag`
- Multiple display selection
- Stronger helper restart behavior
- Menu Quit behavior
- Documentation and manual smoke checklist
- Release-build helper packaging

Acceptance:

- Multiple displays map coordinates correctly.
- Dragging cannot leave the mouse button held down.
- Clean Quit does not relaunch in a loop.
- Crash restart works.
- All automated checks pass.

### Phase 6: Distribution, only after the MVP works

Later work:

- Developer ID signing.
- Hardened Runtime.
- Notarization.
- Universal binary if needed.
- Installer.
- Stable permission-preserving upgrades.
- Real per-action approval UI.

Do not start this phase until the local observe–act–verify loop is reliable.

## 19. Testing

### Elixir tests

Test:

- Tool names, descriptions, schemas, and sequential execution mode.
- JSONL fragmented input.
- Multiple frames in one chunk.
- Malformed JSON.
- Request/response correlation.
- Request timeout.
- Helper exit with pending calls.
- Screenshot response conversion.
- Argument validation.
- Errors returned as usable tool results.

Use an executable fake helper under `test/support`. Configure the helper command in test rather than launching the real app.

### Swift tests

Test pure logic:

- Request decoding.
- Response encoding.
- Invalid methods and params.
- Coordinate transforms.
- Bounds validation.
- Keyboard normalization.
- Observation/reference invalidation.
- Secure-field redaction helpers.

Native UI automation itself requires manual integration tests; do not create a giant mocking framework for Apple APIs.

### Manual smoke test

Document and perform:

1. Build and start the extension.
2. Confirm the menu-bar icon appears.
3. Grant Accessibility permission.
4. Grant Screen Recording permission.
5. Restart if macOS requires it.
6. Open TextEdit.
7. Observe the display.
8. Locate the focused TextEdit window.
9. Enable automation from the menu.
10. Type a known sentence.
11. Click a standard control.
12. Pause automation.
13. Confirm subsequent actions are rejected.
14. Change foreground applications between observation and action.
15. Confirm stale-state protection rejects the action.
16. Stop the extension and confirm the helper exits.

## 20. Development commands

Expected workflow:

```bash
cd /Users/aayushmau5/Documents/my-projects/eva-ext-desktop-mac
EVA_CORE_PATH=../eva/core mix deps.get
./scripts/build_helper
EVA_CORE_PATH=../eva/core mix compile --warnings-as-errors
EVA_CORE_PATH=../eva/core mix test
swift test --package-path native/EvaDesktopHelper
```

Register and run through Eva:

```bash
cd /Users/aayushmau5/Documents/my-projects/eva
mix eva.ext.add ../eva-ext-desktop-mac
mix eva.ext.start desktop_mac
mix eva.ext.list
```

During active extension development, running the extension through `iex -S mix` is acceptable if it follows the same Eva project-extension discovery pattern as `eva-mcp`.

Add a local `mix precommit` alias in the new extension that runs:

- Helper build.
- Elixir compile with warnings as errors.
- Dependency cleanup check.
- Elixir formatting.
- Elixir tests.
- Swift tests.

If implementation requires any change inside the main Eva repository, run Eva’s own:

```bash
mix precommit
```

after those changes.

## 21. Definition of done

The MVP is complete when all of the following are true:

- `eva-ext-desktop-mac` is an independent Mix project.
- Eva discovers it as `desktop_mac`.
- Its menu-bar helper launches without a Dock icon.
- Permission state is visible from the menu.
- Automation begins paused and can only be enabled locally.
- `desktop_status` reports real state.
- `desktop_observe` returns a current screenshot and compact AX snapshot.
- `desktop_action` can click, type, send keys, scroll, and wait.
- Semantic element targeting works for standard controls.
- Coordinate fallback correctly handles Retina scaling.
- Actions reject stale observations.
- Secure fields are redacted.
- Every successful action returns a fresh screenshot.
- Helper crashes and permission failures produce clear errors.
- The helper exits with the extension and does not become orphaned.
- Automated Elixir and Swift tests pass.
- The documented TextEdit smoke test succeeds.
- No changes to Eva core were required unless a concrete blocker was found and explained.
