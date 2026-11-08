-- nvim.phext.navigate — navigation decisions over a phext session.
--
-- Pure logic, no vim API: every function takes the sparse index plus the
-- current coordinate and returns a target coordinate (or nil). The session
-- layer in nvim.phext applies the result to a buffer. Two kinds of motion,
-- never conflated (design §6):
--
--   * arithmetic motion steps a dimension and may land on empty space
--     (that is how scrolls are created);
--   * populated motion jumps between occupied scrolls only, via binary
--     search over the ordered occupied list (that is how phexts are read).

local coord_mod = require('nvim.phext.coord')
local index_mod = require('nvim.phext.index')

local M = {}

--- Step the active dimension (or `dim`) of `coord` by `delta`.
---@param coord integer[]
---@param dim integer user dimension 1..9
---@param delta integer
---@return integer[]
function M.step(coord, dim, delta)
  return coord_mod.step(coord, dim, delta)
end

--- The coordinate `count` occupied scrolls after `coord`, or nil.
---@param idx PhextIndex
---@param coord integer[]
---@param count integer >= 1
---@return integer[]|nil
function M.next_populated(idx, coord, count)
  count = count or 1
  local i = index_mod.next_populated(idx, coord)
  local seen = 1
  while i and seen < count do
    i = index_mod.next_populated(idx, idx.entries[i].coord)
    seen = seen + 1
  end
  if not i then
    return nil
  end
  return coord_mod.copy(idx.entries[i].coord)
end

--- The coordinate `count` occupied scrolls before `coord`, or nil.
---@param idx PhextIndex
---@param coord integer[]
---@param count integer >= 1
---@return integer[]|nil
function M.prev_populated(idx, coord, count)
  count = count or 1
  local i = index_mod.prev_populated(idx, coord)
  local seen = 1
  while i and seen < count do
    i = index_mod.prev_populated(idx, idx.entries[i].coord)
    seen = seen + 1
  end
  if not i then
    return nil
  end
  return coord_mod.copy(idx.entries[i].coord)
end

--- Next occupied scroll reached by stepping dimension `dim`, skipping
--- empty coordinates. Or nil.
---@param idx PhextIndex
---@param coord integer[]
---@param dim integer user dimension 1..9
---@param count integer >= 1
---@return integer[]|nil
function M.next_in_dim(idx, coord, dim, count)
  count = count or 1
  local cur = coord
  for _ = 1, count do
    local i = index_mod.next_in_dim(idx, cur, dim)
    if not i then
      return nil
    end
    cur = idx.entries[i].coord
  end
  return coord_mod.copy(cur)
end

--- Previous occupied scroll reached by stepping dimension `dim` back,
--- skipping empty coordinates. Or nil.
---@param idx PhextIndex
---@param coord integer[]
---@param dim integer user dimension 1..9
---@param count integer >= 1
---@return integer[]|nil
function M.prev_in_dim(idx, coord, dim, count)
  count = count or 1
  local cur = coord
  for _ = 1, count do
    local i = index_mod.prev_in_dim(idx, cur, dim)
    if not i then
      return nil
    end
    cur = idx.entries[i].coord
  end
  return coord_mod.copy(cur)
end

--- 1-based rank of `coord` among occupied scrolls, or nil when unoccupied.
---@param idx PhextIndex
---@param coord integer[]
---@return integer|nil
function M.rank(idx, coord)
  return index_mod.find(idx, coord)
end

--- Neighbourhood description for :PhextCoord / the statusline.
---@param idx PhextIndex
---@param coord integer[]
---@return table { occupied: boolean, rank: integer|nil, total: integer,
---                 prev: integer[]|nil, next: integer[]|nil }
function M.describe(idx, coord)
  local rank = index_mod.find(idx, coord)
  local ni = index_mod.next_populated(idx, coord)
  local pi = index_mod.prev_populated(idx, coord)
  return {
    occupied = rank ~= nil,
    rank = rank,
    total = #idx.entries,
    prev = pi and coord_mod.copy(idx.entries[pi].coord) or nil,
    next = ni and coord_mod.copy(idx.entries[ni].coord) or nil,
  }
end

return M
