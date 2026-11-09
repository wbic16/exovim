-- nvim.phext.search — search across scrolls.
--
-- `/`, `?`, `n`, `*` inside a scroll stay native and scroll-scoped.
-- :PhextSearch is the cross-scroll operation: it walks the effective
-- index once (search is the one legitimately linear operation, and it
-- runs on demand, not per keystroke) and fills the quickfix list. Each
-- entry carries module = coordinate and text = matching line; <CR> in
-- that quickfix buffer performs a coordinate jump + in-scroll line jump.
--
-- :PhextTitles filters scroll first-lines through vim.ui.select (the core
-- picker seam; telescope/fzf-lua override it for free).

local coord_mod = require('nvim.phext.coord')

local M = {}

local function split_lines(text)
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

--- Case prefix for a Vim pattern, honouring 'ignorecase'/'smartcase'.
local function case_prefix(pattern)
  if not vim.o.ignorecase then
    return '\\C'
  end
  if vim.o.smartcase and pattern:find('%u') then
    return '\\C'
  end
  return '\\c'
end

--- Find all matches of a Vim-regex `pattern` in the session's scrolls.
--- Returns quickfix entries plus a parallel list of target coordinates.
---@param session PhextSession
---@param pattern string
---@return table[] items, table[] targets ({ coord, lnum })
function M.collect(session, pattern)
  local phext = require('nvim.phext')
  local eff = phext._eff_index(session)
  local pat = case_prefix(pattern) .. pattern
  local items = {}
  local targets = {}
  for _, e in ipairs(eff.entries) do
    local lines = split_lines(e.text or '')
    for lnum, line in ipairs(lines) do
      if vim.fn.match(line, pat) >= 0 then
        items[#items + 1] = {
          bufnr = session.bufnr,
          lnum = lnum,
          module = coord_mod.key(e.coord),
          text = line,
        }
        targets[#targets + 1] = { coord = coord_mod.copy(e.coord), lnum = lnum }
      end
    end
  end
  return items, targets
end

--- :PhextSearch {pattern}
---@param session PhextSession
---@param pattern string
---@param goto_fn fun(coord: integer[], lnum: integer)
function M.run(session, pattern, goto_fn)
  local items, targets = M.collect(session, pattern)
  if #items == 0 then
    vim.notify(
      ('phext: no matches for %q'):format(pattern),
      vim.log.levels.WARN,
      { title = 'phext' }
    )
    return
  end
  vim.fn.setqflist({}, 'r', {
    title = 'PhextSearch: ' .. pattern,
    items = items,
  })
  vim.cmd('copen')
  -- Buffer-local <CR> in *this* quickfix buffer: the entries' bufnr is the
  -- phext buffer (whose visible scroll changes), so the default jump would
  -- land on the wrong scroll. Resolve through the stored targets instead.
  local qf_buf = vim.api.nvim_get_current_buf()
  vim.keymap.set('n', '<CR>', function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local t = targets[row]
    if t then
      vim.cmd('cclose')
      goto_fn(t.coord, t.lnum)
    end
  end, { buffer = qf_buf, silent = true, desc = 'phext search: jump to scroll' })
  vim.notify(
    ('phext: %d match%s for %q'):format(#items, #items == 1 and '' or 'es', pattern),
    vim.log.levels.INFO,
    { title = 'phext' }
  )
end

--- :PhextTitles {pattern} — pick a scroll by its first line.
---@param session PhextSession
---@param pattern string plain-text, case-insensitive filter ('' = all)
---@param goto_fn fun(coord: integer[])
function M.titles(session, pattern, goto_fn)
  local phext = require('nvim.phext')
  local eff = phext._eff_index(session)
  local needle = pattern:lower()
  local choices = {}
  local coords = {}
  for _, e in ipairs(eff.entries) do
    local title = ((e.text or ''):match('^([^\n]*)') or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if title == '' then
      title = '(no title)'
    end
    if needle == '' or title:lower():find(needle, 1, true) then
      choices[#choices + 1] = ('%s  %s'):format(coord_mod.key(e.coord), title)
      coords[#coords + 1] = e.coord
    end
  end
  if #choices == 0 then
    vim.notify('phext: no titles match', vim.log.levels.WARN, { title = 'phext' })
    return
  end
  vim.ui.select(choices, { prompt = 'PhextTitles' }, function(_, idx)
    if idx then
      goto_fn(coord_mod.copy(coords[idx]))
    end
  end)
end

return M
