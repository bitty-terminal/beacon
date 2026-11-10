# Beacon

Spatial and semantic workspace targeting policy (`Action x Target`) for the Bitty terminal.

## Overview

Beacon turns the Bitty workspace into a keyboard-addressable surface inspired by `flash.nvim` and Which-Key. Instead of cycling sequentially through panels or workspaces, pressing a single Beacon chord collects a live target snapshot (`bitty.ui.targets.snapshot`), assigns ergonomic home-row labels (`bitty.ui.labels.set_policy` / `bitty.ui.targets.session_start`), presents spatial hint badges directly over targets on the compositor annotation layer alongside a compact status/picker overlay, and dispatches the selected command or workspace mutation after Core revalidates the target's generation handle (`bitty.ui.targets.dispatch`).

Beacon is pure policy over the accepted Core mechanism/policy split (ADR 0018):

- **Action-first operators**: jump directly to any workspace or panel (`start`, `goto-workspace`) or move the focused panel to a labeled workspace (`move-panel`).
- **Target-first picker (`pick`)**: select any labeled target first, then choose an action from the in-overlay action menu (`[f]` Focus workspace, `[m]` Move focused panel here, `[n]` Next workspace, `[c]` Close workspace, `[Esc]` Cancel).
- **Spatial home-row allocation**: single-character home-row labels come first (split into left-hand and right-hand spatial pools around the viewport center), spilling to two-character overflow labels when needed.
- **Fail-closed generation safety**: every label selection is validated against Core's live `TargetRegistry`; stale targets (`StaleTarget`), unknown labels, and revoked capabilities fail closed and immediately release both the targeting session and overlay block.

## Install

Prerequisites: Bitty `>=0.0.31` and Plugin API `^1.0`.

From the official registry or directly from this repository:

```sh
bitty plugin install https://github.com/bitty-terminal/beacon.git
bitty plugin enable bitty-terminal.beacon
bitty plugin list
```

From a local checkout:

```sh
bitty plugin install ./beacon --yes
bitty plugin enable bitty-terminal.beacon
```

## Commands

| Command                                | What it does                                                                                           | Arguments                          |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| `bitty-terminal.beacon:start`          | Start an action-first targeting session in the configured default scope (`all`, `workspace`, `panel`). | `{ scope?, operator? }` (optional) |
| `bitty-terminal.beacon:goto-workspace` | Start a workspace-scoped focus targeting session (`Action = focus`, `Scope = workspace`).              | None                               |
| `bitty-terminal.beacon:move-panel`     | Start a workspace-scoped panel-move targeting session (`Action = move`, `Scope = workspace`).          | None                               |
| `bitty-terminal.beacon:pick`           | Start a target-first session: select a target by label, then pick an action from the overlay menu.     | `{ scope? }` (optional)            |
| `bitty-terminal.beacon:cancel`         | Cancel any active Beacon targeting session and release overlay capture.                                | None                               |

## Configuration

| Setting           | Type     | Default       | Description                                                                                         |
| ----------------- | -------- | ------------- | --------------------------------------------------------------------------------------------------- |
| `open_chord`      | `string` | `"alt+b"`     | Suggested global shortcut for `bitty-terminal.beacon:start`.                                        |
| `workspace_chord` | `string` | `"alt+g"`     | Suggested global shortcut for `bitty-terminal.beacon:goto-workspace`.                               |
| `move_chord`      | `string` | `"alt+m"`     | Suggested global shortcut for `bitty-terminal.beacon:move-panel`.                                   |
| `default_scope`   | `string` | `"all"`       | Default target scope for `start` and `pick` (`all`, `workspace`, `panel`, `block`, `node`, `link`). |
| `label_home`      | `string` | `"asdfghjkl"` | Home-row label charset (`[a-z0-9]`, duplicate-free, split into left/right spatial pools).           |
| `label_overflow`  | `string` | `"asdfghjkl"` | Second-character overflow charset (`[a-z0-9]`, duplicate-free) when targets exceed single labels.   |
| `viewport_width`  | `int`    | `80`          | Viewport width in cells (`1..=65535`) used to partition left-hand and right-hand label pools.       |

## Keybindings

During activation, Beacon suggests three chords via `bitty.keymaps.suggest`:

| Suggested chord | Command                                | Context  |
| --------------- | -------------------------------------- | -------- |
| `alt+b`         | `bitty-terminal.beacon:start`          | `global` |
| `alt+g`         | `bitty-terminal.beacon:goto-workspace` | `global` |
| `alt+m`         | `bitty-terminal.beacon:move-panel`     | `global` |

While a Beacon session holds transient overlay capture:

- Typing a single-character label (or the two characters of an overflow label) selects the target.
- `Backspace` clears a pending two-character label prefix.
- `Escape` cancels the session cleanly without dispatching any command.
- In `pick` (target-first) action-menu mode: `f` focuses the target's workspace, `m` moves the focused panel to the target's workspace, `n` switches to the next workspace, `c` closes the target's workspace, and `Escape` cancels.

## Troubleshooting

**The shortcut does nothing.** Verify `bitty --version` is `>=0.0.31` and check `bitty plugin list` to confirm `bitty-terminal.beacon` is enabled with all five capabilities granted (`ui.rich`, `ui.overlay`, `ui.overlay.focus`, `workspace.read`, `workspace.control`).

**Selecting a label cancels without acting.** If the target panel or workspace was closed after the session opened, Core's generation check rejects the stale handle (`StaleTarget`) fail-closed and Beacon ends the session without executing a command.

**Custom `label_home` or `label_overflow` is ignored.** Charsets must be non-empty, at most 64 characters, lowercase ASCII alphanumeric (`[a-z0-9]`), and free of duplicate characters. Invalid charsets fall back to `"asdfghjkl"`.

## Capabilities

Five least-privilege grants, deny by default:

| Capability          | Why                                                                                    |
| ------------------- | -------------------------------------------------------------------------------------- |
| `ui.rich`           | Construct declarative `List` and `Text` overlay scene nodes.                           |
| `ui.overlay`        | Mount the Beacon overlay and access `bitty.ui.targets.*` and `bitty.ui.labels.*`.      |
| `ui.overlay.focus`  | Acquire bounded transient keyboard capture during an active targeting session.         |
| `workspace.read`    | Read workspace summaries and names via `bitty.workspace.list`.                         |
| `workspace.control` | Enqueue workspace `focus`, `move_panel`, `next`, and `close` actions selected by user. |
