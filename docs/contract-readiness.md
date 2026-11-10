# Contract readiness

Beacon's repository boundary and host contract surfaces are ready and verified against `bitty` `v0.0.39`:

- **Mechanism/policy split (ADR 0018)**: Core retains `TargetEngine`, `AnnotationEngine`, `TargetRef` generation handles, `HintAnnotationLayer` compositor rendering (`paint_target_annotations`), and `TargetDispatcher` validation; `bitty-terminal.beacon` owns only the replaceable Lua policy layer (chord vocabulary, operator modes, target scopes, home-row/overflow label charsets, and target-first action menu).
- **Focusable overlay and transient input capture (W-01)**: `bitty.ui.overlay.{acquire,update,poll,release}` and `overlay.input.available` / `overlay.released` observation events are accepted and wired in both Core and `bitty-plugin-sdk`.
- **Targeting and label host surface (W-29)**: `bitty.ui.targets.{snapshot,register,unregister,session_start,session_cancel,dispatch}`, `bitty.ui.labels.{set_policy,assign}`, and live Core workspace/panel anchor publication (`LiveTargets`) are implemented and tested in Core.
- **Least-privilege capabilities**: `ui.rich`, `ui.overlay`, `ui.overlay.focus`, `workspace.read`, and `workspace.control`. No private first-party channel, raw host handle, or hot-path callback is used.
