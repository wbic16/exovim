-- Phext scroll buffers: ordinary text, one scroll at a time.
-- The session machinery lives in nvim.phext; this ftplugin only sets the
-- per-buffer presentation: the coordinate statusline segment and a
-- comment string for the (text) scroll content.

if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true

-- Coordinate replaces line number as the primary "where am I"; the
-- segment is require('nvim.phext').status() (see runtime/doc/phext.txt).
vim.opt_local.statusline = "%{%v:lua.require'nvim.phext'.status()%} %= %l,%c %P"

vim.bo.commentstring = '# %s'

vim.b.undo_ftplugin = 'setlocal statusline< | setlocal commentstring<'
