-- nvim.phext.outline — the table-of-contents buffer for a phext session.
--
-- The whole-phext view is a separate, read-only buffer kind: one zoom arm
-- at a time (never a fully expanded 9-level tree), populated nodes only,
-- built from the sparse index and cached per (revision, arm, scope):
--
--   outer:  groups by library.shelf.series        (positions 1..3)
--   middle: groups by collection.volume.book       (positions 4..6),
--           scoped to the current outer arm
--   inner:  individual scrolls, scoped to the current outer+middle arms
--
-- <CR> on an outer/middle group descends into the next arm scoped to that
-- group; <CR> on an inner leaf jumps to the scroll. `>` / `+` zoom in,
-- `<` / `-` zoom out, `q` closes.

local coord_mod = require('nvim.phext.coord')

local M = {}

local ARMS = { 'outer', 'middle', 'inner' }

--- Arm -> first array position of its three dimensions.
local ARM_POS = { outer = 1, middle = 4, inner = 7 }

local function arm_of(name)
  for _, a in ipairs(ARMS) do
    if a == name then
      return a
    end
  end
  return nil
end

local function next_arm(arm)
  if arm == 'outer' then
    return 'middle'
  end
  if arm == 'middle' then
    return 'inner'
  end
  return nil
end

local function prev_arm(arm)
  if arm == 'middle' then
    return 'outer'
  end
  if arm == 'inner' then
    return 'middle'
  end
  return nil
end

--- Does `coord` fall inside the scope set by `scope_coord` for `arm`?
--- Outer is unscoped; middle shares positions 1..3; inner shares 1..6.
local function in_scope(coord, scope_coord, arm)
  local upto = ARM_POS[arm] - 1
  for p = 1, upto do
    if coord[p] ~= scope_coord[p] then
      return false
    end
  end
  return true
end

local function arm_string(coord, arm)
  local p = ARM_POS[arm] or 1
  return ('%d.%d.%d'):format(coord[p], coord[p + 1], coord[p + 2])
end

local function first_line(text)
  local line = text:match('^([^\n]*)') or ''
  line = line:gsub('^%s+', ''):gsub('%s+$', '')
  if #line > 60 then
    line = line:sub(1, 57) .. '...'
  end
  return line
end

--- Build outline lines + per-line actions for (arm, scope) from the
--- effective entries. Pure function of the entry list.
---@param entries PhextIndexEntry[] effective entries ({ coord, text }), sorted
---@param arm string
---@param scope_coord integer[]
---@return string[] lines, table[] actions (parallel to lines)
function M.build(entries, arm, scope_coord)
  local lines = {}
  local actions = {}
  local function emit(text, action)
    lines[#lines + 1] = text
    actions[#actions + 1] = action
  end
  if arm == 'inner' then
    for _, e in ipairs(entries) do
      if in_scope(e.coord, scope_coord, 'inner') then
        local title = first_line(e.text)
        emit(
          ('%s  %s'):format(coord_mod.key(e.coord), title ~= '' and title or '(no title)'),
          { kind = 'jump', coord = coord_mod.copy(e.coord) }
        )
      end
    end
  else
    local p = ARM_POS[arm] or 1
    local groups = {}
    local order = {}
    for _, e in ipairs(entries) do
      if in_scope(e.coord, scope_coord, arm) then
        local gk = ('%d.%d.%d'):format(e.coord[p] or 0, e.coord[p + 1] or 0, e.coord[p + 2] or 0)
        local g = groups[gk]
        if not g then
          g = { count = 0, first = e, coord = e.coord }
          groups[gk] = g
          order[#order + 1] = gk
        end
        g.count = g.count + 1
      end
    end
    for _, gk in ipairs(order) do
      local g = groups[gk]
      if not g then
        error('phext outline: group vanished')
      end
      local title = first_line(g.first.text or '')
      emit(
        ('%s · %d scroll%s · %s'):format(
          arm_string(g.coord, arm),
          g.count,
          g.count == 1 and '' or 's',
          title ~= '' and title or '(no title)'
        ),
        { kind = 'descend', coord = coord_mod.copy(g.coord) }
      )
    end
  end
  if #lines == 0 then
    emit('(no populated scrolls in this scope)', { kind = 'none' })
  end
  return lines, actions
end

--- Open (or refresh) the outline for `session` at `arm_name` ('' keeps the
--- current arm or defaults: the arm just above the current coordinate's
--- finest populated level — v1 default is "inner" when re-opening an
--- existing outline, else "outer"... simpler: default "outer").
--- `goto_fn(coord)` performs the jump into the phext buffer.
---@param session PhextSession
---@param arm_name string '', 'outer', 'middle' or 'inner'
---@param goto_fn fun(coord: integer[])
function M.open(session, arm_name, goto_fn)
  local phext = require('nvim.phext')
  local eff = phext._eff_index(session)
  local state = session._outline
  if not state then
    state = {
      arm = 'outer',
      scope = coord_mod.copy(session.coord or coord_mod.default()),
      bufnr = nil,
    }
    session._outline = state
  end
  local arm = arm_of(arm_name)
  if arm then
    state.arm = arm
    state.scope = coord_mod.copy(session.coord or coord_mod.default())
  end

  local cache_key = ('%d|%s|%s'):format(session.revision, state.arm, coord_mod.key(state.scope))
  local lines, actions
  if session._outline_cache and session._outline_cache.key == cache_key then
    lines = session._outline_cache.lines
    actions = session._outline_cache.actions
  else
    lines, actions = M.build(eff.entries, state.arm, state.scope)
    session._outline_cache = { key = cache_key, lines = lines, actions = actions }
  end

  local buf = state.bufnr
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    state.bufnr = buf
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'phexttoc'
    vim.bo[buf].modifiable = false
    vim.keymap.set('n', '<CR>', function()
      M.activate(session, goto_fn)
    end, { buffer = buf, silent = true, desc = 'phext toc: open' })
    vim.keymap.set('n', 'q', function()
      local w = vim.fn.bufwinid(buf)
      if w ~= -1 then
        vim.api.nvim_win_close(w, true)
      end
    end, { buffer = buf, silent = true, desc = 'phext toc: close' })
    for _, lhs in ipairs({ '>', '+' }) do
      vim.keymap.set('n', lhs, function()
        M.activate(session, goto_fn)
      end, { buffer = buf, silent = true, desc = 'phext toc: zoom in' })
    end
    for _, lhs in ipairs({ '<', '-' }) do
      vim.keymap.set('n', lhs, function()
        local pa = prev_arm(state.arm)
        if pa then
          state.arm = pa
          M.open(session, '', goto_fn)
        end
      end, { buffer = buf, silent = true, desc = 'phext toc: zoom out' })
    end
  end

  local header = ('phext outline — %s arm · scope %s · %d scrolls  (<CR> open · >/< zoom · q close)'):format(
    state.arm,
    coord_mod.key(state.scope),
    #eff.entries
  )
  vim.bo[buf].modifiable = true
  local body = { header, '' }
  for _, l in ipairs(lines) do
    body[#body + 1] = '  ' .. l
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.bo[buf].modifiable = false
  state.actions = actions
  state.header_lines = 2

  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd('vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_config(win, { width = math.max(40, math.floor(vim.o.columns * 0.4)) })
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.wo[win].foldmethod = 'indent'
  pcall(vim.api.nvim_win_set_cursor, win, { state.header_lines + 1, 0 })
end

--- <CR> handler: descend or jump depending on the line's action.
---@param session PhextSession
---@param goto_fn fun(coord: integer[])
function M.activate(session, goto_fn)
  local state = session._outline
  if not state then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local idx = row - (state.header_lines or 0)
  local action = state.actions and state.actions[idx]
  if not action or action.kind == 'none' then
    return
  end
  if action.kind == 'descend' then
    local na = next_arm(state.arm)
    if na then
      state.arm = na
      state.scope = coord_mod.copy(action.coord)
      M.open(session, '', goto_fn)
    end
  elseif action.kind == 'jump' then
    local toc_win = vim.api.nvim_get_current_win()
    goto_fn(action.coord)
    -- keep the outline open beside the scroll; return focus is with the
    -- scroll buffer (goto already focused it).
    if vim.api.nvim_win_is_valid(toc_win) and vim.api.nvim_get_current_win() == toc_win then
      -- goto did not move focus (should not happen); nothing to do.
    end
  end
end

return M
