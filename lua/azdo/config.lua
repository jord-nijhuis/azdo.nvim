--- Configuration for azdo.nvim.
---
--- `require('azdo').setup(opts)` merges `opts` over these defaults; every other
--- module reads `require('azdo.config').options`. There are no `vim.g.*`
--- globals — `setup()` is the single source of truth. |azdo-config|
local M = {}

--- @class azdo.Config
M.defaults = {
  -- Connection / auth -------------------------------------------------------

  --- On-prem Azure DevOps Server collection root, e.g.
  --- "https://tfs.example.com/tfs/MyCollection". nil = cloud dev.azure.com.
  --- @type string?
  base_url = nil,

  --- REST api-version. Older on-prem servers may need e.g. "6.0".
  --- @type string
  api_version = '7.1',

  --- Personal Access Token. A string, or a function returning one (handy for
  --- reading it lazily from a keychain). nil = use `az login`.
  --- @type string|fun():string?|nil
  pat = nil,

  --- Fall back to `$AZDO_PAT` / `$AZURE_DEVOPS_EXT_PAT` when `pat` is unset.
  --- Off by default: `AZURE_DEVOPS_EXT_PAT` belongs to the `az devops` CLI, and
  --- picking it up implicitly means a var exported for an unrelated tool decides
  --- which identity the editor authenticates as, silently overriding `az login`.
  --- @type boolean
  pat_from_env = false,

  --- Default project "org/project" (or just "project" on-prem) used by
  --- `:Azdo items` when you're not inside an Azure DevOps clone.
  --- @type string?
  project = nil,

  -- Behaviour ---------------------------------------------------------------

  --- Open a newly-created PR in a new tab (vs. the current window).
  --- @type boolean
  create_in_tab = true,

  --- Create pull requests as drafts. On by default: a published PR notifies every
  --- required reviewer the moment it exists, and again on each push, so a PR you
  --- are still iterating on burns their attention. Mark it ready in the web UI —
  --- or with the `edit` mapping — once it actually is.
  --- @type boolean
  create_draft = true,

  --- Prefill a new PR's description from the repository's pull-request template
  --- when one exists. Azure DevOps looks for `pull_request_template.md` in
  --- `.azuredevops/`, `.vsts/`, `docs/` or the repo root; so does this, in that
  --- order, plus `.github/` for repos that keep it there. false leaves the
  --- description empty.
  --- @type boolean
  create_template = true,

  --- PR-view settings (the `pr` / `prdiff` / `prcomments` buffers).
  --- @class azdo.Config.pr
  pr = {
    --- The PR diff + comments split.
    --- @class azdo.Config.pr.comments
    comments = {
      --- Width of the comments pane, as a percentage (1-99) of the editor
      --- width. nil keeps Vim's 50% default.
      --- @type number?
      width = nil,
    },
  },

  --- The `:Azdo items` work-items dashboard, and how `open_split` opens the
  --- PR / work item under the cursor. |<Plug>(azdo-open-split)|
  --- @class azdo.Config.items
  items = {
    --- Split direction: 'vertical' (side-by-side) or 'horizontal' (above/below).
    --- @type 'vertical'|'horizontal'
    split = 'vertical',

    --- Split size, as a percentage (1-99) of the editor. For a vertical split
    --- this is the new window's width; for horizontal, its height. nil keeps
    --- Vim's default (an even split).
    --- @type number?
    size = nil,

    --- Default sort for the `:Azdo items` dashboard. One of 'changed',
    --- 'created', 'id', 'title', 'type', 'state', 'assignee' (a trailing
    --- " date" is allowed, e.g. 'created date'). Date sorts are newest-first.
    --- Change it interactively with the `sort` keymap (default `s`).
    --- @type string
    sort = 'changed',

    --- Group the dashboard under `###` subheadings derived from the sort: by
    --- day for date sorts, by state (in workflow/board order) for the 'state'
    --- sort, by type/assignee for those. 'id' and 'title' are never grouped.
    --- false renders a flat list. The `sort` picker can also toggle this.
    --- @type boolean
    group = true,

    --- Fold the dashboard's groups closed by default (only applies when
    --- grouping is on). `false` = all open, `true` = all closed, or a list of
    --- group labels (typically state names, case-insensitive) to start folded
    --- while the rest stay open — e.g. `{ 'Done' }` to collapse finished work
    --- without hiding it. Expand with the standard fold keys: `za` toggles the
    --- group under the cursor, `zR` opens all, `zM` closes all.
    --- @type boolean|string[]
    fold = false,

    --- Who the dashboard lists. 'me' (default) = items assigned to you (`@Me`).
    --- 'all' = everyone's active items. A name string = one person (matched on
    --- display name or unique name, e.g. "Aaron Shahriari"). A list of names =
    --- several people (OR'd). Change it at runtime with the `assignee` keymap
    --- (default `ga`), which pops a multi-select of the project's active
    --- assignees; the choice sticks across refreshes.
    --- @type 'me'|'all'|string|string[]
    assignee = 'me',

    --- The roster offered by the `assignee` picker (default `ga`). A list of
    --- names (display name or unique name / email) you filter by often, e.g.
    --- `{ 'Aaron Shahriari', 'Jane Doe' }`. When set, the picker shows exactly
    --- "All assignees", "Me", and these — instantly, with no extra query. Leave
    --- it empty/nil to instead derive the roster from the project's recently
    --- active work items (one bounded query). |azdo-workitems|
    --- @type string[]?
    assignees = nil,

    --- Work-item states to hide from the active list, case-insensitive, e.g.
    --- `{ 'Done' }` (the WIQL already drops Closed/Removed). Hidden items are
    --- filtered out before grouping and their count is shown in the header;
    --- reveal them at runtime with the `toggle_hidden` keymap (default `gh`).
    --- @type string[]
    hide_states = {},
  },

  --- Log REST calls to `stdpath('log')/azdo.log`.
  --- @type boolean
  debug = false,

  --- Editable rich-text sections for the work-item editor, per work-item type.
  --- `{ [type] = { { title, field }, … } }`; "default" applies to unlisted
  --- types. `field` is the Azure reference name. Override a single type to
  --- replace its section list (e.g. add org-specific custom fields).
  workitem_sections = {
    default = {
      { 'Description', 'System.Description' },
      { 'Acceptance Criteria', 'Microsoft.VSTS.Common.AcceptanceCriteria' },
    },
    Bug = {
      { 'Repro Steps', 'Microsoft.VSTS.TCM.ReproSteps' },
      { 'System Info', 'Microsoft.VSTS.TCM.SystemInfo' },
      { 'Acceptance Criteria', 'Microsoft.VSTS.Common.AcceptanceCriteria' },
    },
  },

  -- Mappings ----------------------------------------------------------------

  --- Buffer-local default mappings inside `azdo://` buffers, as
  --- `{ action = lhs }`. Set one entry to `false` to drop just that key; set
  --- `keymaps = false` to disable all defaults. The wiring (which
  --- `<Plug>(azdo-…)` each action fires) lives in util.lua. |azdo-mappings|
  keymaps = {
    refresh = 'R',
    diff_toggle = 'dd',
    logs = 'dl',
    pipeline = 'dp',
    next_commit = ']f',
    prev_commit = '[f',
    web = 'gw',
    link = 'gW',
    help = 'g?',
    comment_overview = 'cC',
    merge = 'cM',
    review = 'cR',
    edit = 'c:',
    comment = 'cc',
    comment_visual = 'c',
    thread = 'cr',
    comment_delete = 'cd',
    comment_update = 'cu',
    open = '<CR>',
    open_split = '<C-W><CR>',
    next_comment = ']c',
    prev_comment = '[c',
    tag_toggle = 't',
    sort = 's',
    set_state = 'cc',
    start_branch = 'cb',
    toggle_hidden = 'gh',
    assignee = 'ga',
  },

  --- Optional global mapping for the `:AzdoMenu` command palette, e.g.
  --- "<leader>a". nil = don't map anything (use `:AzdoMenu` / `<Plug>(azdo-menu)`).
  --- @type string?
  menu = nil,
}

--- The active, merged configuration. Read this everywhere.
--- @type azdo.Config
M.options = vim.deepcopy(M.defaults)

--- Merge `opts` over the defaults. Most keys merge deeply, but the two
--- list-bearing categories are merged one level deep so you can override a
--- single entry without re-specifying the rest:
---  - `workitem_sections`: per work-item type (each type's section list is
---    replaced wholesale, since a deep merge would splice the arrays).
---  - `keymaps`: per action (or `keymaps = false` to disable all).
--- @param opts azdo.Config?
--- @return azdo.Config
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)

  -- workitem_sections values are LISTS; tbl_deep_extend would merge them
  -- element-wise. Replace per work-item type instead.
  if opts.workitem_sections then
    merged.workitem_sections = vim.tbl_extend('force', vim.deepcopy(M.defaults.workitem_sections), opts.workitem_sections)
  end

  -- Backward-compat: the flat `comments_width` moved under `pr.comments.width`.
  -- Honor the old key (unless `pr.comments.width` was set explicitly).
  local explicit = opts.pr and opts.pr.comments and opts.pr.comments.width
  if opts.comments_width ~= nil and explicit == nil then
    merged.pr.comments.width = opts.comments_width
  end
  merged.comments_width = nil

  M.options = merged
  return M.options
end

--- Resolve the PAT (the `pat` option may be a string or a function).
--- @return string?
function M.pat()
  local p = M.options.pat
  if type(p) == 'function' then
    p = p()
  end
  if type(p) == 'string' and p ~= '' then
    return p
  end
  return nil
end

return M
