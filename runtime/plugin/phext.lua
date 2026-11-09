-- phext scroll navigation — plugin entry point.
--
-- Purely additive runtime support: filetype detection happens here via
-- autocmd (BufReadCmd/BufNewFile for *.phext) so the patch set touches
-- ZERO existing upstream files. Disable with g:loaded_phext set before
-- this file is sourced, or by removing the runtime files.
--
-- Opt-out for the buffer-local ]] / [[ section-motion overrides:
--   let g:phext_no_section_motions = 1

if vim.g.loaded_phext then
  return
end
vim.g.loaded_phext = 1

local group = vim.api.nvim_create_augroup('Phext', { clear = true })

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = group,
  pattern = '*.phext',
  desc = 'phext: load a .phext file as a scroll session',
  callback = function(ev)
    require('nvim.phext').read(ev)
  end,
})

vim.api.nvim_create_autocmd('BufNewFile', {
  group = group,
  pattern = '*.phext',
  desc = 'phext: start an empty session for a new .phext file',
  callback = function(ev)
    require('nvim.phext').new_file(ev)
  end,
})

-- Buffer names are phext://<path>@<coordinate> once a session exists, so
-- the write hook matches the phext:// scheme, not the *.phext glob.
vim.api.nvim_create_autocmd('BufWriteCmd', {
  group = group,
  pattern = 'phext://*',
  desc = 'phext: serialise a scroll session on :write',
  callback = function(ev)
    require('nvim.phext').write(ev.buf)
  end,
})

local function cmd(name, fn, opts)
  opts = opts or {}
  opts.desc = opts.desc or ('phext: ' .. name)
  vim.api.nvim_create_user_command(name, fn, opts)
end

cmd('PhextGoto', function(o)
  require('nvim.phext').cmd_goto(o)
end, {
  nargs = '?',
  desc = 'phext: go to coordinate',
  complete = function(lead)
    return require('nvim.phext').complete_goto(lead)
  end,
})

cmd('PhextCoord', function()
  require('nvim.phext').cmd_coord()
end, { desc = 'phext: show coordinate, dimension, neighbours' })

cmd('PhextDim', function(o)
  require('nvim.phext').cmd_dim(o)
end, { nargs = '?', desc = 'phext: set/show active dimension (1-9 or name)' })

cmd('PhextStep', function(o)
  require('nvim.phext').cmd_step(o)
end, { nargs = '*', desc = 'phext: step a dimension: :PhextStep {dim} [+n|-n]' })

cmd('PhextNext', function(o)
  require('nvim.phext').cmd_next(o)
end, { count = true, desc = 'phext: next populated scroll' })

cmd('PhextPrev', function(o)
  require('nvim.phext').cmd_prev(o)
end, { count = true, desc = 'phext: previous populated scroll' })

cmd('PhextToc', function(o)
  require('nvim.phext').cmd_toc(o)
end, { nargs = '?', desc = 'phext: open the outline (outer|middle|inner)' })

cmd('PhextSearch', function(o)
  require('nvim.phext').cmd_search(o)
end, { nargs = '+', desc = 'phext: search all scrolls into quickfix' })

cmd('PhextGrep', function(o)
  require('nvim.phext').cmd_search(o)
end, { nargs = '+', desc = 'phext: alias for :PhextSearch' })

cmd('PhextTitles', function(o)
  require('nvim.phext').cmd_titles(o)
end, { nargs = '?', desc = 'phext: pick a scroll by first-line title' })

cmd('PhextNew', function(o)
  require('nvim.phext').cmd_new(o)
end, {
  nargs = '?',
  desc = 'phext: go to a coordinate intending to create the scroll',
  complete = function(lead)
    return require('nvim.phext').complete_goto(lead)
  end,
})

cmd('PhextDelete', function()
  require('nvim.phext').cmd_delete()
end, { desc = 'phext: empty the current scroll (deleted on :write)' })

cmd('PhextMarks', function()
  require('nvim.phext').cmd_marks()
end, { desc = 'phext: list the phext mark and buffer/global marks' })
