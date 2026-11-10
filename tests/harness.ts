/**
 * Test harness for `bitty-terminal.beacon`: runs `lua/beacon/init.lua` in a
 * real Lua VM (`wasmoon`) against `bitty-plugin-sdk`'s `MockHost` augmented
 * with the W-29 `bitty.ui.targets` and `bitty.ui.labels` host bridge.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { MockHost } from "bitty-plugin-sdk";
import { LuaFactory, type LuaEngine } from "wasmoon";

const REPO_ROOT = fileURLToPath(new URL("..", import.meta.url));
export const MANIFEST_SOURCE = readFileSync(
  join(REPO_ROOT, "bitty-plugin.toml"),
  "utf8",
);
export const README_SOURCE = readFileSync(join(REPO_ROOT, "README.md"), "utf8");
export const ENTRY_SOURCE = readFileSync(
  join(REPO_ROOT, "lua/beacon/init.lua"),
  "utf8",
);

export const BEACON_CAPABILITIES = [
  "ui.rich",
  "ui.overlay",
  "ui.overlay.focus",
  "workspace.read",
  "workspace.control",
] as const;

export const START_COMMAND = "bitty-terminal.beacon:start";
export const GOTO_WORKSPACE_COMMAND = "bitty-terminal.beacon:goto-workspace";
export const MOVE_PANEL_COMMAND = "bitty-terminal.beacon:move-panel";
export const PICK_COMMAND = "bitty-terminal.beacon:pick";
export const CANCEL_COMMAND = "bitty-terminal.beacon:cancel";

export interface CoreTargetSeed {
  readonly id: number;
  readonly kind: "workspace" | "panel" | "block" | "node" | "link";
  readonly workspace?: number;
  readonly rect?: readonly [number, number, number, number];
  readonly generation?: number;
}

export interface BeaconRun {
  readonly host: MockHost;
  readonly lua: LuaEngine;
  query(expr: string): Promise<unknown>;
  setCoreTargets(targets: readonly CoreTargetSeed[]): void;
  retireCoreTarget(kind: string, id: number): void;
  bumpCoreTargetGeneration(kind: string, id: number): void;
  activeTargetingSession(): boolean;
  close(): void;
}

export interface BeaconRunOptions {
  readonly grants?: readonly string[];
  readonly settings?: Readonly<Record<string, unknown>>;
  readonly safeMode?: boolean;
  readonly pluginApiVersion?: string;
  readonly coreTargets?: readonly CoreTargetSeed[];
  readonly workspaces?: ReadonlyArray<{
    readonly id: number;
    readonly name: string;
    readonly active?: boolean;
    readonly panels?: number;
  }>;
}

const DEFAULT_CORE_TARGETS: readonly CoreTargetSeed[] = [
  {
    id: 1,
    kind: "workspace",
    workspace: 1,
    rect: [2, 0, 12, 1],
    generation: 1,
  },
  {
    id: 2,
    kind: "workspace",
    workspace: 2,
    rect: [60, 0, 12, 1],
    generation: 1,
  },
  { id: 10, kind: "panel", workspace: 1, rect: [0, 1, 40, 23], generation: 1 },
  { id: 11, kind: "panel", workspace: 1, rect: [40, 1, 40, 23], generation: 1 },
];

const DEFAULT_WORKSPACES = [
  { id: 1, name: "main", active: true, panels: 2 },
  { id: 2, name: "ops", active: false, panels: 1 },
];

const factory = new LuaFactory();

function validateCharset(raw: unknown, role: string): string[] {
  if (typeof raw !== "string") {
    throw new Error(
      `[E_DEF_INVALID] ui.labels.set_policy ${role} must be a string`,
    );
  }
  if (raw.length === 0 || raw.length > 64) {
    throw new Error(
      `[E_DEF_INVALID] invalid label charset: ${role} charset length`,
    );
  }
  const chars = [...raw];
  const seen = new Set<string>();
  for (const ch of chars) {
    if (!/^[a-z0-9]$/.test(ch)) {
      throw new Error(
        `[E_DEF_INVALID] invalid label charset: ${role} must be [a-z0-9]`,
      );
    }
    if (seen.has(ch)) {
      throw new Error(
        `[E_DEF_INVALID] invalid label charset: duplicate '${ch}'`,
      );
    }
    seen.add(ch);
  }
  return chars;
}

function sideLabels(
  pool: string[],
  overflow: string[],
  count: number,
): string[] {
  const capacity = pool.length + pool.length * overflow.length;
  if (count > capacity) {
    throw new Error(
      `[E_DEF_LIMIT] too many hint targets: requested ${count}, capacity ${capacity}`,
    );
  }
  const out: string[] = [];
  for (const ch of pool) {
    if (out.length >= count) break;
    out.push(ch);
  }
  for (const first of pool) {
    for (const second of overflow) {
      if (out.length >= count) return out;
      out.push(`${first}${second}`);
    }
  }
  return out;
}

function assignLabels(
  home: string[],
  overflow: string[],
  anchors: ReadonlyArray<{ x: number; y: number }>,
  viewportWidth: number,
): string[] {
  const mid = Math.max(1, Math.min(home.length, Math.floor(home.length / 2)));
  const leftPool = home.slice(0, mid);
  const rightPool = mid >= home.length ? home : home.slice(mid);

  const left: number[] = [];
  const right: number[] = [];
  anchors.forEach((pt, idx) => {
    if (pt.x * 2 < viewportWidth) {
      left.push(idx);
    } else {
      right.push(idx);
    }
  });
  left.sort(
    (a, b) => anchors[a]!.y - anchors[b]!.y || anchors[a]!.x - anchors[b]!.x,
  );
  right.sort(
    (a, b) => anchors[a]!.y - anchors[b]!.y || anchors[a]!.x - anchors[b]!.x,
  );

  const leftAssigned = sideLabels(leftPool, overflow, left.length);
  const rightAssigned = sideLabels(rightPool, overflow, right.length);

  const out = new Array<string>(anchors.length).fill("");
  left.forEach((origIdx, pos) => {
    out[origIdx] = leftAssigned[pos]!;
  });
  right.forEach((origIdx, pos) => {
    out[origIdx] = rightAssigned[pos]!;
  });
  return out;
}

function nilSafe<T>(table: T): T {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(table as Record<string, unknown>)) {
    if (typeof value === "function") {
      out[key] = (...args: unknown[]): unknown => {
        const result = (value as (...a: unknown[]) => unknown)(...args);
        return result === null ? undefined : result;
      };
    } else if (
      value !== null &&
      typeof value === "object" &&
      !Array.isArray(value)
    ) {
      out[key] = nilSafe(value);
    } else {
      out[key] = value;
    }
  }
  return out as T;
}

export async function activateBeacon(
  options: BeaconRunOptions = {},
): Promise<BeaconRun> {
  const host = new MockHost({
    manifestSource: MANIFEST_SOURCE,
    ...(options.safeMode !== undefined ? { safeMode: options.safeMode } : {}),
    ...(options.pluginApiVersion !== undefined
      ? { pluginApiVersion: options.pluginApiVersion }
      : {}),
  });

  for (const capability of options.grants ?? BEACON_CAPABILITIES) {
    host.grant(capability);
  }

  const wsRows = (options.workspaces ?? DEFAULT_WORKSPACES).map((w, idx) => ({
    id: w.id,
    seq: idx + 1,
    name: w.name,
    active: w.active === true,
    panel_count: w.panels ?? 1,
    scratchpad_occupied: false,
    attention: { bell: false, activity: false, exit_failure: false },
  }));
  host.setWorkspaces(wsRows as never);

  let coreTargets: CoreTargetSeed[] = [
    ...(options.coreTargets ?? DEFAULT_CORE_TARGETS),
  ];
  const lenses = new Map<
    string,
    {
      tier: string;
      targets: Array<{ kind: string; id: number; generation: number }>;
    }
  >();
  let homeCharset = validateCharset("asdfghjkl", "home");
  let overflowCharset = validateCharset("asdfghjkl", "overflow");
  let sessionOverlayHandle: number | null = null;
  let bindings = new Map<
    string,
    { kind: string; id: number; generation: number; command: string }
  >();

  const requireOverlayCap = (): void => {
    if (options.safeMode === true || !host.hasCapability("ui.overlay")) {
      throw new Error(
        "[E_CAPABILITY_DENIED] capability 'ui.overlay' is not granted",
      );
    }
  };

  const collectEntries = (): Array<{
    handle: number;
    id: number;
    kind: string;
    tier: string;
    workspace: number | undefined;
    rect: number[] | undefined;
    generation: number;
  }> => {
    const all: Array<{
      handle: number;
      id: number;
      kind: string;
      tier: string;
      workspace: number | undefined;
      rect: number[] | undefined;
      generation: number;
    }> = [];
    for (const row of coreTargets) {
      all.push({
        handle: all.length + 1,
        id: row.id,
        kind: row.kind,
        tier: "core",
        workspace:
          row.workspace ?? (row.kind === "workspace" ? row.id : undefined),
        rect: row.rect ? [...row.rect] : undefined,
        generation: row.generation ?? 1,
      });
    }
    for (const [, lens] of lenses) {
      for (const t of lens.targets) {
        all.push({
          handle: all.length + 1,
          id: t.id,
          kind: t.kind,
          tier: "derived",
          workspace: t.kind === "workspace" ? t.id : undefined,
          rect: undefined,
          generation: t.generation,
        });
      }
    }
    return all;
  };

  const uiTable = host.bitty.ui as unknown as Record<string, unknown>;
  const origOverlay = host.bitty.ui.overlay;
  const origOverlayAcquire = origOverlay.acquire.bind(origOverlay);
  const origOverlayUpdate = origOverlay.update.bind(origOverlay);
  const origOverlayPoll = origOverlay.poll.bind(origOverlay);
  const origOverlayRelease = origOverlay.release.bind(origOverlay);

  let nextOverlayBlockHandle = 100;
  const mountedBlocks = new Map<
    number,
    { slot: string; component: Record<string, unknown> }
  >();
  const captureHandleByOverlay = new Map<number, number>();

  uiTable["mount"] = (slot: string, component: Record<string, unknown>) => {
    if (options.safeMode === true || !host.hasCapability("ui.rich")) {
      throw new Error(
        "[E_CAPABILITY_DENIED] capability 'ui.rich' is not granted",
      );
    }
    if (slot === "overlay") {
      requireOverlayCap();
    }
    const handle = ++nextOverlayBlockHandle;
    mountedBlocks.set(handle, { slot, component });
    return handle;
  };

  uiTable["update"] = (handle: number, component: Record<string, unknown>) => {
    if (options.safeMode === true || !host.hasCapability("ui.rich")) {
      throw new Error(
        "[E_CAPABILITY_DENIED] capability 'ui.rich' is not granted",
      );
    }
    const block = mountedBlocks.get(handle);
    if (!block) {
      return false;
    }
    block.component = component;
    const capHandle = captureHandleByOverlay.get(handle);
    if (capHandle !== undefined) {
      try {
        origOverlayUpdate(capHandle, component);
      } catch {
        // ignore if capture session already released
      }
    }
    return true;
  };

  uiTable["unmount"] = (handle: number) => {
    if (options.safeMode === true || !host.hasCapability("ui.rich")) {
      throw new Error(
        "[E_CAPABILITY_DENIED] capability 'ui.rich' is not granted",
      );
    }
    captureHandleByOverlay.delete(handle);
    return mountedBlocks.delete(handle);
  };

  uiTable["overlay"] = {
    acquire(handleOrSpec?: unknown) {
      if (typeof handleOrSpec === "number") {
        const capHandle = origOverlayAcquire({ title: "Beacon" });
        captureHandleByOverlay.set(handleOrSpec, capHandle);
        return capHandle;
      }
      return origOverlayAcquire(handleOrSpec as never);
    },
    update(handle: number, scene: Record<string, unknown>) {
      const capHandle = captureHandleByOverlay.get(handle) ?? handle;
      return origOverlayUpdate(capHandle, scene);
    },
    poll(handle: number) {
      const capHandle = captureHandleByOverlay.get(handle) ?? handle;
      return origOverlayPoll(capHandle);
    },
    release(handle: number, reason?: string | null) {
      const capHandle = captureHandleByOverlay.get(handle) ?? handle;
      captureHandleByOverlay.delete(handle);
      return origOverlayRelease(capHandle, reason);
    },
  };

  uiTable["targets"] = {
    snapshot(max?: number) {
      requireOverlayCap();
      const cap =
        max === undefined ? 64 : Math.max(0, Math.min(64, Math.floor(max)));
      return collectEntries().slice(0, cap);
    },
    register(def: Record<string, unknown>) {
      requireOverlayCap();
      if (typeof def !== "object" || def === null) {
        throw new Error(
          "[E_DEF_INVALID] ui.targets.register definition must be a table",
        );
      }
      const name = def["name"];
      const tier = def["tier"];
      const rawTargets = def["targets"];
      if (typeof name !== "string" || name.length === 0 || name.length > 64) {
        throw new Error("[E_DEF_INVALID] ui.targets.register name invalid");
      }
      if (tier === "core") {
        throw new Error(
          "[E_DEF_INVALID] the 'core' provider tier is not registrable from Lua",
        );
      }
      if (tier !== "plugin" && tier !== "derived") {
        throw new Error(
          `[E_DEF_INVALID] unknown provider tier '${String(tier)}'`,
        );
      }
      if (!Array.isArray(rawTargets)) {
        throw new Error(
          "[E_DEF_INVALID] ui.targets.register targets must be an array",
        );
      }
      const parsed: Array<{ kind: string; id: number; generation: number }> =
        [];
      for (const item of rawTargets) {
        const rec = item as Record<string, unknown>;
        const kind = rec["kind"];
        const id = rec["id"];
        if (
          typeof kind !== "string" ||
          !["workspace", "panel", "block", "node", "link"].includes(kind) ||
          typeof id !== "number" ||
          id < 0
        ) {
          throw new Error("[E_DEF_INVALID] invalid target offer");
        }
        parsed.push({ kind, id, generation: 1 });
      }
      lenses.set(name, { tier, targets: parsed });
      return true;
    },
    unregister(name: string) {
      requireOverlayCap();
      if (typeof name !== "string") {
        throw new Error(
          "[E_DEF_INVALID] ui.targets.unregister name must be a string",
        );
      }
      return lenses.delete(name);
    },
    session_start(
      overlayHandle: number,
      width: number,
      anchorsRaw: unknown,
      commandsRaw: unknown,
    ) {
      requireOverlayCap();
      if (typeof overlayHandle !== "number" || overlayHandle <= 0) {
        throw new Error("[E_DEF_INVALID] handle must be a positive integer");
      }
      if (typeof width !== "number" || width < 0 || width > 65535) {
        throw new Error("[E_DEF_INVALID] width must be in 0..=65535");
      }
      // Acquire transient overlay capture first (checks ui.overlay.focus and safe mode).
      host.bitty.ui.overlay.acquire(overlayHandle as never);
      try {
        const entries = collectEntries();
        const anchorsArr = Array.isArray(anchorsRaw) ? anchorsRaw : [];
        const commandsArr = Array.isArray(commandsRaw) ? commandsRaw : [];
        if (
          anchorsArr.length !== entries.length ||
          commandsArr.length !== entries.length
        ) {
          throw new Error(
            `[E_DEF_INVALID] targeting session expected ${entries.length} anchors and commands`,
          );
        }
        const points = entries.map((entry, idx) => {
          const anchor = anchorsArr[idx] as { x: number; y: number };
          if (entry.kind === "panel" && entry.rect !== undefined) {
            return { x: entry.rect[0]!, y: entry.rect[1]! };
          }
          return { x: Number(anchor.x ?? 0), y: Number(anchor.y ?? 0) };
        });
        const assigned = assignLabels(
          homeCharset,
          overflowCharset,
          points,
          width,
        );
        const nextBindings = new Map<
          string,
          { kind: string; id: number; generation: number; command: string }
        >();
        entries.forEach((entry, idx) => {
          const cmd = String(commandsArr[idx] ?? "");
          if (!cmd.includes(":")) {
            throw new Error(
              "[E_DEF_INVALID] targeting session command id is not a qualified command",
            );
          }
          nextBindings.set(assigned[idx]!, {
            kind: entry.kind,
            id: entry.id,
            generation: entry.generation,
            command: cmd,
          });
        });
        bindings = nextBindings;
        sessionOverlayHandle = overlayHandle;
        return assigned;
      } catch (err) {
        try {
          host.bitty.ui.overlay.release(overlayHandle);
        } catch {
          // ignore release error on rollback
        }
        sessionOverlayHandle = null;
        bindings.clear();
        throw err;
      }
    },
    session_cancel(overlayHandle: number) {
      const owned = sessionOverlayHandle === overlayHandle;
      if (owned) {
        sessionOverlayHandle = null;
        bindings.clear();
      }
      const released = host.bitty.ui.overlay.release(overlayHandle);
      return owned || Boolean(released);
    },
    dispatch(label: string) {
      requireOverlayCap();
      if (typeof label !== "string" || label.length === 0) {
        throw new Error(
          "[E_DEF_INVALID] ui.targets.dispatch label must be non-empty",
        );
      }
      if (sessionOverlayHandle === null) {
        throw new Error(
          "[E_UI_NOT_OWNER] no active targeting session for this generation",
        );
      }
      const bound = bindings.get(label);
      if (bound === undefined) {
        throw new Error(`[E_DEF_INVALID] unknown hint label: '${label}'`);
      }
      const live = collectEntries().find(
        (e) => e.kind === bound.kind && e.id === bound.id,
      );
      if (live === undefined || live.generation !== bound.generation) {
        throw new Error(
          `[E_DEF_INVALID] stale target: ${bound.kind}#${bound.id}`,
        );
      }
      // Single-shot dispatch clears the targeting bindings.
      sessionOverlayHandle = null;
      bindings.clear();
      return bound.command;
    },
  };

  uiTable["labels"] = {
    set_policy(home: string, overflow: string) {
      requireOverlayCap();
      homeCharset = validateCharset(home, "home");
      overflowCharset = validateCharset(overflow, "overflow");
      return true;
    },
    assign(anchorsRaw: unknown, width: number) {
      requireOverlayCap();
      const anchorsArr = Array.isArray(anchorsRaw) ? anchorsRaw : [];
      const points = anchorsArr.map((a) => ({
        x: Number((a as { x?: number }).x ?? 0),
        y: Number((a as { y?: number }).y ?? 0),
      }));
      return assignLabels(homeCharset, overflowCharset, points, width);
    },
  };

  host.beginActivation();
  for (const [key, value] of Object.entries(options.settings ?? {})) {
    host.bitty.settings.set(key, value as never);
  }

  const lua = await factory.createEngine({ injectObjects: false });
  lua.global.set("bitty", nilSafe(host.bitty));

  const run: BeaconRun = {
    host,
    lua,
    async query(expr: string): Promise<unknown> {
      return lua.doString(`return ${expr}`);
    },
    setCoreTargets(targets: readonly CoreTargetSeed[]): void {
      coreTargets = [...targets];
    },
    retireCoreTarget(kind: string, id: number): void {
      coreTargets = coreTargets.filter(
        (t) => !(t.kind === kind && t.id === id),
      );
    },
    bumpCoreTargetGeneration(kind: string, id: number): void {
      coreTargets = coreTargets.map((t) =>
        t.kind === kind && t.id === id
          ? { ...t, generation: (t.generation ?? 1) + 1 }
          : t,
      );
    },
    activeTargetingSession(): boolean {
      return sessionOverlayHandle !== null;
    },
    close(): void {
      lua.global.close();
    },
  };

  try {
    await lua.doString(ENTRY_SOURCE);
    host.endActivation();
  } catch (error) {
    lua.global.close();
    throw error;
  }

  return run;
}

export function dispatch(
  run: BeaconRun,
  command: string,
  args: unknown = {},
): unknown {
  return run.host.dispatchCommand(command, args);
}

export async function pump(run: BeaconRun): Promise<void> {
  await run.lua.doString("beacon.pump()");
}

export async function pressKey(
  run: BeaconRun,
  key: string,
  mods: { ctrl?: boolean; alt?: boolean; shift?: boolean } = {},
): Promise<void> {
  run.host.injectOverlayInput({
    type: "key",
    data: {
      key,
      ctrl: mods.ctrl === true,
      alt: mods.alt === true,
      shift: mods.shift === true,
    },
  });
  await pump(run);
}

export async function typeText(run: BeaconRun, text: string): Promise<void> {
  run.host.injectOverlayInput({
    type: "text",
    data: { text },
  });
  await pump(run);
}
