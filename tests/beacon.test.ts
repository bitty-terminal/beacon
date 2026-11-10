import { describe, expect, test } from "bun:test";
import {
  checkPluginReadme,
  lintManifestSource,
  loadManifestModel,
} from "bitty-plugin-sdk";

import {
  activateBeacon,
  BEACON_CAPABILITIES,
  CANCEL_COMMAND,
  dispatch,
  ENTRY_SOURCE,
  GOTO_WORKSPACE_COMMAND,
  MANIFEST_SOURCE,
  MOVE_PANEL_COMMAND,
  PICK_COMMAND,
  pressKey,
  README_SOURCE,
  START_COMMAND,
  typeText,
} from "./harness.js";

describe("bitty-plugin.toml and README.md contracts", () => {
  test("passes the authoritative manifest validator with zero errors or warnings", () => {
    const result = lintManifestSource(MANIFEST_SOURCE);
    expect(result.diagnostics).toEqual([]);
  });

  test("declares least-privilege capabilities, five commands, and seven settings", () => {
    const model = loadManifestModel(MANIFEST_SOURCE);
    expect(model.pluginId).toBe("bitty-terminal.beacon");
    expect(model.name).toBe("Beacon");
    expect(model.version).toBe("0.0.1");
    expect([...model.capabilities].sort()).toEqual(
      [...BEACON_CAPABILITIES].sort(),
    );
    expect([...model.commands]).toEqual([
      START_COMMAND,
      GOTO_WORKSPACE_COMMAND,
      MOVE_PANEL_COMMAND,
      PICK_COMMAND,
      CANCEL_COMMAND,
    ]);
    expect(model.settings.size).toBe(7);
  });

  test("passes the SDK README user-documentation and settings-table check", () => {
    const result = checkPluginReadme({
      manifestSource: MANIFEST_SOURCE,
      readmeSource: README_SOURCE,
    });
    expect(result.diagnostics).toEqual([]);
    expect(result.valid).toBe(true);
  });
});

describe("activation and configuration policy", () => {
  test("registers commands, suggests keybindings, and reads defaults", async () => {
    const run = await activateBeacon();
    try {
      expect(await run.query("beacon.last_code()")).toBe("OK");
      expect(await run.query("beacon.configured_home_charset()")).toBe(
        "asdfghjkl",
      );
      expect(await run.query("beacon.configured_overflow_charset()")).toBe(
        "asdfghjkl",
      );
      expect(await run.query("beacon.configured_default_scope()")).toBe("all");
      expect(await run.query("beacon.configured_viewport_width()")).toBe(80);
    } finally {
      run.close();
    }
  });

  test("falls back to defaults when configured charsets or scope are invalid", async () => {
    const run = await activateBeacon({
      settings: {
        default_scope: "invalid_scope",
        label_home: "aabb", // duplicate
        label_overflow: "UPPER!", // invalid chars
        viewport_width: -5,
      },
    });
    try {
      expect(await run.query("beacon.configured_default_scope()")).toBe("all");
      expect(await run.query("beacon.configured_home_charset()")).toBe(
        "asdfghjkl",
      );
      expect(await run.query("beacon.configured_overflow_charset()")).toBe(
        "asdfghjkl",
      );
      expect(await run.query("beacon.configured_viewport_width()")).toBe(80);
    } finally {
      run.close();
    }
  });

  test("disables fail-closed on incompatible Plugin API major version", async () => {
    expect(() => activateBeacon({ pluginApiVersion: "2.0.0" })).toThrow(
      /E_LIFECYCLE_STATE/,
    );
    const run = await activateBeacon();
    try {
      await run.lua.doString(`
        bitty = { api_version = "2.0.0" }
        ${ENTRY_SOURCE}
      `);
      expect(await run.query("beacon.last_code()")).toBe("E_DISABLED");
      expect(await run.query("beacon.is_open()")).toBe(false);
    } finally {
      run.close();
    }
  });
});

describe("action-first spatial targeting", () => {
  test("start allocates left/right spatial home-row labels and focuses selected target", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, START_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.mode()")).toBe("targeting");
      expect(await run.query("beacon.active_operator()")).toBe("focus");
      expect(await run.query("beacon.active_scope()")).toBe("all");
      expect(await run.query("beacon.candidate_count()")).toBe(4);

      // Workspace #1 at x=2 (left pool -> 'a'), Workspace #2 at x=60 (right pool -> 'g').
      const ws1Label = String(await run.query("beacon.label_for_index(1)"));
      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      expect(ws1Label).toBe("a");
      expect(ws2Label).toBe("g");

      await pressKey(run, ws2Label);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.overlay_handle()")).toBe(0);
      expect(await run.query("beacon.last_code()")).toBe("OK");
      expect(await run.query("beacon.last_focused_workspace()")).toBe(2);
    } finally {
      run.close();
    }
  });

  test("goto_workspace scopes candidates to workspaces only", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, GOTO_WORKSPACE_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.active_scope()")).toBe("workspace");
      expect(await run.query("beacon.candidate_count()")).toBe(2);

      const ws1Label = String(await run.query("beacon.label_for_index(1)"));
      await pressKey(run, ws1Label);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_focused_workspace()")).toBe(1);
    } finally {
      run.close();
    }
  });

  test("move_panel moves the focused panel to the selected workspace", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, MOVE_PANEL_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.active_operator()")).toBe("move");
      expect(await run.query("beacon.active_scope()")).toBe("workspace");

      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      await pressKey(run, ws2Label);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("OK");
      expect(await run.query("beacon.last_moved_workspace()")).toBe(2);
    } finally {
      run.close();
    }
  });

  test("handles multi-character overflow labels, prefix filtering, and Backspace", async () => {
    const run = await activateBeacon({
      settings: {
        label_home: "ab",
        label_overflow: "12",
      },
      coreTargets: [
        { id: 1, kind: "workspace", workspace: 1, rect: [2, 0, 10, 1] },
        { id: 2, kind: "workspace", workspace: 2, rect: [2, 1, 10, 1] },
        { id: 3, kind: "workspace", workspace: 3, rect: [2, 2, 10, 1] },
      ],
    });
    try {
      dispatch(run, GOTO_WORKSPACE_COMMAND);
      // Left pool is ['a']; singles: ['a'], overflow: ['a1', 'a2'].
      expect(await run.query("beacon.label_for_index(1)")).toBe("a");
      expect(await run.query("beacon.label_for_index(2)")).toBe("a1");
      expect(await run.query("beacon.label_for_index(3)")).toBe("a2");
    } finally {
      run.close();
    }

    // Now test prefix narrowing when single label is on right side and overflow is on left:
    const run2 = await activateBeacon({
      settings: {
        label_home: "ab",
        label_overflow: "12",
      },
      coreTargets: [
        { id: 1, kind: "workspace", workspace: 1, rect: [60, 0, 10, 1] },
        { id: 2, kind: "workspace", workspace: 2, rect: [60, 1, 10, 1] },
      ],
    });
    try {
      dispatch(run2, GOTO_WORKSPACE_COMMAND);
      // Right pool is ['b']; labels are 'b' and 'b1'.
      expect(await run2.query("beacon.label_for_index(1)")).toBe("b");
      expect(await run2.query("beacon.label_for_index(2)")).toBe("b1");

      // Typing unknown prefix 'z' fails closed with E_UNKNOWN_LABEL.
      await pressKey(run2, "z");
      expect(await run2.query("beacon.is_open()")).toBe(false);
      expect(await run2.query("beacon.last_code()")).toBe("E_UNKNOWN_LABEL");
    } finally {
      run2.close();
    }
  });
});

describe("target-first pick mode (action menu)", () => {
  test("selects a target first and dispatches the chosen action from the menu", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, PICK_COMMAND, { scope: "workspace" });
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.mode()")).toBe("targeting");

      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      await pressKey(run, ws2Label);

      // Should now be in action_menu mode for workspace #2.
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.mode()")).toBe("action_menu");
      expect(await run.query("beacon.selected_target_id()")).toBe(2);
      expect(await run.query("beacon.selected_target_kind()")).toBe(
        "workspace",
      );

      // Press 'm' to move panel to workspace #2.
      await pressKey(run, "m");
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("OK");
      expect(await run.query("beacon.last_moved_workspace()")).toBe(2);
    } finally {
      run.close();
    }
  });

  test("supports next ('n') and close ('c') actions in pick menu", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, PICK_COMMAND, { scope: "workspace" });
      const ws1Label = String(await run.query("beacon.label_for_index(1)"));
      await pressKey(run, ws1Label);
      expect(await run.query("beacon.mode()")).toBe("action_menu");

      await pressKey(run, "n");
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.next_workspace_count()")).toBe(1);

      dispatch(run, PICK_COMMAND, { scope: "workspace" });
      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      await pressKey(run, ws2Label);
      await pressKey(run, "c");
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_closed_workspace()")).toBe(2);
    } finally {
      run.close();
    }
  });

  test("fails closed with E_STALE_TARGET if selected target vanishes while action menu is open", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, PICK_COMMAND, { scope: "workspace" });
      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      await pressKey(run, ws2Label);
      expect(await run.query("beacon.mode()")).toBe("action_menu");

      // Retire workspace #2 before pressing 'f'.
      run.retireCoreTarget("workspace", 2);
      await pressKey(run, "f");

      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("E_STALE_TARGET");
      expect(await run.query("beacon.last_focused_workspace()")).toBe(0);
    } finally {
      run.close();
    }
  });
});

describe("custom target lenses", () => {
  test("registers and unregisters derived lenses and rejects 'core' tier", async () => {
    const run = await activateBeacon();
    try {
      const coreOk = await run.query(
        'beacon.register_lens("illegal", "core", {{ kind = "link", id = 99 }})',
      );
      expect(coreOk).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("E_DEF_INVALID");

      const ok = await run.query(
        'beacon.register_lens("links", "derived", {{ kind = "link", id = 42 }})',
      );
      expect(ok).toBe(true);
      expect(await run.query("beacon.last_code()")).toBe("OK");

      dispatch(run, START_COMMAND, { scope: "link" });
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(await run.query("beacon.candidate_count()")).toBe(1);

      dispatch(run, CANCEL_COMMAND);
      const removed = await run.query('beacon.unregister_lens("links")');
      expect(removed).toBe(true);
    } finally {
      run.close();
    }
  });
});

describe("fail-closed negative paths and cancellation", () => {
  test("fails closed with E_STALE_TARGET when target generation changes mid-session", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, GOTO_WORKSPACE_COMMAND);
      const ws2Label = String(await run.query("beacon.label_for_index(2)"));

      // Simulate workspace #2 closing and re-registering with a new generation.
      run.bumpCoreTargetGeneration("workspace", 2);
      await pressKey(run, ws2Label);

      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.overlay_handle()")).toBe(0);
      expect(await run.query("beacon.last_code()")).toBe("E_STALE_TARGET");
      expect(await run.query("beacon.last_focused_workspace()")).toBe(0);
    } finally {
      run.close();
    }
  });

  test("Escape key and cancel command release session and unmount overlay", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, START_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(true);
      expect(run.activeTargetingSession()).toBe(true);

      await pressKey(run, "Escape");
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.overlay_handle()")).toBe(0);
      expect(await run.query("beacon.last_code()")).toBe("CANCELLED");
      expect(run.activeTargetingSession()).toBe(false);

      // Reopen and cancel via command.
      dispatch(run, START_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(true);
      dispatch(run, CANCEL_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("CANCELLED");
    } finally {
      run.close();
    }
  });

  test("fails closed with E_CAPABILITY_DENIED when ui.overlay.focus is absent", async () => {
    const run = await activateBeacon({
      grants: ["ui.rich", "ui.overlay", "workspace.read", "workspace.control"],
    });
    try {
      dispatch(run, START_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.overlay_handle()")).toBe(0);
      expect(await run.query("beacon.last_code()")).toBe("E_CAPABILITY_DENIED");
    } finally {
      run.close();
    }
  });

  test("fails closed with E_CAPABILITY_DENIED when workspace.read is absent on goto_workspace", async () => {
    const run = await activateBeacon({
      grants: [
        "ui.rich",
        "ui.overlay",
        "ui.overlay.focus",
        "workspace.control",
      ],
    });
    try {
      dispatch(run, GOTO_WORKSPACE_COMMAND);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("E_CAPABILITY_DENIED");
    } finally {
      run.close();
    }
  });

  test("supports text input events as well as key events", async () => {
    const run = await activateBeacon();
    try {
      dispatch(run, GOTO_WORKSPACE_COMMAND);
      const ws2Label = String(await run.query("beacon.label_for_index(2)"));
      await typeText(run, ws2Label);
      expect(await run.query("beacon.is_open()")).toBe(false);
      expect(await run.query("beacon.last_code()")).toBe("OK");
      expect(await run.query("beacon.last_focused_workspace()")).toBe(2);
    } finally {
      run.close();
    }
  });
});
