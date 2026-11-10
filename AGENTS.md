# Beacon repository guidance

Official spatial and semantic targeting policy plugin (`bitty-terminal.beacon`). Policy uses public capability-gated APIs only (`bitty.ui.targets.*`, `bitty.ui.labels.*`, `bitty.ui.overlay.*`, `bitty.ui.mount`/`update`/`unmount`, `bitty.workspace.*`, `bitty.commands.*`, `bitty.keymaps.suggest`, `bitty.settings.get`, `bitty.store.*`); Core owns targets, generations, `HintAnnotationLayer` rendering, transient input capture, and dispatch safety. No first-party bypass, raw host handles, or hot-path callbacks.

English only; derive host values from configuration and Git metadata. Version `0.0.1`; Bun owns JS. Run quality gates via `just check` and `just product` (`fmt-check`, `markdownlint`, `metadata`, `hygiene`, `paths`, `manifest`, `lua`, `lua-control`, `docs-check`, `test`). Phases `CTX-0001 -> CTX-0002 -> CTX-0003 -> CTX-0004` track bootstrap, contract readiness, implementation, and independent verification.
