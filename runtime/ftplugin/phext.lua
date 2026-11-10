-- Phext scroll buffers: ordinary text, one scroll at a time.
-- The session machinery lives in nvim.phext; this ftplugin only sets the
-- per-buffer presentation: the coordinate statusline segment and a
-- comment string for the (text) scroll content.

if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = true

-- The coordinate is always on screen, next to line and column: the
-- statusline shows require('nvim.phext').status() (full 9D coordinate,
-- scroll rank, active dimension, [+] when the session has unsaved
-- edits) plus the cursor's %l,%c inside the scroll, which the
-- statusline refreshes natively on every cursor move. On by default;
-- opt out with g:phext_ui_statusline = 0 (or g:phext_ui.statusline =
-- false) to keep your own statusline — status() stays available to it.
-- Set via the function form: the option-value meta type for 'statusline'
-- rejects the %{%...%} expression form on direct assignment.
if require('nvim.phext')._ui_enabled('statusline') then
  vim.opt_local.statusline:append("%{%v:lua.require'nvim.phext'.status()%} %= %l,%c %P")
end

vim.bo.commentstring = '# %s'

vim.b.undo_ftplugin = 'setlocal statusline< | setlocal commentstring<'
