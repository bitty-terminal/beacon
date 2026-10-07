# beacon

Metadata-only official plugin candidate for jump navigation. No installable manifest or Lua implementation exists; not onboarded in the plugin registry.

Scope is this repository only. Policy uses public capability-gated APIs only; Core owns targets, generations, annotations and dispatch safety.

Prerequisites are W-81, W-90 and W-120 with umbrella bitty-terminal/bitty#1629 still open. No product implementation is authorized until contracts are accepted.

Task mapping is CTX-0001 to issue #4, CTX-0002 to #3, CTX-0003 to #2 and CTX-0004 to #1. CTX-0001 is complete in CarryCtx; CTX-0002 is in progress awaiting its accepted contract; CTX-0003 and CTX-0004 are planned and blocked.

Task tracking lives in CarryCtx, including the published carryctx-snapshots ref. Read AGENTS.md, repo.toml and the CarryCtx state before changing anything.

Verification is metadata only: just check covers formatting, Markdown, metadata presence, hygiene and portable paths. It is not Lua or SDK conformance evidence.
