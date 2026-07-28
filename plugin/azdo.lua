vim.api.nvim_set_hl(0, 'AzdoHeading', { default = true, link = 'PmenuSel' })
vim.api.nvim_set_hl(0, 'AzdoWarning', { default = true, link = 'WarningMsg' })

local group = vim.api.nvim_create_augroup('azdo.keymaps', { clear = true })

-- ":edit azdo://org/project/repo/pr/N" (etc.) dispatches to :Azdo.
-- Wipe the placeholder buffer that :edit created.
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'azdo://*',
  group = group,
  callback = function(args)
    local uri = args.match
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.api.nvim_buf_delete(args.buf, { force = true })
      end
      vim.cmd('Azdo ' .. vim.fn.fnameescape(uri))
    end)
  end,
})

-- :syncbind the prdiff/prcomments windows.
vim.api.nvim_create_autocmd({ 'WinEnter', 'WinResized' }, {
  pattern = { 'azdo://*/prdiff/*', 'azdo://*/prcomments/*' },
  group = group,
  command = 'keepjumps syncbind',
})

vim.api.nvim_create_user_command('Azdo', function(args)
  require('azdo.pr').select(args)
end, { nargs = '?' })
vim.api.nvim_create_user_command('AzdoComment', function(args)
  require('azdo.pr').comment(args)
end, { bang = true, range = true })
vim.api.nvim_create_user_command('AzdoCreate', function()
  require('azdo.pr').create_pr()
end, {})
vim.api.nvim_create_user_command('AzdoLink', function()
  require('azdo.pr').link_workitem()
end, {})
vim.api.nvim_create_user_command('AzdoMenu', function(args)
  require('azdo.menu').open({ mods = args.mods })
end, {})

local opts = { silent = true }
vim.keymap.set('n', '<Plug>(azdo-review)', function()
  require('azdo.pr').review_pr()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-merge)', function()
  require('azdo.pr').merge_pr()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-edit)', function()
  require('azdo.pr').edit_pr()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-create)', function()
  require('azdo.pr').create_pr()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-web)', function()
  require('azdo.pr').open_web()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-link)', function()
  require('azdo.pr').link_workitem()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-tag-toggle)', function()
  require('azdo.pr').tag_toggle()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-sort)', function()
  require('azdo.pr').sort_workitems()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-set-state)', function()
  require('azdo.pr').set_state()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-start-branch)', function()
  require('azdo.pr').start_branch()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-toggle-hidden)', function()
  require('azdo.pr').toggle_hidden()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-assignee)', function()
  require('azdo.pr').filter_assignee()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-comment)', '<cmd>AzdoComment<cr>', opts)
-- Use ":" in Visual mode so the `'<,'>` range is passed to the command.
vim.keymap.set('x', '<Plug>(azdo-comment)', ':AzdoComment<cr>', opts)
vim.keymap.set('n', '<Plug>(azdo-comment-overview)', '<cmd>%AzdoComment<cr>', opts)
vim.keymap.set('n', '<Plug>(azdo-thread)', function()
  require('azdo.comments').reply_or_resolve(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(azdo-comment-delete)', function()
  require('azdo.comments').delete_comment(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(azdo-comment-update)', function()
  require('azdo.comments').update_comment(vim.fn.line('.'))
end, opts)
vim.keymap.set('n', '<Plug>(azdo-next-comment)', function()
  require('azdo.comments').goto_comment(1)
end, opts)
vim.keymap.set('n', '<Plug>(azdo-prev-comment)', function()
  require('azdo.comments').goto_comment(-1)
end, opts)
vim.keymap.set('n', '<Plug>(azdo-diff)', function()
  require('azdo.pr').show_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-diff-toggle)', function()
  require('azdo.pr').toggle_pr_diff()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-logs)', function()
  require('azdo.pr').show_ci_logs()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-pipeline)', function()
  require('azdo.pr').queue_pipeline()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-help)', '<cmd>help azdo-mappings<cr>', opts)
vim.keymap.set('n', '<Plug>(azdo-menu)', '<cmd>AzdoMenu<cr>', opts)
vim.keymap.set('n', '<Plug>(azdo-refresh)', function()
  require('azdo.pr').refresh()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-open)', function()
  vim.cmd.Azdo(vim.fn.expand('<cWORD>'))
end, opts)
vim.keymap.set('n', '<Plug>(azdo-open-split)', function()
  local items = require('azdo.config').options.items or {}
  local vertical = (items.split or 'vertical') ~= 'horizontal'
  vim.api.nvim_cmd({
    cmd = 'Azdo',
    args = { vim.fn.expand('<cWORD>') },
    mods = vertical and { vertical = true } or { horizontal = true },
  }, {})
  -- `:Azdo` created (and focused) the split synchronously; size it now.
  local size = items.size
  if type(size) == 'number' and size > 0 and size < 100 then
    local total = vertical and vim.o.columns or vim.o.lines
    vim.cmd((vertical and 'vertical resize ' or 'resize ') .. math.floor(total * size / 100 + 0.5))
  end
end, opts)
vim.keymap.set('n', '<Plug>(azdo-open-tab)', function()
  -- `mods.tab` is the tab to open *after*, which is what `:tab <cmd>` sets it to;
  -- -1 (the default) means "no tab modifier" and would open in place.
  vim.api.nvim_cmd(
    { cmd = 'Azdo', args = { vim.fn.expand('<cWORD>') }, mods = { tab = vim.fn.tabpagenr() } },
    {}
  )
end, opts)
vim.keymap.set('n', '<Plug>(azdo-checkout)', function()
  require('azdo.pr').checkout()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-finish)', function()
  require('azdo.pr').finish()
end, opts)
vim.keymap.set('n', '<Plug>(azdo-next-commit)', function()
  require('azdo.pr').show_next_commit(1)
end, opts)
vim.keymap.set('n', '<Plug>(azdo-prev-commit)', function()
  require('azdo.pr').show_next_commit(-1)
end, opts)
