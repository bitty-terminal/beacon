# Verification plan

Verification of `bitty-terminal.beacon` covers manifest, documentation, Lua grammar, positive and negative behavior paths, and fail-closed security invariants:

- **Manifest & README gates (`just manifest`, `just docs-check`)**: `bitty-plugin-lint` and `bitty-plugin-docs-check` from `bitty-plugin-sdk` validate `bitty-plugin.toml` and `README.md` (including exact parity between `[settings]` declarations and the `## Configuration` table).
- **Lua grammar gates (`just lua`, `just lua-control`)**: `luaparse` validates `lua/beacon/init.lua` against the Lua 5.1 grammar and verifies fail-closed rejection on malformed syntax.
- **Behavioral & negative-path suite (`just test`)**: executes `lua/beacon/init.lua` inside a real Lua VM (`wasmoon`) against `MockHost` plus the `bitty.ui.targets` / `bitty.ui.labels` host bridge, verifying:
  - Action-first operators (`start`, `goto-workspace`, `move-panel`) and target-first `pick` action menu.
  - Multi-character overflow label prefix filtering, `Backspace` edit, and `Escape` cancellation.
  - Custom lens provider registration (`register_lens` / `unregister_lens`) and rejection of the reserved `"core"` tier.
  - Fail-closed behavior on `StaleTarget` (retired generation handle), unknown labels, capability denial (`ui.overlay`, `ui.overlay.focus`, `workspace.read`, `workspace.control`), safe mode, and API major mismatch, leaving zero orphaned overlays or capture handles.
