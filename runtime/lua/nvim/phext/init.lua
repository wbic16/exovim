-- nvim.phext — phext scroll navigation for exovim.
--
-- Primary model: scroll-as-buffer. The .phext file on disk stays the single
-- canonical byte stream; opening it builds a sparse coordinate index once
-- (nvim.phext.index), and the user edits one scroll at a time in a normal
-- buffer whose contents contain no delimiter bytes. Navigation swaps the
-- buffer's content to the target scroll. Saving serialises (original bytes
-- + per-scroll edits); an unmodified save never touches the file.
--
-- See PHEXT.md at the repository root for the classification, coordinate
-- map, invariants, and honest limits of this implementation.

local coord_mod = require('nvim.phext.coord')
local index_mod = require('nvim.phext.index')
local navigate = require('nvim.phext.navigate')

local M = {}
M.coord = coord_mod
M.index = index_mod
M.navigate = navigate

---@class PhextSession
---@field bufnr integer
---@field path string absolute path of the .phext file
---@field bytes string bytes as loaded / last written
---@field index PhextIndex sparse index over `bytes`
---@field load_hash string sha256 of `bytes`
---@field coord integer[]|nil current coordinate
---@field dim integer active user dimension (1 = scroll .. 9 = library)
---@field edits table<string, string> coordinate key -> replacement text
---@field revision integer bumped whenever `edits` changes
---@field cursors table<string, integer[]> coordinate key -> {row, col}
---@field mark integer[]|nil the phext mark (mP / 'P)
---@field _eff PhextEffIndex|nil cached effective index (index + edits)
---@field _eff_revision integer
---@field _outline table|nil outline (table-of-contents) state
---@field _outline_cache table|nil cached outline lines/actions

---@type table<integer, PhextSession>
local sessions = {}
M._sessions = sessions

local ns = vim.api.nvim_create_namespace('nvim.phext')

-- ---------------------------------------------------------------------------
-- small helpers

local function read_bytes(path)
  local f, err = io.open(path, 'rb')
  if not f then
    return nil, err
  end
  local data = f:read('*a')
  f:close()
  return data or ''
end

local function write_bytes(path, data)
  local f, err = io.open(path, 'wb')
  if not f then
    return nil, err
  end
  f:write(data)
  f:close()
  return true
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'phext' })
end

--- Error display that never raises. (vim.notify at ERROR level echoes with
--- err=true, which throws inside autocmds and command callbacks; reserve
--- real raises for the :write refusal in M.write, where aborting is the
--- intended E813-style semantics.)
local function err_notify(msg)
  vim.api.nvim_echo({ { msg, 'ErrorMsg' } }, true, {})
end

--- Split scroll text into buffer lines. A scroll's trailing newline is
--- content: "a\n" -> { "a", "" }, "" -> { "" }, "\n" -> { "", "" }.
local function text_to_lines(text)
  local lines = {}
  local pos = 1
  while true do
    local nl = text:find('\n', pos, true)
    if not nl then
      lines[#lines + 1] = text:sub(pos)
      break
    end
    lines[#lines + 1] = text:sub(pos, nl - 1)
    pos = nl + 1
  end
  return lines
end

local function lines_to_text(lines)
  return table.concat(lines, '\n')
end

local function original_text(session, key)
  local i = session.index.by_key[key]
  if not i then
    return ''
  end
  local entry = session.index.entries[i]
  assert(entry)
  return index_mod.entry_text(session.index, entry)
end

--- The effective text of a scroll: edit if present, else the indexed text,
--- else "" for an unoccupied coordinate.
local function session_text(session, coord)
  local key = coord_mod.key(coord)
  local edited = session.edits[key]
  if edited ~= nil then
    return edited
  end
  return original_text(session, key)
end

local function is_occupied(session, coord)
  local key = coord_mod.key(coord)
  local edited = session.edits[key]
  if edited ~= nil then
    return edited ~= ''
  end
  return session.index.by_key[key] ~= nil
end

local function session_dirty(session)
  return next(session.edits) ~= nil
end
M._dirty = session_dirty

--- Effective index: the sparse index with edits applied (emptied scrolls
--- removed, inserted scrolls merged in), cached per revision. Navigation,
--- outline, search, and completion all read through this view.
---@param session PhextSession
---@return PhextEffIndex
local function eff_index(session)
  if session._eff and session._eff_revision == session.revision then
    return session._eff
  end
  local entries = {}
  local by_key = {}
  local function push(c, text)
    entries[#entries + 1] = { coord = c, text = text }
    by_key[coord_mod.key(c)] = #entries
  end
  for _, entry in ipairs(session.index.entries) do
    local key = coord_mod.key(entry.coord)
    local text = session.edits[key]
    if text == nil then
      text = index_mod.entry_text(session.index, entry)
    end
    if text ~= '' then
      push(entry.coord, text)
    end
  end
  for key, text in pairs(session.edits) do
    if text ~= '' and not session.index.by_key[key] then
      push(coord_mod.parse(key), text)
    end
  end
  table.sort(entries, function(a, b)
    return coord_mod.compare(a.coord, b.coord) < 0
  end)
  -- rebuild by_key after sorting
  by_key = {}
  for i, e in ipairs(entries) do
    by_key[coord_mod.key(e.coord)] = i
  end
  local eff = { entries = entries, by_key = by_key }
  session._eff = eff
  session._eff_revision = session.revision
  return eff
end
M._eff_index = eff_index

--- Fold the current buffer content (and cursor) back into the session.
--- Only the current scroll can change; edits are stored per coordinate and
--- the revision bumps only when the stored text actually changes.
---@param session PhextSession
local function capture_current(session)
  if not session.coord then
    return
  end
  local key = coord_mod.key(session.coord)
  local win = vim.fn.bufwinid(session.bufnr)
  if win ~= -1 then
    session.cursors[key] = vim.api.nvim_win_get_cursor(win)
  end
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  local text = lines_to_text(lines)
  local orig = original_text(session, key)
  if text == orig then
    if session.edits[key] ~= nil then
      session.edits[key] = nil
      session.revision = session.revision + 1
    end
  elseif session.edits[key] ~= text then
    session.edits[key] = text
    session.revision = session.revision + 1
  end
end
M._capture = capture_current

--- Show `coord`'s scroll in the session buffer.
---@param session PhextSession
---@param coord integer[]
---@param opts table|nil { jump: boolean, line: integer|nil }
local function display(session, coord, opts)
  opts = opts or {}
  local buf = session.bufnr
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.api.nvim_set_current_win(win)
  if opts.jump then
    vim.cmd("normal! m'")
  end
  local text = session_text(session, coord)
  local saved_ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text_to_lines(text))
  vim.bo[buf].undolevels = saved_ul
  session.coord = coord_mod.copy(coord)
  vim.bo[buf].modified = session_dirty(session)
  pcall(
    vim.api.nvim_buf_set_name,
    buf,
    ('phext://%s@%s'):format(session.path, coord_mod.key(coord))
  )
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if not is_occupied(session, coord) then
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
      virt_text = { { '(empty scroll — type and :write to create it)', 'Comment' } },
      virt_text_pos = 'eol',
    })
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local cursor = opts.line and { opts.line, 0 } or session.cursors[coord_mod.key(coord)] or { 1, 0 }
  cursor[1] = math.max(1, math.min(cursor[1], line_count))
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

--- Go to a coordinate (captures the current scroll first, pushes the
--- jumplist). `line` optionally positions the cursor inside the scroll.
---@param session PhextSession
---@param coord integer[]
---@param line integer|nil
function M.goto_coord(session, coord, line)
  capture_current(session)
  display(session, coord, { jump = true, line = line })
end

-- ---------------------------------------------------------------------------
-- session lifecycle

local function setup_mappings(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set('n', lhs, fn, { buffer = buf, silent = true, desc = desc })
  end
  local function sess()
    return sessions[buf]
  end
  map('gP', function()
    local s = sess()
    if s then
      M.prompt_goto(s)
    end
  end, 'phext: goto coordinate (prompt)')
  for d = 1, 9 do
    map('g' .. d, function()
      local s = sess()
      if s then
        s.dim = d
        notify(('phext: active dimension %d (%s)'):format(d, coord_mod.DIM_NAMES[d]))
      end
    end, 'phext: set active dimension')
  end
  map('g]', function()
    local s = sess()
    if s then
      M.goto_coord(s, coord_mod.step(s.coord, s.dim, vim.v.count1))
    end
  end, 'phext: step active dimension forward')
  map('g[', function()
    local s = sess()
    if s then
      M.goto_coord(s, coord_mod.step(s.coord, s.dim, -vim.v.count1))
    end
  end, 'phext: step active dimension backward')
  if not vim.g.phext_no_section_motions then
    map(']]', function()
      local s = sess()
      if s then
        M.cmd_next({ count = vim.v.count1 })
      end
    end, 'phext: next populated scroll')
    map('[[', function()
      local s = sess()
      if s then
        M.cmd_prev({ count = vim.v.count1 })
      end
    end, 'phext: previous populated scroll')
  end
  map(']P', function()
    local s = sess()
    if s then
      M.step_populated(s, 1)
    end
  end, 'phext: next populated scroll in active dimension')
  map('[P', function()
    local s = sess()
    if s then
      M.step_populated(s, -1)
    end
  end, 'phext: previous populated scroll in active dimension')
  map('mP', function()
    local s = sess()
    if s then
      capture_current(s)
      s.mark = coord_mod.copy(s.coord)
      notify('phext: mark set at ' .. coord_mod.key(s.coord))
    end
  end, 'phext: set phext mark')
  map("'P", function()
    local s = sess()
    if s and s.mark then
      M.goto_coord(s, s.mark)
    elseif s then
      notify('phext: no mark set (mP)', vim.log.levels.WARN)
    end
  end, 'phext: go to phext mark')
end

---@param buf integer
---@param path string
---@param bytes string
local function new_session(buf, path, bytes)
  ---@type PhextSession
  local session = {
    bufnr = buf,
    path = path,
    bytes = bytes,
    index = index_mod.build(bytes),
    load_hash = vim.fn.sha256(bytes),
    coord = nil,
    dim = 1,
    edits = {},
    revision = 0,
    cursors = {},
    mark = nil,
    _eff = nil,
    _eff_revision = -1,
    _outline = nil,
    _outline_cache = nil,
  }
  sessions[buf] = session
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].fileencoding = 'utf-8'
  vim.bo[buf].filetype = 'phext'
  setup_mappings(buf)
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
    buffer = buf,
    callback = function()
      sessions[buf] = nil
    end,
  })
  display(session, coord_mod.default(), { jump = false })
  vim.bo[buf].modified = false
  return session
end

--- BufReadCmd handler: load a .phext file as a scroll session.
---@param ev table autocmd event
function M.read(ev)
  local path = vim.fn.fnamemodify(ev.file, ':p')
  local bytes, err = read_bytes(path)
  if bytes == nil then
    err_notify(('phext: cannot read %s: %s'):format(path, err))
    return
  end
  new_session(ev.buf, path, bytes)
end

--- BufNewFile handler: a fresh, empty phext session.
---@param ev table autocmd event
function M.new_file(ev)
  local path = vim.fn.fnamemodify(ev.file, ':p')
  new_session(ev.buf, path, '')
end

--- BufWriteCmd handler (:write). No-op when nothing changed; refuses when
--- the file changed on disk since load (the index would otherwise
--- silently resurrect stale spans).
---@param buf integer
---@return boolean handled
function M.write(buf)
  local session = sessions[buf]
  if not session then
    return false
  end
  capture_current(session)
  local on_disk = read_bytes(session.path)
  if on_disk ~= nil and vim.fn.sha256(on_disk) ~= session.load_hash then
    vim.bo[buf].modified = true
    -- Deliberate raise: a BufWriteCmd error aborts the write, which is
    -- exactly the E813-style refusal the design specifies.
    error('phext: file changed on disk since load; refusing to overwrite (E813-style)', 0)
  end
  if not session_dirty(session) then
    vim.bo[buf].modified = false
    notify('phext: no changes; file untouched')
    return true
  end
  local out = index_mod.serialize(session.index, session.edits)
  local ok, werr = write_bytes(session.path, out)
  if not ok then
    error(('phext: write failed: %s'):format(werr), 0)
  end
  local current = session.coord and coord_mod.copy(session.coord) or coord_mod.default()
  session.bytes = out
  session.index = index_mod.build(out)
  session.edits = {}
  session.revision = session.revision + 1
  session.load_hash = vim.fn.sha256(out)
  display(session, current, { jump = false })
  vim.bo[buf].modified = false
  notify(('phext: wrote %d scrolls (%d bytes)'):format(#session.index.entries, #out))
  return true
end

-- ---------------------------------------------------------------------------
-- public API for user statuslines / other plugins

---@return PhextSession|nil
local function current_session()
  local buf = vim.api.nvim_get_current_buf()
  local s = sessions[buf]
  if not s then
    -- the current buffer may be the outline/quickfix of a phext session;
    -- commands there are expected to target their owning session instead.
    return nil
  end
  return s
end
M._current_session = current_session

--- The current coordinate as a 9-component array, or nil outside phext.
---@return integer[]|nil
function M.coordinate()
  local s = current_session()
  if not s or not s.coord then
    return nil
  end
  return coord_mod.copy(s.coord)
end

--- Statusline segment: "33.5.9/7.5.9/5.5.8 · scroll 8 of 7,281 · dim: Book [+]".
--- Pure function of cached session state (effective index is revision-cached).
---@return string
function M.status()
  local s = current_session()
  if not s or not s.coord then
    return ''
  end
  capture_current(s)
  local eff = eff_index(s)
  local key = coord_mod.key(s.coord)
  local rank = eff.by_key[key]
  local where = rank and ('scroll %d of %d'):format(rank, #eff.entries)
    or ('empty · %d scrolls'):format(#eff.entries)
  return ('%s · %s · dim: %s%s'):format(
    key,
    where,
    coord_mod.DIM_NAMES[s.dim],
    session_dirty(s) and ' [+]' or ''
  )
end

-- ---------------------------------------------------------------------------
-- commands (registered by runtime/plugin/phext.lua)

local function need_session()
  local s = current_session()
  if not s then
    notify('phext: not a phext buffer', vim.log.levels.WARN)
  end
  return s
end

--- Completion for :PhextGoto: occupied coordinates only, by prefix.
---@param lead string
---@return string[]
function M.complete_goto(lead)
  local s = current_session()
  if not s then
    return {}
  end
  local eff = eff_index(s)
  local out = {}
  for _, e in ipairs(eff.entries) do
    local key = coord_mod.key(e.coord)
    if lead == '' or key:sub(1, #lead) == lead then
      out[#out + 1] = key
    end
  end
  return out
end

--- Global hook used by input() completion (v:lua cannot reach locals).
---@param lead string
---@return string[]
_G.PhextGotoComplete = function(lead)
  return M.complete_goto(lead)
end

---@param session PhextSession
function M.prompt_goto(session)
  local input = vim.fn.input(
    'PhextGoto: ',
    session.coord and coord_mod.key(session.coord) or '',
    'customlist,v:lua.PhextGotoComplete'
  )
  if input and input ~= '' then
    M.cmd_goto({ args = input })
  end
end

---@param opts table command opts ({ args, count, ... })
function M.cmd_goto(opts)
  local s = need_session()
  if not s then
    return
  end
  local arg = vim.trim(opts.args or '')
  if arg == '' then
    M.prompt_goto(s)
    return
  end
  capture_current(s)
  local coord, err = coord_mod.parse(arg, s.coord)
  if not coord then
    err_notify('phext: ' .. err)
    return
  end
  display(s, coord, { jump = true })
end

function M.cmd_coord()
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  local coord = s.coord or coord_mod.default()
  local eff = eff_index(s)
  local info = navigate.describe(eff, coord)
  local lines = {
    ('coordinate: %s'):format(coord_mod.key(coord)),
    ('active dimension: %d (%s)'):format(s.dim, coord_mod.DIM_NAMES[s.dim]),
    info.occupied and ('occupied: yes — scroll %d of %d'):format(info.rank, info.total)
      or ('occupied: no — %d scrolls in file'):format(info.total),
    'prev populated: ' .. (info.prev and coord_mod.key(info.prev) or '(none)'),
    'next populated: ' .. (info.next and coord_mod.key(info.next) or '(none)'),
    'file: ' .. s.path,
  }
  vim.api.nvim_echo({ { table.concat(lines, '\n'), '' } }, true, {})
end

---@param opts table
function M.cmd_dim(opts)
  local s = need_session()
  if not s then
    return
  end
  local arg = vim.trim(opts.args or '')
  if arg == '' then
    notify(('phext: active dimension %d (%s)'):format(s.dim, coord_mod.DIM_NAMES[s.dim]))
    return
  end
  local dim = coord_mod.dim_number(arg)
  if not dim then
    err_notify(('phext: invalid dimension %q (1-9 or scroll..library)'):format(arg))
    return
  end
  s.dim = dim
  notify(('phext: active dimension %d (%s)'):format(dim, coord_mod.DIM_NAMES[dim] or ''))
end

---@param opts table :PhextStep {dim} [+n|-n] — dim optional when the first
--- token is a signed count; delta defaults to +1.
function M.cmd_step(opts)
  local s = need_session()
  if not s then
    return
  end
  local dim = s.dim
  local delta = 1
  local arg = vim.trim(opts.args or '')
  if arg ~= '' then
    for tok in arg:gmatch('%S+') do
      local signed = tok:match('^([+-]%d+)$')
      if signed then
        delta = tonumber(signed) or delta
      else
        local d = coord_mod.dim_number(tok)
        if not d then
          err_notify(('phext: invalid step argument %q'):format(tok))
          return
        end
        dim = d
      end
    end
  end
  M.goto_coord(s, coord_mod.step(s.coord or coord_mod.default(), dim, delta))
end

---@param opts table
function M.cmd_next(opts)
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  local target =
    navigate.next_populated(eff_index(s), s.coord or coord_mod.default(), opts.count or 1)
  if target then
    display(s, target, { jump = true })
  else
    notify('phext: no next populated scroll', vim.log.levels.WARN)
  end
end

---@param opts table
function M.cmd_prev(opts)
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  local target =
    navigate.prev_populated(eff_index(s), s.coord or coord_mod.default(), opts.count or 1)
  if target then
    display(s, target, { jump = true })
  else
    notify('phext: no previous populated scroll', vim.log.levels.WARN)
  end
end

--- ]P / [P backend: populated motion within the active dimension.
---@param session PhextSession
---@param dir integer 1 or -1
function M.step_populated(session, dir)
  capture_current(session)
  local eff = eff_index(session)
  local target
  local coord = session.coord or coord_mod.default()
  if dir > 0 then
    target = navigate.next_in_dim(eff, coord, session.dim, vim.v.count1)
  else
    target = navigate.prev_in_dim(eff, coord, session.dim, vim.v.count1)
  end
  if target then
    display(session, target, { jump = true })
  else
    notify('phext: no populated scroll in this dimension', vim.log.levels.WARN)
  end
end

---@param opts table :PhextNew {coord} — goto intending creation.
function M.cmd_new(opts)
  local s = need_session()
  if not s then
    return
  end
  local arg = vim.trim(opts.args or '')
  if arg == '' then
    err_notify('phext: :PhextNew requires a coordinate')
    return
  end
  capture_current(s)
  local coord, err = coord_mod.parse(arg, s.coord)
  if not coord then
    err_notify('phext: ' .. err)
    return
  end
  display(s, coord, { jump = true })
  if not is_occupied(s, coord) then
    notify('phext: new scroll — type, then :write to create it')
  end
end

function M.cmd_delete()
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  local coord = s.coord or coord_mod.default()
  local key = coord_mod.key(coord)
  if s.index.by_key[key] then
    if s.edits[key] ~= '' then
      s.edits[key] = ''
      s.revision = s.revision + 1
    end
  else
    if s.edits[key] ~= nil then
      s.edits[key] = nil
      s.revision = s.revision + 1
    end
  end
  display(s, coord, { jump = false })
  vim.bo[s.bufnr].modified = session_dirty(s)
  notify('phext: scroll emptied — it is deleted on :write')
end

function M.cmd_marks()
  local s = need_session()
  if not s then
    return
  end
  local lines = {}
  lines[#lines + 1] = 'phext mark (mP): ' .. (s.mark and coord_mod.key(s.mark) or '(not set)')
  local marks = vim.fn.getmarklist(s.bufnr)
  if #marks > 0 then
    lines[#lines + 1] = 'buffer marks:'
    for _, m in ipairs(marks) do
      lines[#lines + 1] = ('  %s  line %d'):format(m.mark, m.pos[2])
    end
  end
  local globals = vim.fn.getmarklist()
  local any = false
  for _, m in ipairs(globals) do
    if m.file == s.path then
      if not any then
        lines[#lines + 1] = 'global marks into this file:'
        any = true
      end
      lines[#lines + 1] = ('  %s  line %d'):format(m.mark, m.pos[2])
    end
  end
  vim.api.nvim_echo({ { table.concat(lines, '\n'), '' } }, true, {})
end

---@param opts table
function M.cmd_toc(opts)
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  require('nvim.phext.outline').open(s, vim.trim(opts.args or ''), function(coord)
    M.goto_coord(s, coord)
  end)
end

---@param opts table
function M.cmd_search(opts)
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  local pattern = opts.args or ''
  if pattern == '' then
    err_notify('phext: :PhextSearch requires a pattern')
    return
  end
  require('nvim.phext.search').run(s, pattern, function(coord, line)
    M.goto_coord(s, coord, line)
  end)
end

---@param opts table
function M.cmd_titles(opts)
  local s = need_session()
  if not s then
    return
  end
  capture_current(s)
  require('nvim.phext.search').titles(s, vim.trim(opts.args or ''), function(coord)
    M.goto_coord(s, coord)
  end)
end

return M
