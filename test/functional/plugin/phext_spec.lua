-- Functional tests for the phext runtime plugin (runtime/plugin/phext.lua,
-- runtime/lua/nvim/phext/*). The plugin is runtime-only, so these run
-- against any exovim build; the same assertions are also exercised by the
-- standalone harness described in PATCHES.md.
local t = require('test.testutil')
local n = require('test.functional.testnvim')()

-- NOTE (0.12 base): describe/it/before_each are busted globals here;
-- master's testutil re-exports them (t.describe), this base's does not.
local clear = n.clear
local command = n.command
local feed = n.feed
local exec_lua = n.exec_lua
local eq = t.eq

local fixtures = vim.fs.joinpath(t.paths.test_source_path, 'test/functional/fixtures/phext')

--- Copy a fixture to a writable temp .phext file inside the child and
--- return its path.
local function edit_copy(fixture)
  return exec_lua(
    [[
    local src = ...
    local f = assert(io.open(src, 'rb'))
    local data = f:read('*a')
    f:close()
    local dst = vim.fn.tempname() .. '.phext'
    local g = assert(io.open(dst, 'wb'))
    g:write(data)
    g:close()
    return dst
  ]],
    vim.fs.joinpath(fixtures, fixture)
  )
end

local function buf_text()
  return exec_lua([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')]])
end

local function cur_coord()
  return exec_lua(
    [[return require('nvim.phext.coord').tostring(require('nvim.phext').coordinate())]]
  )
end

local function file_hash(path)
  return exec_lua(
    [[
    local f = assert(io.open(..., 'rb'))
    local data = f:read('*a')
    f:close()
    return vim.fn.sha256(data)
  ]],
    path
  )
end

describe('phext runtime plugin', function()
  before_each(function()
    clear { args = { '-u', 'NORC' } }
    exec_lua([[vim.cmd('runtime! plugin/phext.lua')]])
  end)

  it('opens a .phext file as a scroll session at the home coordinate', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    eq('phext', exec_lua([[return vim.bo.filetype]]))
    eq('alpha\nline2', buf_text())
    eq('1.1.1/1.1.1/1.1.1', cur_coord())
    eq(1, exec_lua([[return vim.api.nvim_buf_get_name(0):match('^phext://') and 1 or 0]]))
  end)

  it('no-op :write is byte-identical', function()
    local path = edit_copy('basic.phext')
    local before = file_hash(path)
    command('edit ' .. path)
    command('write')
    eq(before, file_hash(path))
  end)

  it('walks populated scrolls with :PhextNext / :PhextPrev', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    command('PhextNext')
    eq('beta', buf_text())
    eq('1.1.1/1.1.1/1.1.2', cur_coord())
    command('PhextNext')
    eq('gamma', buf_text())
    eq('1.1.1/1.1.1/1.2.1', cur_coord())
    command('PhextPrev')
    eq('beta', buf_text())
  end)

  it('skips empty coordinates in populated navigation (gaps fixture)', function()
    local path = edit_copy('gaps.phext')
    command('edit ' .. path)
    eq('one', buf_text())
    command('PhextNext')
    eq('three', buf_text())
    eq('1.1.1/1.1.1/1.1.3', cur_coord())
  end)

  it(':PhextGoto accepts partial (trailing-arm) coordinates', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    command('PhextGoto 1.2.1')
    eq('gamma', buf_text())
    eq('1.1.1/1.1.1/1.2.1', cur_coord())
  end)

  it(':PhextStep resets lower dimensions and may land on empty space', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    command('PhextStep chapter +1')
    eq('1.1.1/1.1.1/2.1.1', cur_coord())
    eq('', buf_text())
    command('PhextStep chapter -1')
    eq('1.1.1/1.1.1/1.1.1', cur_coord())
  end)

  it('confines a written edit to the edited scroll span', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    exec_lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'alpha EDITED' })]])
    command('write')
    local content = exec_lua(
      [[
      local f = assert(io.open(..., 'rb'))
      local data = f:read('*a')
      f:close()
      return data
    ]],
      path
    )
    eq('alpha EDITED\23beta\24gamma', content)
  end)

  it('deletes an emptied scroll on save and creates a new scroll on save', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    command('PhextGoto 1.1.1/1.1.1/1.1.2')
    exec_lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { '' })]])
    command('write')
    eq(
      0,
      exec_lua(
        [[
        local path = ...
        local idx = require('nvim.phext.index').build((function()
          local f = assert(io.open(path, 'rb'))
          local d = f:read('*a')
          f:close()
          return d
        end)())
        return idx.by_key['1.1.1/1.1.1/1.1.2'] and 1 or 0
      ]],
        path
      )
    )
    command('PhextGoto 1.1.1/1.1.1/5.5.5')
    exec_lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'created' })]])
    command('write')
    eq(
      'created',
      exec_lua(
        [[
        local path = ...
        local idx = require('nvim.phext.index').build((function()
          local f = assert(io.open(path, 'rb'))
          local d = f:read('*a')
          f:close()
          return d
        end)())
        local i = idx.by_key['1.1.1/1.1.1/5.5.5']
        return i and require('nvim.phext.index').entry_text(idx, idx.entries[i]) or ''
      ]],
        path
      )
    )
  end)

  it('preserves trailing newlines as scroll content', function()
    local path = edit_copy('newlines.phext')
    local before = file_hash(path)
    command('edit ' .. path)
    command('write')
    eq(before, file_hash(path))
    command('PhextGoto 1.1.1/1.1.1/1.1.3')
    eq('\n', buf_text())
  end)

  it(':PhextSearch fills the quickfix list with coordinates as modules', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    command('PhextSearch gamma')
    local qf = exec_lua([[return vim.fn.getqflist()]])
    eq(1, #qf)
    eq('1.1.1/1.1.1/1.2.1', qf[1].module)
    feed('<CR>')
    eq('1.1.1/1.1.1/1.2.1', cur_coord())
    eq('gamma', buf_text())
  end)

  it('refuses to overwrite a file changed on disk since load', function()
    local path = edit_copy('basic.phext')
    command('edit ' .. path)
    exec_lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'edited' })]])
    exec_lua(
      [[
      local g = assert(io.open(..., 'wb'))
      g:write('external')
      g:close()
    ]],
      path
    )
    eq(0, exec_lua([[return pcall(vim.cmd, 'write') and 1 or 0]]))
    eq(
      'external',
      exec_lua(
        [[
        local f = assert(io.open(..., 'rb'))
        local d = f:read('*a')
        f:close()
        return d
      ]],
        path
      )
    )
  end)
end)
