--- azdo.nvim public API.
---
--- `require('azdo').setup{…}` configures the plugin (see |azdo-config|); the
--- functions below are the public actions — map them directly, or call them
--- from your own code. The `:Azdo*` commands and `<Plug>(azdo-…)` maps are
--- registered at startup by plugin/azdo.lua and don't need setup() to exist.
local M = {}

--- Configure azdo.nvim. Merges `opts` over the defaults in |azdo-config| and,
--- if `opts.menu` is a key, maps it to the `:AzdoMenu` palette.
--- @param opts azdo.Config?
function M.setup(opts)
  local config = require('azdo.config')
  config.setup(opts)
  local menu = config.options.menu
  if type(menu) == 'string' and menu ~= '' then
    vim.keymap.set('n', menu, '<Plug>(azdo-menu)', { desc = 'Azdo: command palette' })
  end
  return M
end

-- Public actions ------------------------------------------------------------

--- Open the status dashboard (open PRs for the current repo). `:Azdo`
function M.status()
  vim.cmd('Azdo')
end

--- Open the work-items dashboard (items assigned to you). `:Azdo items`
function M.work_items()
  vim.cmd('Azdo items')
end

--- Open a PR / work item / commit by id, URL, or sha. `:Azdo <target>`
--- @param target string
function M.open(target)
  vim.cmd.Azdo(target)
end

--- Open the command palette. `:AzdoMenu`
function M.menu()
  require('azdo.menu').open()
end

--- Create a PR from the current branch. `:AzdoCreate`
function M.create_pr()
  require('azdo.pr').create_pr()
end

--- Merge (complete) the PR in the current buffer.
function M.merge()
  require('azdo.pr').merge_pr()
end

--- Review the PR in the current buffer (approve / request-changes / comment).
function M.review()
  require('azdo.pr').review_pr()
end

--- Finishes the review of the PR in the current buffer: removes its worktree,
--- closes its tab, drops its buffers. The counterpart to `co`.
function M.finish()
  require('azdo.pr').finish()
end

--- Edit the current PR's title/description or a work item's sections.
function M.edit()
  require('azdo.pr').edit_pr()
end

--- Link a work item assigned to you to the current PR. `:AzdoLink`
function M.link()
  require('azdo.pr').link_workitem()
end

--- Open the current PR / work item in the web browser.
function M.web()
  require('azdo.pr').open_web()
end

--- Refresh the current `azdo://` buffer.
function M.refresh()
  require('azdo.pr').refresh()
end

return M
