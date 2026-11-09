-- nvim.phext.index — sparse coordinate index over a phext byte stream.
--
-- A faithful Lua port of the single-pass delimiter walk in
-- ~/workspace/phext/parse_phext.py (which agrees byte-for-byte with the
-- libphext-rs delimiter walk in phext.rs): scan the bytes once; each
-- delimiter byte closes the current scroll's span and advances the
-- coordinate (increment that dimension, reset all lower dimensions to 1).
--
-- "Occupied" = a coordinate whose span contains at least one byte.
-- Zero-length spans (consecutive delimiters) are address space, not
-- scrolls, and are not indexed. Consequence: emptying a scroll and saving
-- deletes that scroll.
--
-- All lookups are O(1) (hash by coordinate key) or O(log k) (binary search
-- over the ordered occupied list). Nothing here scans the slot space.

local coord_mod = require('nvim.phext.coord')

local M = {}

---@class PhextIndexEntry
---@field coord integer[] coordinate array (see nvim.phext.coord)
---@field s integer byte offset of the first text byte (1-based)
---@field e integer byte offset one past the last text byte
---@field text string? entry text (effective-index entries only)

---@class PhextIndex
---@field bytes string original byte stream
---@field entries PhextIndexEntry[] occupied scrolls in document order
---@field by_key table<string, integer> coordinate key -> entry index

---@class PhextEffIndex : PhextIndex
---@field bytes string? unused for effective indexes (entries carry `text`)
---@field entries PhextIndexEntry[] effective entries (entries carry `text`)
---@field by_key table<string, integer> coordinate key -> entry index

--- Build the sparse index with one pass over `bytes`. O(#bytes).
---@param bytes string
---@return PhextIndex
function M.build(bytes)
  local idx = { bytes = bytes, entries = {}, by_key = {} }
  local coord = coord_mod.default()
  local start = 1
  local n = #bytes
  for i = 1, n do
    local pos = coord_mod.BYTE_TO_POS[bytes:byte(i)]
    if pos then
      if i > start then
        local entry = { coord = coord_mod.copy(coord), s = start, e = i }
        idx.entries[#idx.entries + 1] = entry
        idx.by_key[coord_mod.key(coord)] = #idx.entries
      end
      coord_mod.apply_break(coord, pos)
      start = i + 1
    end
  end
  if n >= start then
    local entry = { coord = coord_mod.copy(coord), s = start, e = n + 1 }
    idx.entries[#idx.entries + 1] = entry
    idx.by_key[coord_mod.key(coord)] = #idx.entries
  end
  return idx
end

--- The text of an index entry, sliced from the original bytes.
---@param idx PhextIndex
---@param entry PhextIndexEntry
---@return string
function M.entry_text(idx, entry)
  return idx.bytes:sub(entry.s, entry.e - 1)
end

--- Entry index for a coordinate, or nil when the coordinate is not occupied.
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@return integer|nil
function M.find(idx, coord)
  return idx.by_key[coord_mod.key(coord)]
end

--- First entry index whose coordinate is >= `coord` (lower bound).
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@return integer index in 1..#entries+1
function M.lower_bound(idx, coord)
  local lo, hi = 1, #idx.entries + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local mid_entry = idx.entries[mid]
    assert(mid_entry)
    if coord_mod.compare(mid_entry.coord, coord) < 0 then
      lo = mid + 1
    else
      hi = mid
    end
  end
  return lo
end

--- Entry index of the next occupied scroll after `coord`, or nil.
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@return integer|nil
function M.next_populated(idx, coord)
  local i = M.lower_bound(idx, coord)
  local bound_entry = idx.entries[i]
  if i <= #idx.entries and bound_entry and coord_mod.eq(bound_entry.coord, coord) then
    i = i + 1
  end
  if i <= #idx.entries then
    return i
  end
  return nil
end

--- Entry index of the previous occupied scroll before `coord`, or nil.
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@return integer|nil
function M.prev_populated(idx, coord)
  local i = M.lower_bound(idx, coord) - 1
  if i >= 1 then
    return i
  end
  return nil
end

--- Next occupied scroll found by stepping user dimension `dim` from `coord`:
--- the first occupied scroll with the same prefix above that dimension and a
--- greater component in it. Binary search, never a step loop. Or nil.
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@param dim integer user dimension 1..9
---@return integer|nil entry index
function M.next_in_dim(idx, coord, dim)
  local pos = 10 - dim
  local target = coord_mod.copy(coord)
  target[pos] = (target[pos] or 0) + 1
  for i = pos + 1, 9 do
    target[i] = 1
  end
  local i = M.lower_bound(idx, target)
  if i > #idx.entries then
    return nil
  end
  local entry = idx.entries[i]
  assert(entry)
  for p = 1, pos - 1 do
    if entry.coord[p] ~= coord[p] then
      return nil
    end
  end
  return i
end

--- Previous occupied scroll when stepping user dimension `dim` back from
--- `coord`: the last occupied scroll with the same prefix above that
--- dimension and a smaller component in it. Or nil.
---@param idx PhextIndex|PhextEffIndex
---@param coord integer[]
---@param dim integer user dimension 1..9
---@return integer|nil entry index
function M.prev_in_dim(idx, coord, dim)
  local pos = 10 - dim
  if coord[pos] <= 1 then
    return nil
  end
  local target = coord_mod.copy(coord)
  for i = pos + 1, 9 do
    target[i] = 1
  end
  local i = M.lower_bound(idx, target) - 1
  if i < 1 then
    return nil
  end
  local entry = idx.entries[i]
  assert(entry)
  for p = 1, pos - 1 do
    if entry.coord[p] ~= coord[p] then
      return nil
    end
  end
  return i
end

--- Canonical break run that walks coordinate `from` forward to `to`
--- (requires `to` >= `from` in document order): for each dimension from
--- highest to lowest, emit that dimension's break until reached. This is
--- the libphext implode/insert fixup behaviour: advancing a dimension by k
--- emits the same bytes as k single breaks, because the first break resets
--- the lower dimensions.
---@param from integer[]
---@param to integer[]
---@return string
local function gap_breaks(from, to)
  local cur = coord_mod.copy(from)
  local out = {}
  for pos = 1, 9 do
    while (cur[pos] or 0) < (to[pos] or 0) do
      out[#out + 1] = string.char(coord_mod.BREAK_BYTE[pos] or 0)
      coord_mod.apply_break(cur, pos)
    end
  end
  return table.concat(out)
end
M.gap_breaks = gap_breaks

--- Serialise the document: original bytes plus an edits map.
--- `edits` maps coordinate key -> replacement text. A key whose text is ""
--- removes the scroll; a key not present in the index inserts a scroll.
---
--- The splice strategy preserves the original gap bytes verbatim wherever
--- the neighbouring scrolls are untouched, so an edit's byte-level effect
--- is confined to the edited span (the mutation-control invariant). Only
--- around inserted/edited/deleted scrolls are canonical gap breaks
--- computed. An empty edits map returns the original bytes unchanged.
---@param idx PhextIndex
---@param edits table<string, string>
---@return string
function M.serialize(idx, edits)
  if not edits or not next(edits) then
    return idx.bytes
  end
  -- Build the final occupied list.
  local final = {}
  local in_index = {}
  for i, entry in ipairs(idx.entries) do
    local key = coord_mod.key(entry.coord)
    in_index[key] = true
    local text = edits[key]
    if text == nil then
      final[#final + 1] = { coord = entry.coord, text = M.entry_text(idx, entry), orig = i }
    elseif text ~= '' then
      final[#final + 1] = { coord = entry.coord, text = text, orig = i, edited = true }
    end
    -- text == "" -> scroll deleted, omitted.
  end
  for key, text in pairs(edits) do
    if not in_index[key] and text ~= '' then
      local c = coord_mod.parse(key)
      final[#final + 1] = { coord = c, text = text, orig = nil, edited = true }
    end
  end
  table.sort(final, function(a, b)
    return coord_mod.compare(a.coord, b.coord) < 0
  end)
  if #final == 0 then
    return ''
  end

  local out = {}
  local prev_coord = coord_mod.default()
  local prev = nil
  for _, item in ipairs(final) do
    -- Verbatim splice: this item is an untouched original whose original
    -- predecessor is exactly the previous final item (or it is the first
    -- original entry and nothing was inserted before it). Copy the
    -- original bytes from the predecessor's span end through this span:
    -- gap + text, byte-identical.
    local verbatim = false
    if item.orig and not item.edited then
      if prev == nil and item.orig == 1 then
        verbatim = true
      elseif prev and prev.orig and item.orig == prev.orig + 1 then
        verbatim = true
      end
    end
    if verbatim then
      local from = prev and idx.entries[prev.orig].e or 1
      out[#out + 1] = idx.bytes:sub(from, idx.entries[item.orig].e - 1)
    else
      if prev ~= nil or not (item.orig == 1 and not item.edited) then
        out[#out + 1] = gap_breaks(prev_coord, item.coord)
      end
      out[#out + 1] = item.text
    end
    prev_coord = item.coord
    prev = item
  end
  -- Preserve any trailing bytes after the last scroll's span (a trailing
  -- break run encoding empty address space) when the last scroll is an
  -- untouched original.
  if prev and prev.orig == #idx.entries and not prev.edited then
    local last_entry = idx.entries[prev.orig]
    assert(last_entry)
    out[#out + 1] = idx.bytes:sub(last_entry.e)
  end
  return table.concat(out)
end

return M
