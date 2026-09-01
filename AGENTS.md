# AGENTS.md

## Before committing

Run `mix precommit`. It builds the native helper bundle, compiles with
`--warnings-as-errors`, checks for unused deps, formats, and runs both the Elixir and
Swift test suites.

## Layout

- `lib/eva/extension/desktop_mac*` — the extension module, the application supervisor, the
  `Helper` GenServer (which will own the helper `Port`), and the tool definitions.
- `native/EvaDesktopHelper` — the menu-bar helper app. Only Apple frameworks and the Swift
  standard library. Stdout is protocol frames only; logs go to stderr.
- `scripts/build_helper` — builds the app bundle into `priv/EvaDesktopHelper.app`.

## Contract

This extension depends on `eva_core` (see `mix.exs`). Set `EVA_CORE_PATH` to build against
a local checkout of the Eva `core/` directory:

```bash
EVA_CORE_PATH=../eva/core mix deps.get
```

Eva registers the extension under the name `desktop_mac`: it strips the `eva_` prefix from
the `:eva_desktop_mac` app. The extension module is therefore `Eva.Extension.DesktopMac`.
