-- Entry point for Beacon (bitty-terminal.beacon): spatial and semantic
-- workspace targeting policy over the public host API only.
--
-- Accepted mechanism/policy split (bitty-docs ADR 0018): Core owns the
-- TargetEngine, AnnotationEngine, generation-validated TargetRef handles,
-- compositor HintAnnotationLayer rendering, and transient overlay input
-- capture; Beacon owns only the replaceable Lua policy layer (chord
-- suggestions, Action x Target operator grammar, target scopes, home-row and
-- overflow label charset configuration, and the target-first action menu).
--
-- This module stays within the Lua 5.1 grammar (`just lua`) and uses no
-- private host channel, raw handle, or hot-path callback.

local M = {}

M.PLUGIN_ID = "bitty-terminal.beacon"
M.REQUIRED_API_MAJOR = 1

M.DEFAULT_OPEN_CHORD = "alt+b"
M.DEFAULT_WORKSPACE_CHORD = "alt+g"
M.DEFAULT_MOVE_CHORD = "alt+m"
M.DEFAULT_SCOPE = "all"
M.DEFAULT_HOME_CHARSET = "asdfghjkl"
M.DEFAULT_OVERFLOW_CHARSET = "asdfghjkl"
M.DEFAULT_VIEWPORT_WIDTH = 80

M.MAX_SNAPSHOT_TARGETS = 64
M.MAX_CHARSET_LEN = 64
M.MAX_VIEWPORT_WIDTH = 65535

M.CODE_OK = "OK"
M.CODE_NOT_OPEN = "NOT_OPEN"
M.CODE_DISABLED = "E_DISABLED"
M.CODE_CANCELLED = "CANCELLED"
M.CODE_RELEASED = "RELEASED"
M.CODE_UNKNOWN_LABEL = "E_UNKNOWN_LABEL"
M.CODE_STALE_TARGET = "E_STALE_TARGET"
M.CODE_NO_TARGETS = "E_NO_TARGETS"

local VALID_SCOPES = {
  all = true,
  workspace = true,
  panel = true,
  block = true,
  node = true,
  link = true,
}

local VALID_OPERATORS = {
  focus = true,
  move = true,
  pick = true,
}

-- ---------------------------------------------------------------------------
-- Pure validation helpers
-- ---------------------------------------------------------------------------

local function trim(s)
  local stripped = string.gsub(s, "^%s+", "")
  stripped = string.gsub(stripped, "%s+$", "")
  return stripped
end

function M.validate_charset(raw)
  if type(raw) ~= "string" then
    return false, "charset must be a string"
  end
  if #raw == 0 then
    return false, "charset must not be empty"
  end
  if #raw > M.MAX_CHARSET_LEN then
    return false, "charset exceeds 64 characters"
  end
  local seen = {}
  for i = 1, #raw do
    local b = string.byte(raw, i)
    local is_lower = b >= 97 and b <= 122
    local is_digit = b >= 48 and b <= 57
    if not is_lower and not is_digit then
      return false, "charset must contain only [a-z0-9]"
    end
    if seen[b] then
      return false, "charset contains duplicate character"
    end
    seen[b] = true
  end
  return true, nil
end

function M.is_valid_scope(scope)
  return type(scope) == "string" and VALID_SCOPES[scope] == true
end

function M.is_valid_operator(operator)
  return type(operator) == "string" and VALID_OPERATORS[operator] == true
end

local function is_indexable(v)
  local t = type(v)
  return t == "table" or t == "userdata"
end

local function extract_error_code(err)
  if is_indexable(err) then
    local ok_c, c = pcall(function()
      return err.code
    end)
    if ok_c and type(c) == "string" and c ~= "" then
      return c
    end
  end
  local text = tostring(err)
  if string.find(text, "stale target", 1, true) then
    return M.CODE_STALE_TARGET
  end
  if string.find(text, "unknown hint label", 1, true) then
    return M.CODE_UNKNOWN_LABEL
  end
  for _, code in ipairs({
    "E_CAPABILITY_DENIED",
    "E_UI_UNAVAILABLE",
    "E_UI_NOT_OWNER",
    "E_DEF_INVALID",
    "E_DEF_LIMIT",
    "E_NOT_IMPLEMENTED",
    "E_COMMAND_UNKNOWN",
    "E_COMMAND_GONE",
    "E_COMMAND_INVALID",
    "E_COMMAND_FAILED",
  }) do
    if string.find(text, code, 1, true) then
      return code
    end
  end
  local matched = string.match(text, "(E_[A-Z0-9_]+)")
  if matched ~= nil then
    return matched
  end
  return "E_RUNTIME"
end

-- ---------------------------------------------------------------------------
-- Plugin state
-- ---------------------------------------------------------------------------

local disabled = false
local cfg_open_chord = M.DEFAULT_OPEN_CHORD
local cfg_workspace_chord = M.DEFAULT_WORKSPACE_CHORD
local cfg_move_chord = M.DEFAULT_MOVE_CHORD
local cfg_default_scope = M.DEFAULT_SCOPE
local cfg_home = M.DEFAULT_HOME_CHARSET
local cfg_overflow = M.DEFAULT_OVERFLOW_CHARSET
local cfg_viewport_width = M.DEFAULT_VIEWPORT_WIDTH

local session_mode = "closed" -- "closed" | "targeting" | "action_menu"
local session_handle = 0
local active_operator = ""
local active_scope = ""
local active_prefix = ""
local scoped_candidates = {}
local selected_target = nil

local last_code = M.CODE_OK
local last_dispatched_command = ""
local last_focused_workspace = 0
local last_moved_workspace = 0
local last_closed_workspace = 0
local next_workspace_count = 0

local function store_set_safe(key, val)
  if is_indexable(bitty) and is_indexable(bitty.store) and type(bitty.store.set) == "function" then
    pcall(bitty.store.set, key, val)
  end
end

-- ---------------------------------------------------------------------------
-- Scene construction & session cleanup
-- ---------------------------------------------------------------------------

local function format_candidate_row(cand)
  local ws_suffix = ""
  if cand.workspace ~= nil then
    if cand.workspace_name ~= nil and cand.workspace_name ~= "" then
      ws_suffix = " [" .. cand.workspace_name .. "]"
    else
      ws_suffix = " [ws #" .. tostring(cand.workspace) .. "]"
    end
  end
  local rect_suffix = ""
  if is_indexable(cand.rect) and cand.rect[1] ~= nil and cand.rect[2] ~= nil then
    rect_suffix = " @" .. tostring(cand.rect[1]) .. "," .. tostring(cand.rect[2])
  end
  return "[" .. cand.label .. "] " .. cand.kind .. " #" .. tostring(cand.id) .. ws_suffix .. rect_suffix
end

local function visible_candidates()
  if active_prefix == "" then
    return scoped_candidates
  end
  local out = {}
  local plen = #active_prefix
  for i = 1, #scoped_candidates do
    local cand = scoped_candidates[i]
    if string.sub(cand.label, 1, plen) == active_prefix then
      out[#out + 1] = cand
    end
  end
  return out
end

local function build_scene()
  if session_mode == "action_menu" and selected_target ~= nil then
    local target_desc = selected_target.kind .. " #" .. tostring(selected_target.id)
    local items = {
      "Beacon Target: " .. target_desc .. " (choose action or Esc to cancel)",
      "[f] Focus target workspace",
      "[m] Move focused panel to target workspace",
      "[n] Switch to next workspace",
      "[c] Close target workspace",
      "[Esc] Cancel",
    }
    return {
      kind = "List",
      items = items,
    }
  end

  local vis = visible_candidates()
  local prefix_label = active_prefix ~= "" and (" | prefix: " .. active_prefix) or ""
  local header = "Beacon [" .. active_operator .. " | scope: " .. active_scope .. prefix_label .. "] (" .. tostring(#vis) .. " target(s))"
  local items = { header }
  for i = 1, #vis do
    items[#items + 1] = format_candidate_row(vis[i])
  end
  return {
    kind = "List",
    items = items,
  }
end

local function repaint_overlay()
  if session_handle > 0 and is_indexable(bitty) and is_indexable(bitty.ui) and type(bitty.ui.update) == "function" then
    pcall(bitty.ui.update, session_handle, build_scene())
  end
end

local function close_session(code)
  local handle = session_handle
  session_mode = "closed"
  session_handle = 0
  active_operator = ""
  active_scope = ""
  active_prefix = ""
  scoped_candidates = {}
  selected_target = nil
  if handle > 0 and is_indexable(bitty) and is_indexable(bitty.ui) then
    if is_indexable(bitty.ui.targets) and type(bitty.ui.targets.session_cancel) == "function" then
      pcall(bitty.ui.targets.session_cancel, handle)
    elseif is_indexable(bitty.ui.overlay) and type(bitty.ui.overlay.release) == "function" then
      pcall(bitty.ui.overlay.release, handle)
    end
    if type(bitty.ui.unmount) == "function" then
      pcall(bitty.ui.unmount, handle)
    end
  end
  if code ~= nil then
    last_code = code
  end
end

-- ---------------------------------------------------------------------------
-- Action execution
-- ---------------------------------------------------------------------------

local function resolve_workspace_id(cand)
  if type(cand.workspace) == "number" and cand.workspace > 0 then
    return cand.workspace
  end
  if cand.kind == "workspace" and type(cand.id) == "number" and cand.id > 0 then
    return cand.id
  end
  return 1
end

local function execute_operator_action(op, cand, dispatched_cmd)
  if type(dispatched_cmd) == "string" and dispatched_cmd ~= "" then
    local is_internal = string.find(dispatched_cmd, "^bitty%-terminal%.beacon:") ~= nil
    if not is_internal then
      local ok, err = pcall(bitty.commands.invoke, dispatched_cmd, {
        id = cand.id,
        kind = cand.kind,
        workspace = cand.workspace,
      })
      if not ok then
        last_code = extract_error_code(err)
        return false
      end
      last_dispatched_command = dispatched_cmd
      last_code = M.CODE_OK
      store_set_safe("beacon.last_target", cand.kind .. ":" .. tostring(cand.id))
      return true
    end
  end

  local ws_id = resolve_workspace_id(cand)
  if op == "move" then
    local ok, err = pcall(bitty.workspace.move_panel, ws_id)
    if not ok then
      last_code = extract_error_code(err)
      return false
    end
    last_moved_workspace = ws_id
    last_dispatched_command = dispatched_cmd or "bitty-terminal.beacon:move-panel"
    last_code = M.CODE_OK
    store_set_safe("beacon.last_target", cand.kind .. ":" .. tostring(cand.id))
    return true
  end

  local ok, err = pcall(bitty.workspace.focus, ws_id)
  if not ok then
    last_code = extract_error_code(err)
    return false
  end
  last_focused_workspace = ws_id
  last_dispatched_command = dispatched_cmd or "bitty-terminal.beacon:start"
  last_code = M.CODE_OK
  store_set_safe("beacon.last_target", cand.kind .. ":" .. tostring(cand.id))
  return true
end

local function target_still_live(cand)
  if not is_indexable(bitty.ui) or not is_indexable(bitty.ui.targets) or type(bitty.ui.targets.snapshot) ~= "function" then
    return false
  end
  local ok, rows = pcall(bitty.ui.targets.snapshot, M.MAX_SNAPSHOT_TARGETS)
  if not ok or not is_indexable(rows) then
    return false
  end
  for i = 1, #rows do
    local row = rows[i]
    if row.kind == cand.kind and row.id == cand.id then
      if cand.generation ~= nil and row.generation ~= nil and row.generation ~= cand.generation then
        return false
      end
      return true
    end
  end
  return false
end

local function handle_action_menu_key(ch)
  local cand = selected_target
  if cand == nil then
    close_session(M.CODE_NOT_OPEN)
    return
  end
  if not target_still_live(cand) then
    close_session(M.CODE_STALE_TARGET)
    return
  end
  local ws_id = resolve_workspace_id(cand)
  if ch == "f" then
    close_session(M.CODE_OK)
    local ok, err = pcall(bitty.workspace.focus, ws_id)
    if not ok then
      last_code = extract_error_code(err)
      return
    end
    last_focused_workspace = ws_id
    last_dispatched_command = "bitty.workspace.focus"
    store_set_safe("beacon.last_target", cand.kind .. ":" .. tostring(cand.id))
  elseif ch == "m" then
    close_session(M.CODE_OK)
    local ok, err = pcall(bitty.workspace.move_panel, ws_id)
    if not ok then
      last_code = extract_error_code(err)
      return
    end
    last_moved_workspace = ws_id
    last_dispatched_command = "bitty.workspace.move_panel"
    store_set_safe("beacon.last_target", cand.kind .. ":" .. tostring(cand.id))
  elseif ch == "n" then
    close_session(M.CODE_OK)
    local ok, err = pcall(bitty.workspace.next)
    if not ok then
      last_code = extract_error_code(err)
      return
    end
    next_workspace_count = next_workspace_count + 1
    last_dispatched_command = "bitty.workspace.next"
  elseif ch == "c" then
    close_session(M.CODE_OK)
    local ok, err = pcall(bitty.workspace.close, ws_id)
    if not ok then
      last_code = extract_error_code(err)
      return
    end
    last_closed_workspace = ws_id
    last_dispatched_command = "bitty.workspace.close"
  else
    close_session(M.CODE_UNKNOWN_LABEL)
  end
end

local function handle_targeting_char(ch)
  active_prefix = active_prefix .. ch
  local exact = nil
  local prefix_matches = 0
  local plen = #active_prefix
  for i = 1, #scoped_candidates do
    local cand = scoped_candidates[i]
    if cand.label == active_prefix then
      exact = cand
    elseif string.sub(cand.label, 1, plen) == active_prefix then
      prefix_matches = prefix_matches + 1
    end
  end

  if exact ~= nil then
    local ok, dispatched = pcall(bitty.ui.targets.dispatch, exact.label)
    if not ok then
      close_session(extract_error_code(dispatched))
      return
    end
    if active_operator == "pick" then
      selected_target = exact
      session_mode = "action_menu"
      active_prefix = ""
      last_dispatched_command = dispatched
      repaint_overlay()
      return
    end
    local op = active_operator
    close_session(M.CODE_OK)
    execute_operator_action(op, exact, dispatched)
    return
  end

  if prefix_matches > 0 then
    repaint_overlay()
    return
  end

  close_session(M.CODE_UNKNOWN_LABEL)
end

-- ---------------------------------------------------------------------------
-- Input drain (`beacon.pump()`)
-- ---------------------------------------------------------------------------

local function extract_event_key(ev)
  if not is_indexable(ev) then
    return nil, nil
  end
  local ev_type = ev.type
  local data = is_indexable(ev.data) and ev.data or nil
  if ev_type == "key" then
    local key = (data and data.key) or ev.text or ""
    if type(key) ~= "string" then
      return nil, nil
    end
    local lower = string.lower(key)
    local ctrl = data ~= nil and data.ctrl == true
    local alt = data ~= nil and data.alt == true
    if lower == "escape" or lower == "esc" or (ctrl and lower == "c") then
      return "cancel", nil
    end
    if lower == "backspace" then
      return "backspace", nil
    end
    if not ctrl and not alt and #lower == 1 then
      local b = string.byte(lower, 1)
      if (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
        return "char", lower
      end
    end
    return "other", lower
  elseif ev_type == "text" then
    local text = (data and data.text) or ev.text or ""
    if type(text) == "string" and #text > 0 then
      return "text", string.lower(text)
    end
  end
  return nil, nil
end

function M.pump()
  if disabled then
    last_code = M.CODE_DISABLED
    return false
  end
  if session_mode == "closed" or session_handle <= 0 then
    last_code = M.CODE_NOT_OPEN
    return false
  end
  if not is_indexable(bitty.ui) or not is_indexable(bitty.ui.overlay) or type(bitty.ui.overlay.poll) ~= "function" then
    close_session("E_UI_UNAVAILABLE")
    return false
  end

  local ok, res = pcall(bitty.ui.overlay.poll, session_handle)
  if not ok then
    close_session(extract_error_code(res))
    return false
  end
  if not is_indexable(res) then
    return true
  end
  if res.closed == true then
    close_session(M.CODE_RELEASED)
    return false
  end
  local events = res.events
  if not is_indexable(events) then
    return true
  end

  for i = 1, #events do
    if session_mode == "closed" then
      break
    end
    local kind, payload = extract_event_key(events[i])
    if kind == "cancel" then
      close_session(M.CODE_CANCELLED)
      return false
    elseif kind == "backspace" then
      if session_mode == "targeting" and #active_prefix > 0 then
        active_prefix = string.sub(active_prefix, 1, #active_prefix - 1)
        repaint_overlay()
      end
    elseif kind == "char" and payload ~= nil then
      if session_mode == "action_menu" then
        handle_action_menu_key(payload)
      else
        handle_targeting_char(payload)
      end
    elseif kind == "text" and payload ~= nil then
      for c_idx = 1, #payload do
        if session_mode == "closed" then
          break
        end
        local ch = string.sub(payload, c_idx, c_idx)
        local b = string.byte(ch, 1)
        if (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
          if session_mode == "action_menu" then
            handle_action_menu_key(ch)
          else
            handle_targeting_char(ch)
          end
        else
          close_session(M.CODE_UNKNOWN_LABEL)
          break
        end
      end
    elseif kind == "other" then
      close_session(M.CODE_UNKNOWN_LABEL)
      return false
    end
  end
  return session_mode ~= "closed"
end

-- ---------------------------------------------------------------------------
-- Public lens registration helpers
-- ---------------------------------------------------------------------------

function M.register_lens(name, tier, targets)
  if disabled then
    last_code = M.CODE_DISABLED
    return false
  end
  if not is_indexable(bitty.ui) or not is_indexable(bitty.ui.targets) or type(bitty.ui.targets.register) ~= "function" then
    last_code = "E_UI_UNAVAILABLE"
    return false
  end
  local ok, res = pcall(bitty.ui.targets.register, {
    name = name,
    tier = tier,
    targets = targets,
  })
  if not ok then
    last_code = extract_error_code(res)
    return false
  end
  last_code = M.CODE_OK
  return res == true
end

function M.unregister_lens(name)
  if disabled then
    last_code = M.CODE_DISABLED
    return false
  end
  if not is_indexable(bitty.ui) or not is_indexable(bitty.ui.targets) or type(bitty.ui.targets.unregister) ~= "function" then
    last_code = "E_UI_UNAVAILABLE"
    return false
  end
  local ok, res = pcall(bitty.ui.targets.unregister, name)
  if not ok then
    last_code = extract_error_code(res)
    return false
  end
  last_code = M.CODE_OK
  return res == true
end

-- ---------------------------------------------------------------------------
-- Session entry points (`start`, `goto_workspace`, `move_panel`, `pick`, `cancel`)
-- ---------------------------------------------------------------------------

function M.start(args)
  if disabled then
    last_code = M.CODE_DISABLED
    return { ok = false, code = M.CODE_DISABLED }
  end
  if session_mode ~= "closed" then
    close_session(nil)
  end

  local req_scope = cfg_default_scope
  local req_operator = "focus"
  local custom_commands = nil
  if is_indexable(args) then
    if args.scope ~= nil then
      if not M.is_valid_scope(args.scope) then
        last_code = "E_DEF_INVALID"
        return { ok = false, code = "E_DEF_INVALID" }
      end
      req_scope = args.scope
    end
    if args.operator ~= nil then
      if not M.is_valid_operator(args.operator) then
        last_code = "E_DEF_INVALID"
        return { ok = false, code = "E_DEF_INVALID" }
      end
      req_operator = args.operator
    end
    if is_indexable(args.target_commands) then
      custom_commands = args.target_commands
    end
  end

  if not is_indexable(bitty.ui) or not is_indexable(bitty.ui.targets) or not is_indexable(bitty.ui.labels) then
    last_code = "E_UI_UNAVAILABLE"
    return { ok = false, code = "E_UI_UNAVAILABLE" }
  end

  local policy_ok, policy_err = pcall(bitty.ui.labels.set_policy, cfg_home, cfg_overflow)
  if not policy_ok then
    local code = extract_error_code(policy_err)
    last_code = code
    return { ok = false, code = code }
  end

  local ws_names = {}
  if is_indexable(bitty.workspace) and type(bitty.workspace.list) == "function" then
    local ws_ok, ws_list = pcall(bitty.workspace.list)
    if not ws_ok then
      if req_scope == "workspace" or req_operator == "move" then
        local code = extract_error_code(ws_list)
        last_code = code
        return { ok = false, code = code }
      end
    elseif is_indexable(ws_list) then
      for i = 1, #ws_list do
        local w = ws_list[i]
        if is_indexable(w) and type(w.id) == "number" and type(w.name) == "string" then
          ws_names[w.id] = w.name
        end
      end
    end
  end

  local snap_ok, rows = pcall(bitty.ui.targets.snapshot, M.MAX_SNAPSHOT_TARGETS)
  if not snap_ok then
    local code = extract_error_code(rows)
    last_code = code
    return { ok = false, code = code }
  end
  if not is_indexable(rows) or #rows == 0 then
    last_code = M.CODE_NO_TARGETS
    return { ok = false, code = M.CODE_NO_TARGETS }
  end

  local anchors = {}
  local commands = {}
  local matching_indices = {}
  for i = 1, #rows do
    local row = rows[i]
    local rx = ((i - 1) * 8) % cfg_viewport_width
    local ry = math.floor(((i - 1) * 8) / cfg_viewport_width)
    if is_indexable(row.rect) and type(row.rect[1]) == "number" and type(row.rect[2]) == "number" then
      rx = row.rect[1]
      ry = row.rect[2]
    end
    anchors[i] = { x = rx, y = ry }

    local key = tostring(row.kind) .. ":" .. tostring(row.id)
    local cmd = "bitty-terminal.beacon:start"
    if custom_commands ~= nil and type(custom_commands[key]) == "string" and custom_commands[key] ~= "" then
      cmd = custom_commands[key]
    elseif req_operator == "move" then
      cmd = "bitty-terminal.beacon:move-panel"
    elseif req_operator == "pick" then
      cmd = "bitty-terminal.beacon:pick"
    elseif req_scope == "workspace" then
      cmd = "bitty-terminal.beacon:goto-workspace"
    end
    commands[i] = cmd

    if req_scope == "all" or row.kind == req_scope then
      matching_indices[#matching_indices + 1] = i
    end
  end

  if #matching_indices == 0 then
    last_code = M.CODE_NO_TARGETS
    return { ok = false, code = M.CODE_NO_TARGETS }
  end

  local mount_ok, handle = pcall(bitty.ui.mount, "overlay", {
    kind = "Text",
    text = "Beacon loading...",
  })
  if not mount_ok or type(handle) ~= "number" or handle <= 0 then
    local code = extract_error_code(handle)
    last_code = code
    return { ok = false, code = code }
  end

  local start_ok, labels = pcall(bitty.ui.targets.session_start, handle, cfg_viewport_width, anchors, commands)
  if not start_ok or not is_indexable(labels) then
    if type(bitty.ui.unmount) == "function" then
      pcall(bitty.ui.unmount, handle)
    end
    local code = extract_error_code(labels)
    last_code = code
    return { ok = false, code = code }
  end

  local cands = {}
  for j = 1, #matching_indices do
    local idx = matching_indices[j]
    local row = rows[idx]
    local ws_id = row.workspace
    if ws_id == nil and row.kind == "workspace" then
      ws_id = row.id
    end
    cands[#cands + 1] = {
      index = idx,
      handle = row.handle,
      id = row.id,
      kind = row.kind,
      tier = row.tier,
      workspace = ws_id,
      workspace_name = ws_id ~= nil and ws_names[ws_id] or nil,
      rect = row.rect,
      generation = row.generation,
      label = labels[idx] or "",
      command = commands[idx],
    }
  end

  session_handle = handle
  session_mode = "targeting"
  active_operator = req_operator
  active_scope = req_scope
  active_prefix = ""
  scoped_candidates = cands
  selected_target = nil
  last_code = M.CODE_OK

  repaint_overlay()
  store_set_safe("beacon.last_operator", req_operator)
  store_set_safe("beacon.last_scope", req_scope)

  return {
    ok = true,
    code = M.CODE_OK,
    count = #cands,
  }
end

function M.goto_workspace()
  return M.start({ scope = "workspace", operator = "focus" })
end

function M.move_panel()
  return M.start({ scope = "workspace", operator = "move" })
end

function M.pick(args)
  local scope = cfg_default_scope
  if is_indexable(args) and args.scope ~= nil then
    scope = args.scope
  end
  return M.start({ scope = scope, operator = "pick" })
end

function M.cancel()
  if disabled then
    last_code = M.CODE_DISABLED
    return { ok = false, code = M.CODE_DISABLED }
  end
  if session_mode == "closed" then
    last_code = M.CODE_NOT_OPEN
    return { ok = false, code = M.CODE_NOT_OPEN }
  end
  close_session(M.CODE_CANCELLED)
  return { ok = true, code = M.CODE_CANCELLED }
end

-- ---------------------------------------------------------------------------
-- Scalar queries for tests and diagnostics
-- ---------------------------------------------------------------------------

function M.is_open()
  return session_mode ~= "closed"
end

function M.mode()
  return session_mode
end

function M.active_operator()
  return active_operator
end

function M.active_scope()
  return active_scope
end

function M.prefix()
  return active_prefix
end

function M.candidate_count()
  return #scoped_candidates
end

function M.visible_candidate_count()
  return #visible_candidates()
end

function M.label_for_index(idx)
  local cand = scoped_candidates[idx]
  if cand == nil then
    return nil
  end
  return cand.label
end

function M.selected_target_id()
  if selected_target == nil then
    return 0
  end
  return selected_target.id or 0
end

function M.selected_target_kind()
  if selected_target == nil then
    return ""
  end
  return selected_target.kind or ""
end

function M.last_code()
  return last_code
end

function M.last_dispatched_command()
  return last_dispatched_command
end

function M.last_focused_workspace()
  return last_focused_workspace
end

function M.last_moved_workspace()
  return last_moved_workspace
end

function M.last_closed_workspace()
  return last_closed_workspace
end

function M.next_workspace_count()
  return next_workspace_count
end

function M.overlay_handle()
  return session_handle
end

function M.configured_home_charset()
  return cfg_home
end

function M.configured_overflow_charset()
  return cfg_overflow
end

function M.configured_default_scope()
  return cfg_default_scope
end

function M.configured_viewport_width()
  return cfg_viewport_width
end

-- ---------------------------------------------------------------------------
-- Activation bootstrap
-- ---------------------------------------------------------------------------

local function read_string_setting(key, fallback)
  if not is_indexable(bitty.settings) or type(bitty.settings.get) ~= "function" then
    return fallback
  end
  local ok, val = pcall(bitty.settings.get, key)
  if ok and type(val) == "string" then
    local cleaned = trim(val)
    if cleaned ~= "" then
      return cleaned
    end
  end
  return fallback
end

local function read_int_setting(key, fallback, min_val, max_val)
  if not is_indexable(bitty.settings) or type(bitty.settings.get) ~= "function" then
    return fallback
  end
  local ok, val = pcall(bitty.settings.get, key)
  if ok and type(val) == "number" and math.floor(val) == val and val >= min_val and val <= max_val then
    return val
  end
  return fallback
end

local function check_api_version()
  if not is_indexable(bitty) then
    return false
  end
  local api_ver = bitty.api_version
  if type(api_ver) ~= "string" and type(bitty.version) == "function" then
    local ok, ver = pcall(bitty.version)
    if ok and is_indexable(ver) then
      api_ver = ver.api_version
    end
  end
  if type(api_ver) ~= "string" then
    return false
  end
  local major = string.match(api_ver, "^(%d+)%.")
  return tonumber(major) == M.REQUIRED_API_MAJOR
end

local function activate()
  _G.beacon = M
  if not check_api_version() then
    disabled = true
    last_code = M.CODE_DISABLED
    return
  end

  cfg_open_chord = read_string_setting("open_chord", M.DEFAULT_OPEN_CHORD)
  cfg_workspace_chord = read_string_setting("workspace_chord", M.DEFAULT_WORKSPACE_CHORD)
  cfg_move_chord = read_string_setting("move_chord", M.DEFAULT_MOVE_CHORD)

  local raw_scope = string.lower(read_string_setting("default_scope", M.DEFAULT_SCOPE))
  if M.is_valid_scope(raw_scope) then
    cfg_default_scope = raw_scope
  else
    cfg_default_scope = M.DEFAULT_SCOPE
  end

  local raw_home = string.lower(read_string_setting("label_home", M.DEFAULT_HOME_CHARSET))
  if M.validate_charset(raw_home) then
    cfg_home = raw_home
  else
    cfg_home = M.DEFAULT_HOME_CHARSET
  end

  local raw_overflow = string.lower(read_string_setting("label_overflow", M.DEFAULT_OVERFLOW_CHARSET))
  if M.validate_charset(raw_overflow) then
    cfg_overflow = raw_overflow
  else
    cfg_overflow = M.DEFAULT_OVERFLOW_CHARSET
  end

  cfg_viewport_width = read_int_setting("viewport_width", M.DEFAULT_VIEWPORT_WIDTH, 1, M.MAX_VIEWPORT_WIDTH)

  if is_indexable(bitty.ui) and is_indexable(bitty.ui.labels) and type(bitty.ui.labels.set_policy) == "function" then
    pcall(bitty.ui.labels.set_policy, cfg_home, cfg_overflow)
  end

  bitty.commands.register({
    id = "start",
    title = "Beacon: Start Spatial Targeting",
    run = function(args)
      return M.start(args)
    end,
  })

  bitty.commands.register({
    id = "goto-workspace",
    title = "Beacon: Go to Workspace",
    run = function()
      return M.goto_workspace()
    end,
  })

  bitty.commands.register({
    id = "move-panel",
    title = "Beacon: Move Focused Panel to Workspace",
    run = function()
      return M.move_panel()
    end,
  })

  bitty.commands.register({
    id = "pick",
    title = "Beacon: Pick Target and Action",
    run = function(args)
      return M.pick(args)
    end,
  })

  bitty.commands.register({
    id = "cancel",
    title = "Beacon: Cancel Targeting Session",
    run = function()
      return M.cancel()
    end,
  })

  if is_indexable(bitty.keymaps) and type(bitty.keymaps.suggest) == "function" then
    pcall(bitty.keymaps.suggest, {
      chord = cfg_open_chord,
      command = "bitty-terminal.beacon:start",
      context = "global",
      description = "Start Beacon spatial targeting",
    })
    pcall(bitty.keymaps.suggest, {
      chord = cfg_workspace_chord,
      command = "bitty-terminal.beacon:goto-workspace",
      context = "global",
      description = "Jump to a workspace with Beacon labels",
    })
    pcall(bitty.keymaps.suggest, {
      chord = cfg_move_chord,
      command = "bitty-terminal.beacon:move-panel",
      context = "global",
      description = "Move the focused panel to a labeled workspace",
    })
  end

  if is_indexable(bitty.events) and type(bitty.events.subscribe) == "function" then
    bitty.events.subscribe("overlay.input.available", function()
      if session_mode ~= "closed" then
        M.pump()
      end
    end)
    bitty.events.subscribe("overlay.released", function()
      if session_mode ~= "closed" then
        close_session(M.CODE_RELEASED)
      end
    end)
    bitty.events.subscribe("focus.changed", function()
      if session_mode ~= "closed" then
        M.pump()
      end
    end)
  end
end

activate()

return M
