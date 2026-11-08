-- nvim.phext.coord — phext coordinate parsing and arithmetic.
--
-- A coordinate is a plain array of 9 integers, 1-based, with NO upper bound
-- (libphext 0.4.0 removed the old 999 cap; do not reintroduce it):
--
--   index:  1        2      3       4           5       6     7        8        9
--   name:   library  shelf  series  collection  volume  book  chapter  section  scroll
--   string: library.shelf.series/collection.volume.book/chapter.section.scroll
--
-- User-facing dimension numbers run the other way, matching the editors this
-- design is ported from: dimension 1 = scroll, 2 = section, ..., 9 = library.
-- Array position p and user dimension d are related by p = 10 - d.
--
-- Delimiter bytes (libphext-rs src/phext.rs, LIBRARY_BREAK..SCROLL_BREAK;
-- identical table in parse_phext.py):
--   library 0x01, shelf 0x1F, series 0x1E, collection 0x1D, volume 0x1C,
--   book 0x1A, chapter 0x19, section 0x18, scroll 0x17.  (0x1B is not a break.)
-- A break at position p increments component p and resets all lower
-- components (positions > p) to 1.

local M = {}

--- Dimension names by array position (1 = highest).
M.NAMES = {
  'library',
  'shelf',
  'series',
  'collection',
  'volume',
  'book',
  'chapter',
  'section',
  'scroll',
}

--- Break byte by array position (1 = library .. 9 = scroll).
M.BREAK_BYTE = { 0x01, 0x1F, 0x1E, 0x1D, 0x1C, 0x1A, 0x19, 0x18, 0x17 }

--- Break byte -> array position.
M.BYTE_TO_POS = {}
for pos, b in ipairs(M.BREAK_BYTE) do
  M.BYTE_TO_POS[b] = pos
end

--- Dimension name by user dimension number (1 = scroll .. 9 = library).
M.DIM_NAMES = {}
for pos, name in ipairs(M.NAMES) do
  M.DIM_NAMES[10 - pos] = name
end

--- Name -> user dimension number.
M.NAME_TO_DIM = {}
for dim, name in ipairs(M.DIM_NAMES) do
  M.NAME_TO_DIM[name] = dim
end

--- The home coordinate 1.1.1/1.1.1/1.1.1 (fresh copy each call).
---@return integer[]
function M.default()
  return { 1, 1, 1, 1, 1, 1, 1, 1, 1 }
end

---@param c integer[]
---@return integer[]
function M.copy(c)
  return { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9] }
end

--- True when every component is an integer >= 1 (no upper bound).
---@param c any
---@return boolean
function M.is_valid(c)
  if type(c) ~= 'table' or #c ~= 9 then
    return false
  end
  for i = 1, 9 do
    local v = c[i]
    if type(v) ~= 'number' or v < 1 or v ~= math.floor(v) then
      return false
    end
  end
  return true
end

---@param c integer[]
---@return string
function M.tostring(c)
  return string.format(
    '%d.%d.%d/%d.%d.%d/%d.%d.%d',
    c[1],
    c[2],
    c[3],
    c[4],
    c[5],
    c[6],
    c[7],
    c[8],
    c[9]
  )
end

--- Map key for a coordinate (its canonical string form).
M.key = M.tostring

---@param a integer[]
---@param b integer[]
---@return integer -1, 0 or 1 (document order = lexicographic by position 1..9)
function M.compare(a, b)
  for i = 1, 9 do
    if a[i] ~= b[i] then
      return a[i] < b[i] and -1 or 1
    end
  end
  return 0
end

---@param a integer[]
---@param b integer[]
---@return boolean
function M.eq(a, b)
  return M.compare(a, b) == 0
end

--- Apply one delimiter break at array position `pos` to `c`, in place:
--- increment component `pos`, reset every lower component to 1.
---@param c integer[]
---@param pos integer 1..9
function M.apply_break(c, pos)
  c[pos] = c[pos] + 1
  for i = pos + 1, 9 do
    c[i] = 1
  end
end

--- Resolve a user dimension (number 1..9 or name) to a number, or nil.
---@param dim integer|string
---@return integer|nil
function M.dim_number(dim)
  if type(dim) == 'number' then
    if dim >= 1 and dim <= 9 and dim == math.floor(dim) then
      return dim
    end
    return nil
  end
  if type(dim) == 'string' then
    local n = tonumber(dim)
    if n then
      return M.dim_number(n)
    end
    return M.NAME_TO_DIM[dim:lower()]
  end
  return nil
end

--- Step coordinate `c` along user dimension `dim` by `delta` steps.
--- Each step increments the dimension and resets all lower dimensions to 1;
--- backward steps clamp at the floor of 1 (and still reset lower dimensions,
--- matching the reference editors). The closed form below is exactly the
--- iterated single-step semantics. Returns a new coordinate.
---@param c integer[]
---@param dim integer 1..9 (user dimension)
---@param delta integer
---@return integer[]
function M.step(c, dim, delta)
  local out = M.copy(c)
  if delta == 0 then
    return out
  end
  local pos = 10 - dim
  if delta > 0 then
    out[pos] = out[pos] + delta
  else
    out[pos] = math.max(1, out[pos] + delta)
  end
  for i = pos + 1, 9 do
    out[i] = 1
  end
  return out
end

local function split_plain(s, sep)
  local parts = {}
  local pos = 1
  while true do
    local i = s:find(sep, pos, true)
    if not i then
      parts[#parts + 1] = s:sub(pos)
      break
    end
    parts[#parts + 1] = s:sub(pos, i - 1)
    pos = i + #sep
  end
  return parts
end

--- Parse one arm ("a.b.c") into three positive integers, or nil + error.
local function parse_arm(s)
  local comps = split_plain(s, '.')
  if #comps ~= 3 then
    return nil, ('expected three components in %q'):format(s)
  end
  local out = {}
  for i, p in ipairs(comps) do
    local n = tonumber(p)
    if not n or n < 1 or n ~= math.floor(n) then
      return nil, ('invalid coordinate component %q'):format(p)
    end
    out[i] = n
  end
  return out
end

--- Parse a coordinate string, optionally relative to `base`.
--- Accepted forms:
---   full:    "33.5.9/7.5.9/5.5.8"
---   partial: trailing arms align to the right — "5.5.8" sets the
---            chapter.section.scroll arm and keeps the rest of `base`;
---            "7.5.9/5.5.8" sets volume..scroll arms, keeping library..series.
---   empty arms keep the base arm: "/7.5.9/" keeps Z and X arms of `base`.
--- Without `base`, missing arms default to 1.
---@param s string
---@param base integer[]|nil
---@return integer[]|nil coord, string|nil err
function M.parse(s, base)
  if type(s) ~= 'string' then
    return nil, 'coordinate must be a string'
  end
  s = s:match('^%s*(.-)%s*$')
  if s == '' then
    return nil, 'empty coordinate'
  end
  local arms = split_plain(s, '/')
  if #arms > 3 then
    return nil, ('too many arms in %q'):format(s)
  end
  local out = base and M.copy(base) or M.default()
  -- Right-align: the last arm is always chapter.section.scroll (positions 7..9).
  local first_arm = 3 - #arms + 1
  for i, arm_str in ipairs(arms) do
    if arm_str ~= '' then
      local arm, err = parse_arm(arm_str)
      if not arm then
        return nil, err
      end
      local base_pos = (first_arm + i - 2) * 3
      out[base_pos + 1] = arm[1]
      out[base_pos + 2] = arm[2]
      out[base_pos + 3] = arm[3]
    end
  end
  return out
end

return M
