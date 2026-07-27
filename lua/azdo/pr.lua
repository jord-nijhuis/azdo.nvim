--- The main "app" code. Displays PRs / work-items / repo-status for Azure DevOps.

local comments = require('azdo.comments')
local az = require('azdo.az')
local state = require('azdo.state')
local tags = require('azdo.tags')
local util = require('azdo.util')
local config = require('azdo.config')

local M = {}

-- Branch candidates for the `:AzdoCreate` target-branch prompt, refreshed just
-- before each prompt. Read by `_complete_branch` (the input() completion fn).
local branch_candidates = {}

--- `customlist` completion for the target-branch prompt. Prefix-matches the
--- branches gathered in `branch_candidates`. Referenced as
--- `v:lua.require'azdo.pr'._complete_branch`.
--- @param arglead string
--- @return string[]
function M._complete_branch(arglead)
  if arglead == '' then
    return branch_candidates
  end
  return vim.tbl_filter(function(b)
    return b:find('^' .. vim.pesc(arglead)) ~= nil
  end, branch_candidates)
end

--- Parses `git for-each-ref …:short` output into a sorted, de-duplicated branch
--- list (origin/ prefix stripped, HEAD dropped).
--- @param refs string
--- @return string[]
local function collect_branches(refs)
  local seen, out = {}, {}
  for line in tostring(refs or ''):gmatch('[^\r\n]+') do
    local name = line:gsub('^origin/', '')
    if name ~= '' and name ~= 'HEAD' and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

--- Resolves the current local repo "org/project/repo", blocking up to 5s.
--- @return string?
local function resolve_local_repo()
  local repo
  az.get_repo(function(r)
    repo = r
  end)
  vim.wait(5000, function()
    return not not repo
  end)
  return repo
end

--- Azure DevOps' search order for a repo's default pull-request template, plus
--- `.github/` for repos that keep it there. Azure DevOps also supports a
--- `pull_request_template/` *directory* of named templates; picking between those
--- is a prompt this does not try to be, so only the default file is read.
local PR_TEMPLATE_PATHS = {
  '.azuredevops/pull_request_template.md',
  '.vsts/pull_request_template.md',
  'docs/pull_request_template.md',
  'pull_request_template.md',
  '.github/pull_request_template.md',
}

--- Reads the repository's pull-request template, if it has one and
--- `create_template` is on.
---
--- Resolved against the repo root rather than the working directory so it is
--- found from a subdirectory or a worktree. Exposed for tests.
--- @return string[]? lines
function M._read_pr_template()
  if config.options.create_template == false then
    return nil
  end
  local root = vim.fn.systemlist({ 'git', 'rev-parse', '--show-toplevel' })[1]
  if vim.v.shell_error ~= 0 or not root or root == '' then
    return nil
  end
  for _, rel in ipairs(PR_TEMPLATE_PATHS) do
    local path = root .. '/' .. rel
    if vim.fn.filereadable(path) == 1 then
      local lines = vim.fn.readfile(path)
      if #lines > 0 then
        return lines
      end
    end
  end
  return nil
end

--- The project segment of an "org/project/repo" string (work-item tags are keyed by it).
--- @param repo string?
--- @return string?
local function project_label(repo)
  return repo and (repo:match('^[^/]+/([^/]+)/') or repo) or nil
end

--- Resolves an "org/project/repo"-shaped string for project-level (work-item) endpoints.
--- Work items are project-scoped, so the repo segment is only a placeholder ("_") here —
--- `az.project_base()` reads org+project and ignores the name.
--- Precedence: the `project` option ("org/project", or just "project" on-prem where the
--- collection lives in `base_url`) > current buffer's repo > local git clone.
--- @return string? repo, string? label "<project>" for display
local function resolve_project_repo()
  local p = config.options.project
  if type(p) == 'string' and p ~= '' then
    local parts = vim.split(p, '/', { plain = true, trimempty = true })
    if #parts >= 2 then
      return ('%s/%s/_'):format(parts[1], parts[2]), parts[2]
    elseif #parts == 1 then
      return ('_/%s/_'):format(parts[1]), parts[1] -- on-prem: org folded into azdo_base_url
    end
  end
  local repo = (vim.b.azdo or {}).repo or resolve_local_repo()
  return repo, project_label(repo)
end

--- @param repo string "org/project/repo"
--- @return string org, string project, string name
local function split_repo(repo)
  return repo:match('^([^/]+)/([^/]+)/(.+)$')
end

--- Finds the first `pr/…` buffer matching the given commit `sha`.
---
--- @param sha string
--- @return integer? pr_id
--- @return integer? commit_idx 1-based index of the matching commit in `pr_data.commits`.
local function find_pr_for_commit_sha(sha)
  for _, pr_buf in pairs(state.bufs.pr or {}) do
    local pr_data = vim.fn.getbufvar(pr_buf, 'azdo', {}).pr_data
    for i, c in ipairs(pr_data and pr_data.commits or {}) do
      if c.oid == sha then
        return pr_data.number, i
      end
    end
  end
end

--- Resolves `(pr_id, repo, commit_idx)` from an :Azdo arg, falling back to `b:azdo` and `resolve_local_repo()`.
---
--- @param opts integer|string|table|nil Table form may be cmdline "args", or explicit `{id=…,repo=…}`.
--- @return Feat? feat `b:azdo.feat`, or nil if `opts` provided an explicit id.
--- @return integer id
--- @return string repo
--- @return integer? commit_idx
local function resolve_pr(opts)
  local b_azdo = vim.b.azdo
  local opts_t = type(opts) == 'table' and opts or {}
  local id = opts_t.id or (opts_t.args and tonumber(opts_t.args)) or tonumber(opts)
  if not id and not b_azdo then
    error('azdo: Not in an azdo:// buffer', 0)
  end

  local commit_idx
  if not id then
    if b_azdo.feat == 'commit' then
      id, commit_idx = find_pr_for_commit_sha(b_azdo.id)
    else
      id = vim._tointeger(b_azdo.id)
    end
  end
  if not id then
    error('azdo: Failed to resolve PR id', 0)
  end

  local repo = opts_t.repo or (b_azdo or {}).repo or resolve_local_repo()
  if not repo then
    error('azdo: Failed to resolve repo', 0)
  end
  return b_azdo and b_azdo.feat or nil, id, repo, commit_idx
end

--- Implements `:Azdo`.
function M.select(opts)
  if not az.get_user() then
    util.msg('Not logged in to Azure CLI. Run: "az login"', vim.log.levels.ERROR)
    return
  end

  local arg = (opts or {}).args or ''

  -- Flash the cWORD if it matches the arg (so `:Azdo <cWORD>` works without a wrapper).
  if arg == vim.fn.expand('<cWORD>') then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local on_blank = vim.api.nvim_get_current_line():sub(col + 1, col + 1):match('%S') == nil
    local _, c = unpack(vim.fn.searchpos([[\v(^|\s)@<=\S]], on_blank and 'cnW' or 'bcnW'))
    util.hl_flash(0, { row - 1, c - 1 }, { row - 1, c - 1 + #arg })
  end

  -- Support command mods (`:vertical Azdo …`). See `:help <mods>`.
  local smods = (opts or {}).smods or {}
  local window_mod = (smods.split or '') ~= '' or smods.vertical or smods.horizontal or
      (smods.tab or -1) >= 0
  local focus = not window_mod

  -- Work-items dashboard: `:Azdo items` (aka `mine` / `workitems`).
  if arg:match('^%s*items%s*$') or arg:match('^%s*mine%s*$') or arg:match('^%s*workitems%s*$') then
    if window_mod then
      vim.cmd(((opts or {}).mods or '') .. ' new')
    end
    return M.show_workitems(focus)
  end

  local target, repo
  if #arg > 0 then
    target = util.parse_target(arg)
    if not target then
      util.msg(('failed to parse: %s'):format(arg), vim.log.levels.ERROR)
      return
    end
    repo = target.repo or (vim.b.azdo or {}).repo or resolve_local_repo()
    if not repo then
      util.msg('Failed to get repo info', vim.log.levels.ERROR)
      return
    end
  end

  local function dispatch(is_pr)
    if window_mod then
      vim.cmd(((opts or {}).mods or '') .. ' new')
    end
    if not target then
      M.show_status(focus)
    elseif target.sha then
      M.show_commit(target.sha, repo, focus)
    elseif not target.id then
      M.show_status(focus, repo)
    elseif target.is_pr == true or (target.is_pr == nil and is_pr) then
      M.show_pr(target.id, repo, focus)
    else
      M.show_issue(target.id, repo, focus)
    end
  end

  if target and target.id and target.is_pr == nil and not target.sha then
    -- Probe PR-vs-work-item. Async so the hl_flash() highlight works.
    az.probe_is_pr(repo, target.id, function(is_pr)
      vim.schedule(function()
        dispatch(is_pr)
      end)
    end)
  else
    dispatch(nil)
  end
end

--- Gets commit `sha` (via local `git show`) and displays it as a `gitcommit` buffer.
---
--- @param sha string Commit SHA.
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_commit(sha, repo, focus)
  local done = util.progress(('Loading commit %s...'):format(sha))
  az.get_commit(repo, sha, function(patch, err)
    if not patch then
      done('failed')
      return util.msg(('Failed to load commit %s: %s'):format(sha, err or ''), vim.log.levels.ERROR)
    end
    local full_sha = patch:match('^commit%s+(%x+)') or sha
    local buf = state.init_buf('commit', focus, repo, full_sha, { id = full_sha })
    local lines = vim.split(patch, '\n', { plain = true, trimempty = true })
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    util.set_default_keymaps(buf)
    done('success')
  end)
end

--- Navigates to the next/previous PR commit.
--- @param delta integer +1 for next, -1 for previous.
function M.show_next_commit(delta)
  local _, id, repo, commit_idx = resolve_pr()
  local pr_buf = assert(state.get_buf('pr', repo, id, false))
  local pr_data = vim.fn.getbufvar(pr_buf, 'azdo', {}).pr_data
  local commits = pr_data and pr_data.commits
  if not commits or #commits == 0 then
    error('azdo: No commits found; try refresh (R)', 0)
  end
  local idx = commit_idx or (delta > 0 and 0) or (#commits + 1)
  local next_idx = idx + delta
  if next_idx < 1 or next_idx > #commits then
    return util.msg(('No %s commit'):format(delta > 0 and 'next' or 'previous'))
  end
  M.show_commit(commits[next_idx].oid, repo, true)
end

--- Performs the "review PR" action (sets the signed-in user's vote).
function M.review_pr()
  local _, id, repo = resolve_pr()

  local labels = {
    ['approve'] = { gerund = 'Approving', past = 'Approved' },
    ['comment'] = { gerund = 'Commenting on', past = 'Commented on' },
    ['request-changes'] = { gerund = 'Requesting changes on', past = 'Requested changes on' },
  }

  local function do_action(action)
    local L = labels[action]
    local msg = ('%s PR #%s | ZZ to submit (ZQ to abort)'):format(L.gerund, id)
    local content = action == 'approve' and { '👍' } or { '' }
    comments.edit_comment('review', id, content, { { msg, 'Comment' } }, function(input)
      local body = vim.trim(input)
      local done = util.progress(('%s PR #%s…'):format(L.gerund, id))
      az.review_pr(id, repo, action, body, function(ok, stderr)
        done(ok and 'success' or 'failed')
        if ok then
          util.msg(('%s PR #%s'):format(L.past, id))
        else
          util.msg(('Review failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
        end
      end)
    end)
  end

  local actions = { 'approve', 'request-changes', 'comment' }
  local count = vim.v.count
  if count >= 1 and count <= #actions then
    return do_action(actions[count])
  end

  vim.ui.select(actions, { prompt = ('Review PR #%s by:'):format(id) }, function(action)
    if action then
      do_action(action)
    end
  end)
end

--- Refreshes the current `azdo://*` buffer by invoking `:Azdo <bufname>`.
function M.refresh()
  local feat = util.require_b_azdo({ 'feat' })
  if not feat then
    return
  end
  if feat == 'status' then
    return M.show_status(true)
  end
  if feat == 'workitems' then
    return M.show_workitems(true)
  end
  -- Drop cached pr_data on the `/pr/…` buf so `az.get_pr_data` re-fetches.
  local b = vim.b.azdo or {}
  if b.repo and b.id then
    local pr_buf = state.get_buf('pr', b.repo, b.id, false)
    if pr_buf then
      state.set_b_azdo(pr_buf, { pr_data = nil })
    end
  end
  M.select({ args = vim.api.nvim_buf_get_name(0) })
end

--- Performs the "merge PR" (complete) action.
function M.merge_pr()
  local _, id, repo = resolve_pr()

  local function do_merge(choice, subject, body)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    local done = util.progress(('Completing PR #%s (%s)…'):format(id, choice))
    az.merge_pr(id, repo, method, subject, body, admin, function(ok, stderr)
      done(ok and 'success' or 'failed')
      if ok then
        util.msg(('Completed PR #%s'):format(id))
      else
        util.msg(('Complete failed: %s'):format(vim.trim(stderr)), vim.log.levels.ERROR)
      end
    end)
  end

  local function with_choice(choice)
    local method = choice:match('^(%S+)')
    local admin = choice:find('--admin', 1, true) ~= nil
    if method == 'rebase' then
      return do_merge(choice)
    end
    az.get_pr_data(id, repo, nil, function(pr)
      if not pr then
        return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
      end
      vim.schedule(function()
        local subject, body
        if method == 'merge' then
          subject = ('Merge PR #%s: %s'):format(id, pr.title)
          body = pr.body or ''
        elseif method == 'squash' then
          subject = ('%s (#%s)'):format(pr.title, id)
          local cs = pr.commits or {}
          if #cs == 1 and vim.trim(cs[1].messageHeadline) == vim.trim(pr.title) then
            body = cs[1].messageBody
          else
            local parts = {}
            for _, c in ipairs(cs) do
              local entry = ('* %s'):format(c.messageHeadline)
              if c.messageBody ~= '' then
                entry = entry .. '\n\n' .. c.messageBody
              end
              table.insert(parts, entry)
            end
            body = table.concat(parts, '\n\n')
          end
        else
          error(('unknown method: %s'):format(method))
        end
        local text = ('%s\n\n%s'):format(subject, body):gsub('\r', '')
        local content = vim.split(text, '\n', { plain = true })
        local heading = {
          { ('[%s]'):format(choice),                                               admin and 'ErrorMsg' or 'Comment' },
          { ' | First line = subject; rest = body | ZZ to complete (ZQ to abort)', 'Comment' },
        }
        comments.edit_comment('merge', id, content, heading, function(input)
          local subj, b = input:match('^([^\n]*)\n?(.*)$')
          do_merge(choice, subj, vim.trim(b or ''))
        end)
      end)
    end)
  end

  local choices = { 'squash', 'merge', 'rebase', 'squash --admin', 'merge --admin', 'rebase --admin' }
  local count = vim.v.count
  if count >= 1 and count <= #choices then
    return with_choice(choices[count])
  end

  vim.ui.select(choices, { prompt = ('Complete PR #%s by:'):format(id) }, function(choice)
    if choice then
      with_choice(choice)
    end
  end)
end

--- @param focus boolean
--- @param repo? string "org/project/repo"
function M.show_status(focus, repo)
  repo = repo or (vim.b.azdo or {}).repo or resolve_local_repo()
  local buf = state.init_buf('status', focus, nil, 'all', { repo = repo })
  util.set_default_keymaps(buf)
  if not repo then
    util.buf_set_readonly_lines(buf, { 'azdo: could not resolve repo (not an Azure DevOps clone?)' },
      'markdown')
    return
  end
  local done = util.progress('Loading status...')
  az.list_prs(repo, function(prs, err)
    if not prs then
      done('failed')
      util.buf_set_readonly_lines(buf, { ('azdo: failed to list PRs: %s'):format(err or '') },
        'markdown')
      return
    end
    local lines = { ('# %s'):format(repo), '', ('Open PRs (active): %d'):format(#prs), '' }
    for _, p in ipairs(prs) do
      table.insert(lines, ('  #%d  %s%s'):format(p.number, p.isDraft and '(draft) ' or '', p.title))
    end
    table.insert(lines, '')
    local km = config.options.keymaps or {}
    local split_hint = type(km.open_split) == 'string' and km.open_split ~= '' and
        (' | %s to open in a split'):format(km.open_split) or ''
    table.insert(lines, ('<CR> on a #id to open it%s | g? for help'):format(split_hint))
    util.buf_set_readonly_lines(buf, lines, 'markdown')
    done('success')
  end)
end

--- Renders a `  #id  [type/state]  title` line for the dashboard. When
--- `show_assignee`, the assignee is appended as a styled `` `@Name` `` token
--- (markdown inline-code, so it stands out) rather than a plain "— Name" suffix.
--- The caller only sets `show_assignee` when the list spans more than one person,
--- so a single-assignee view (e.g. your own items) isn't cluttered by repetition.
--- The `  #id  [type/state]` prefix that precedes each item's title. When
--- `hide_state` (the list is grouped by state, so the `### heading` already
--- names it), the redundant `/state` is dropped, leaving just `[type]`.
-- Short labels for the long Azure work-item type names, so the type column stays
-- narrow (e.g. "Product Backlog Item" → "PBI"). Matched case-insensitively;
-- anything unlisted falls through to its full name.
local WI_TYPE_SHORT = {
  ['product backlog item'] = 'PBI',
  ['user story'] = 'Story',
  ['feature'] = 'Feat',
  ['epic'] = 'Epic',
  ['bug'] = 'Bug',
  ['task'] = 'Task',
  ['issue'] = 'Issue',
  ['test case'] = 'Test',
}

--- The work-item type, abbreviated when it's one of the long standard names.
--- @return string
local function wi_type_label(wi)
  local t = tostring(wi.type or '')
  return WI_TYPE_SHORT[t:lower()] or t
end

local function wi_prefix(wi, hide_state)
  if hide_state then
    return ('  #%d  [%s]'):format(wi.id, wi_type_label(wi))
  end
  return ('  #%d  [%s/%s]'):format(wi.id, wi_type_label(wi), wi.state)
end

--- Widest `wi_prefix` across one item list, so its titles pad into a single
--- aligned column regardless of varying id / type / state widths. Computed per
--- section (Tagged vs active) so a wider section doesn't bloat the other's pad.
--- @return integer
local function wi_prefix_width(list, hide_state)
  local w = 0
  for _, wi in ipairs(list) do
    w = math.max(w, vim.fn.strdisplaywidth(wi_prefix(wi, hide_state)))
  end
  return w
end

--- @param prefix_w? integer pad the prefix to this width so titles line up
--- @param hide_state? boolean drop the redundant `/state` (state-grouped list)
local function wi_line(wi, show_assignee, prefix_w, hide_state)
  local prefix = wi_prefix(wi, hide_state)
  local pad = prefix_w and (' '):rep(math.max(0, prefix_w - vim.fn.strdisplaywidth(prefix))) or ''
  local s = ('%s%s  %s'):format(prefix, pad, wi.title)
  if show_assignee and wi.assignee and wi.assignee ~= '' then
    s = s .. ('  `@%s`'):format(wi.assignee)
  end
  return s
end

-- Workflow/board order for the 'state' sort and its group headings. Lower =
-- earlier (further left on the Azure board). Matched case-insensitively across
-- the Agile / Scrum / CMMI process templates; an unknown state lands between
-- active work and "done" so custom in-flight states sort sensibly.
local STATE_RANK = {
  ['new'] = 10,
  ['proposed'] = 10,
  ['to do'] = 10,
  ['open'] = 10,
  ['design'] = 15,
  ['approved'] = 20,
  ['committed'] = 30,
  ['active'] = 30,
  ['sprint backlog'] = 30,
  ['in progress'] = 40,
  ['doing'] = 40,
  ['resolved'] = 50,
  ['in review'] = 55,
  ['testing'] = 60,
  ['in test'] = 60,
  ['done'] = 70,
  ['closed'] = 70,
  ['completed'] = 70,
  ['removed'] = 90,
}
local function state_rank(s)
  return STATE_RANK[tostring(s or ''):lower()] or 45
end

local MONTHS =
{ 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October',
  'November', 'December' }

--- "2026-06-27T…" → "June 27, 2026" for date-group subheadings.
local function day_label(iso)
  local y, m, d = tostring(iso or ''):match('^(%d%d%d%d)-(%d%d)-(%d%d)')
  if not y then
    return 'Unknown date'
  end
  return ('%s %d, %s'):format(MONTHS[tonumber(m)] or '?', tonumber(d), tonumber(y))
end

-- Sort fields offered by the `s` keymap, in menu order. Each spec exposes:
--   key(item)   -> comparable sort key (number or lowercased string)
--   desc        -> reverse order (newest / largest first)
--   group(item) -> `###` subheading label, or absent for un-grouped sorts
-- Items are sorted by `key`; same-`key` items break on group label then id, so
-- each group stays contiguous (e.g. 'New' and 'Proposed' share rank 10).
local WI_SORT_ORDER = { 'changed', 'created', 'state', 'type', 'assignee', 'id', 'title' }
local WI_SORTS = {
  changed = {
    label = 'Changed date (newest first)',
    desc = true,
    key = function(i)
      return i.changed or ''
    end,
    group = function(i)
      return day_label(i.changed)
    end,
  },
  created = {
    label = 'Created date (newest first)',
    desc = true,
    key = function(i)
      return i.created or ''
    end,
    group = function(i)
      return day_label(i.created)
    end,
  },
  state = {
    label = 'State (board order)',
    key = function(i)
      return state_rank(i.state)
    end,
    group = function(i)
      return i.state ~= '' and i.state or 'No state'
    end,
  },
  type = {
    label = 'Type (A → Z)',
    key = function(i)
      return tostring(i.type or ''):lower()
    end,
    group = function(i)
      return i.type ~= '' and i.type or 'No type'
    end,
  },
  assignee = {
    label = 'Assignee (A → Z)',
    key = function(i)
      return tostring(i.assignee or ''):lower()
    end,
    group = function(i)
      return i.assignee ~= '' and i.assignee or 'Unassigned'
    end,
  },
  id = {
    label = 'ID (ascending)',
    key = function(i)
      return i.id or 0
    end,
  },
  title = {
    label = 'Title (A → Z)',
    key = function(i)
      return tostring(i.title or ''):lower()
    end,
  },
}

--- Normalises a user-supplied sort name to a `WI_SORTS` key, or nil if unknown.
--- Case-insensitive, tolerates a trailing " date" and a few Azure aliases, so
--- `items = { sort = 'created date' }` (and 'Created', 'ChangedDate', …) work.
--- @param s any
--- @return string?
local function resolve_sort_name(s)
  if type(s) ~= 'string' then
    return nil
  end
  local key = s:lower():gsub('%s*date%s*$', ''):gsub('%s+', '')
  key = ({ changeddate = 'changed', createddate = 'created', workitemtype = 'type', name = 'title' })
      [key] or key
  return WI_SORTS[key] and key or nil
end

--- Sorts `items` in place by the given sort name (a `WI_SORTS` key). Unknown
--- names leave the list untouched.
--- @param items table[]
--- @param name string
local function sort_items(items, name)
  local spec = WI_SORTS[name]
  if not spec then
    return
  end
  table.sort(items, function(a, b)
    local ka, kb = spec.key(a), spec.key(b)
    if ka ~= kb then
      if spec.desc then
        return ka > kb
      end
      return ka < kb
    end
    if spec.group then -- keep same-group items contiguous before the id tiebreak
      local ga, gb = spec.group(a), spec.group(b)
      if ga ~= gb then
        return ga < gb
      end
    end
    return a.id < b.id
  end)
end

-- Last-fetched dashboard data per buffer, so the `s`/`cc` keymaps can re-sort,
-- re-group, or reflect a state change without another round-trip. Keyed by bufnr.
local wi_cache = {}

--- @class azdo.WiView
--- @field sort string a `WI_SORTS` key
--- @field group boolean group under `###` subheadings
--- @field show_hidden boolean reveal items in `items.hide_states`
--- @field assignee 'me'|'all'|string|string[] who the dashboard lists

--- The dashboard's current view — per-buffer overrides (set by the `s` /
--- `gh` keymaps, surviving refresh via init_buf's merge) over the configured
--- defaults.
--- @param buf integer
--- @return azdo.WiView
local function current_view(buf)
  local b = vim.b[buf].azdo or {}
  local items = config.options.items or {}
  local sort = resolve_sort_name(b.sort) or resolve_sort_name(items.sort) or 'changed'
  local group = b.group
  if group == nil then
    group = items.group ~= false
  end
  local assignee = b.assignee
  if assignee == nil then
    assignee = items.assignee or 'me'
  end
  return { sort = sort, group = group, show_hidden = b.show_hidden == true, assignee = assignee }
end

--- Set of states to hide from the active list (from `items.hide_states`),
--- lowercased for case-insensitive matching. Empty when nothing is configured.
--- @return table<string, true>
local function hidden_states_set()
  local set = {}
  for _, s in ipairs((config.options.items or {}).hide_states or {}) do
    if type(s) == 'string' and s ~= '' then
      set[s:lower()] = true
    end
  end
  return set
end

--- Appends `items` to `lines`, inserting a `### <label>` subheading whenever the
--- group label changes (when `grouping` and the sort defines groups).
local function append_items(lines, items, spec, grouping, show_assignee, prefix_w, hide_state)
  local cur
  for _, wi in ipairs(items) do
    if grouping and spec and spec.group then
      local g = spec.group(wi)
      if g ~= cur then
        lines[#lines + 1] = ('### %s'):format(g)
        cur = g
      end
    end
    lines[#lines + 1] = wi_line(wi, show_assignee, prefix_w, hide_state)
  end
end

-- Per-buffer `### group` fold levels, indexed by line number, consumed by the
-- window foldexpr (`M.fold_expr`). Rebuilt on every render.
M._fold_levels = {}

-- Per-buffer line numbers of the first item line of each group whose label is
-- in `items.fold` (the "start this state folded" list). Applied by setup_folds.
M._fold_closed = {}

--- The set of group labels to start folded, lowercased, when `items.fold` is a
--- list; nil when it's a boolean (handled wholesale by setup_folds).
--- @return table<string, true>?
local function fold_label_set()
  local fold = (config.options.items or {}).fold
  if type(fold) ~= 'table' then
    return nil
  end
  local set = {}
  for _, s in ipairs(fold) do
    if type(s) == 'string' and s ~= '' then
      set[s:lower()] = true
    end
  end
  return set
end

--- Computes the foldexpr level for each rendered line. The `### group` heading
--- itself stays at level 0 (always visible, so render-markdown & co. render it
--- normally even when its items are collapsed); the group's item lines are
--- level 1 and form the fold. Top headings, the Tagged shortlist, blanks, and
--- the hint stay at level 0. Also collects the first item line of each group
--- whose label is in `foldset` (the start-folded groups).
--- @param lines string[]
--- @param grouping boolean
--- @param foldset table<string, true>? group labels to start folded
--- @return table<integer, string> levels, integer[] closed_first_item_lines
local function compute_folds(lines, grouping, foldset)
  local fl, closed = {}, {}
  local label, first = nil, false -- current group label, and "next item is its first"
  for i, l in ipairs(lines) do
    if not grouping then
      fl[i] = '0'
    elseif l:sub(1, 4) == '### ' then
      fl[i], label, first = '0', l:sub(5), true -- heading stays outside the fold
    elseif l == '' or l:sub(1, 3) == '## ' or l:sub(1, 2) == '# ' then
      fl[i], label = '0', nil
    elseif label then
      fl[i] = '1' -- item line in a group → folds under its heading
      if first and foldset and foldset[label:lower()] then
        closed[#closed + 1] = i
      end
      first = false
    else
      fl[i] = '0' -- a Tagged item (no group heading)
    end
  end
  return fl, closed
end

--- foldexpr for the dashboard window (set by `setup_folds`). Reads the level
--- precomputed for the current line; `0` (no fold) for anything unmapped.
function M.fold_expr()
  local fl = M._fold_levels[vim.api.nvim_get_current_buf()]
  return (fl and fl[vim.v.lnum]) or '0'
end

--- foldtext for a collapsed group. The fold covers only the item lines (the
--- `### heading` stays visible above it, so markdown plugins render it normally
--- and can't mangle the collapsed line). Shows the item count, aligned under the
--- items. (`foldstart - 1` is the heading; kept here only as a fallback label.)
function M.fold_text()
  local n = vim.v.foldend - vim.v.foldstart + 1
  return ('    ▸ %d item%s …'):format(n, n == 1 and '' or 's')
end

-- Buffers whose fold window-options have had their default level applied once,
-- so a later sort/refresh doesn't clobber the user's manual za/zR/zM state.
local fold_inited = {}

--- Points every window showing `buf` at the dashboard foldexpr/foldtext. When
--- `set_level`, also applies the configured default fold state — done once per
--- buffer so re-renders don't reset it. `items.fold`: true → all groups closed;
--- a list → only those groups (M._fold_closed[buf]) closed; else all open.
local function setup_folds(buf, set_level)
  local fold = (config.options.items or {}).fold
  local closed = M._fold_closed[buf] or {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local function set(opt, val)
      vim.api.nvim_set_option_value(opt, val, { win = win })
    end
    set('foldmethod', 'expr')
    set('foldexpr', "v:lua.require'azdo.pr'.fold_expr()")
    set('foldtext', "v:lua.require'azdo.pr'.fold_text()")
    set('foldenable', true)
    if set_level then
      if fold == true then
        set('foldlevel', 0)  -- all groups closed
      else
        set('foldlevel', 99) -- all open, then close the start-folded groups (if any)
        if #closed > 0 then
          vim.api.nvim_win_call(win, function()
            for _, ln in ipairs(closed) do
              pcall(vim.cmd, ('%dfoldclose'):format(ln))
            end
          end)
        end
      end
    end
  end
end

--- A short human label for an assignee filter, for the dashboard heading:
--- 'all' → "everyone", nil/'me' → "you", one name → that name, a list → the
--- first name plus "+N".
--- @param assignee 'me'|'all'|string|string[]
--- @return string
local function assignee_label(assignee)
  if assignee == 'all' then
    return 'everyone'
  end
  if assignee == nil or assignee == 'me' then
    return 'you'
  end
  local people = type(assignee) == 'table' and assignee or { assignee }
  if #people <= 1 then
    return people[1] or 'you'
  end
  return ('%s +%d'):format(people[1], #people - 1)
end

--- Counts the distinct (non-empty) assignees across the given item lists — used
--- to decide whether to surface the per-item assignee token (only worth showing
--- when the list spans more than one person).
--- @return integer
local function distinct_assignees(...)
  local seen, n = {}, 0
  for _, list in ipairs({ ... }) do
    for _, wi in ipairs(list) do
      local a = wi.assignee
      if a and a ~= '' and not seen[a] then
        seen[a] = true
        n = n + 1
      end
    end
  end
  return n
end

--- Renders the work-items dashboard into `buf` per `view` (assignee filter /
--- sort / grouping / hidden-state visibility). When grouping and the sort
--- defines groups, items are split under `###` subheadings (foldable);
--- `items.hide_states` are filtered out unless `view.show_hidden`, with the
--- dropped count shown.
--- @param buf integer
--- @param key string project label (heading)
--- @param tagged_items table[]
--- @param items table[]
--- @param view azdo.WiView
local function render_workitems(buf, key, tagged_items, items, view)
  local spec = WI_SORTS[view.sort]
  local grouping = view.group and spec ~= nil and spec.group ~= nil
  sort_items(tagged_items, view.sort)
  sort_items(items, view.sort)

  -- Filter hidden states out of the active list (Tagged pins always show).
  local hide = hidden_states_set()
  local hidden_n = 0
  if not view.show_hidden and next(hide) then
    local shown = {}
    for _, wi in ipairs(items) do
      if hide[tostring(wi.state or ''):lower()] then
        hidden_n = hidden_n + 1
      else
        shown[#shown + 1] = wi
      end
    end
    items = shown
  end

  local who = view.assignee
  local mine = who == nil or who == 'me'
  -- Show the per-item assignee token once the list isn't a single person's.
  local show_assignee = distinct_assignees(items, tagged_items) > 1

  -- When grouped by state, each `### heading` already names the state, so the
  -- active list drops the redundant `/state` from its item prefixes (the Tagged
  -- shortlist isn't grouped, so it keeps showing state).
  local hide_state = grouping and view.sort == 'state'

  -- Align titles into one column per section. The Tagged shortlist always shows
  -- state, so it's padded on its own width; the active list uses its own (often
  -- narrower) width so a wide Tagged prefix doesn't waste space below it.
  local tagged_w = wi_prefix_width(tagged_items, false)
  local prefix_w = wi_prefix_width(items, hide_state)

  -- Short sort descriptor: the spec label minus any "(parenthetical)" jargon,
  -- lowercased (e.g. "State (board order)" → "state"), since a grouped view
  -- already shows the ordering visually.
  local sort_label = ((spec or {}).label or view.sort):gsub('%s*%b()', ''):lower()
  -- The title is just the project; the summary line below names who and how many.
  local lines = { ('# %s'):format(key), '' }
  if #tagged_items > 0 then
    lines[#lines + 1] = ('##  Tagged (%d)'):format(#tagged_items)
    for _, wi in ipairs(tagged_items) do -- the pinned shortlist is sorted but not sub-grouped
      lines[#lines + 1] = wi_line(wi, show_assignee, tagged_w)
    end
    lines[#lines + 1] = ''
  end
  -- Summary: "<n> active[ · <who>] · by <sort>" (mine drops the who token).
  local head = ('## %d active'):format(#items)
  if not mine then
    head = head .. (' · %s'):format(assignee_label(who))
  end
  head = head .. (grouping and (' · by %s'):format(sort_label) or (' · sorted by %s'):format(sort_label))
  if hidden_n > 0 then
    head = head .. ((' · %d hidden'):format(hidden_n))
  elseif view.show_hidden and next(hide) then
    head = head .. ' · showing all'
  end
  lines[#lines + 1] = head
  append_items(lines, items, spec, grouping, show_assignee, prefix_w, hide_state)
  lines[#lines + 1] = ''
  local km = config.options.keymaps or {}
  local function hint(action, txt)
    return type(km[action]) == 'string' and km[action] ~= '' and (' · %s %s'):format(km[action], txt) or
        ''
  end
  local hide_hint = next(hide) and hint('toggle_hidden', view.show_hidden and 'hide' or 'show all') or
      ''
  lines[#lines + 1] = ('<CR> open%s · t tag%s%s%s%s · g? help'):format(
    hint('open_split', 'split'),
    hint('sort', 'sort'),
    hint('assignee', 'assignee'),
    hint('set_state', 'state'),
    hide_hint
  )

  M._fold_levels[buf], M._fold_closed[buf] = compute_folds(lines, grouping, fold_label_set())
  util.buf_set_readonly_lines(buf, lines, 'markdown')
end

--- Re-renders the dashboard in place from cached data at the current view (no
--- round-trip); falls back to a refetch if the cache is somehow gone.
--- @param buf integer
local function rerender_dashboard(buf)
  local cached = wi_cache[buf]
  if cached then
    render_workitems(buf, cached.key, cached.tagged, cached.items, current_view(buf))
  else
    M.show_workitems(true)
  end
end

--- Dashboard of work items assigned to you (active, newest-changed first), with a
--- "Tagged" section at the top for items you've pinned with `t` (see `tag_toggle`).
--- Mirrors `show_status`: a markdown list buffer whose `#id` lines open via `<CR>`.
--- @param focus boolean
--- @param repo? string "org/project/repo"
function M.show_workitems(focus, repo)
  local label
  if repo then
    label = project_label(repo)
  else
    repo, label = resolve_project_repo()
  end
  local buf = state.init_buf('workitems', focus, nil, 'all', { repo = repo })
  util.set_default_keymaps(buf)
  if not repo then
    util.buf_set_readonly_lines(buf, {
      'azdo: no project to query.',
      'Set `project = "org/project"` in setup() (or just "project" on-prem),',
      'or run :Azdo items from inside an Azure DevOps clone.',
    }, 'markdown')
    return
  end
  local key = label or repo
  local done = util.progress('Loading work items...')

  -- Current view: whatever the dashboard was last set to (survives refresh,
  -- since init_buf merges b:azdo), else the configured defaults.
  local view = current_view(buf)
  state.set_b_azdo(buf,
    { sort = view.sort, group = view.group, show_hidden = view.show_hidden, assignee = view.assignee })

  -- Fetch the (possibly closed / others') tagged items by id, then the active list.
  local function then_active(tagged_items)
    az.list_workitems(repo, view.assignee, function(items, err)
      if not items then
        done('failed')
        util.buf_set_readonly_lines(buf,
          { ('azdo: failed to list work items: %s'):format(err or '') }, 'markdown')
        return
      end
      wi_cache[buf] = { key = key, tagged = tagged_items, items = items }
      render_workitems(buf, key, tagged_items, items, view)
      setup_folds(buf, not fold_inited[buf]) -- default fold state applied once
      fold_inited[buf] = true
      done('success')
    end)
  end

  local tagged_ids = tags.list(key)
  if #tagged_ids == 0 then
    then_active({})
  else
    az.get_workitems(repo, tagged_ids, function(t_items)
      local by_id = {}
      for _, wi in ipairs(t_items or {}) do
        by_id[wi.id] = wi
      end
      local ordered = {} -- preserve tag order; drop any that no longer resolve
      for _, id in ipairs(tagged_ids) do
        if by_id[id] then
          ordered[#ordered + 1] = by_id[id]
        end
      end
      then_active(ordered)
    end)
  end
end

-- Sentinel choice (vs. a WI_SORTS key) for the grouping toggle in the picker.
local SORT_TOGGLE_GROUP = '\0toggle-group'

--- Prompts (via `vim.ui.select`, so it flows through Telescope / fzf-lua / snacks
--- / the default picker) for a field to sort the work-items dashboard by — or to
--- toggle grouping — then re-renders in place from the cached data (no extra
--- round-trip). Only valid in a `workitems` buffer. The choice sticks for
--- refreshes; set defaults with `items = { sort = …, group = … }`.
function M.sort_workitems()
  local buf = vim.api.nvim_get_current_buf()
  if (vim.b.azdo or {}).feat ~= 'workitems' then
    return util.msg('azdo: sort is only available in the work-items dashboard', vim.log.levels.WARN)
  end
  local cur = current_view(buf)
  local choices = vim.list_extend({}, WI_SORT_ORDER)
  choices[#choices + 1] = SORT_TOGGLE_GROUP

  vim.ui.select(choices, {
    prompt = 'Sort work items by:',
    format_item = function(name)
      if name == SORT_TOGGLE_GROUP then
        return ('  Grouping: %s (toggle)'):format(cur.group and 'on' or 'off')
      end
      local groups = WI_SORTS[name].group and ' ⊞' or ''
      return ('%s %s%s'):format(name == cur.sort and '✓' or ' ', WI_SORTS[name].label, groups)
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice == SORT_TOGGLE_GROUP then
      state.set_b_azdo(buf, { group = not cur.group })
    else
      state.set_b_azdo(buf, { sort = choice })
    end
    rerender_dashboard(buf)
  end)
end

--- Toggles whether the dashboard's `items.hide_states` (e.g. Done) are shown.
--- The choice sticks across refreshes; no-op with a hint when nothing is
--- configured to hide. Only valid in a `workitems` buffer.
function M.toggle_hidden()
  local buf = vim.api.nvim_get_current_buf()
  if (vim.b.azdo or {}).feat ~= 'workitems' then
    return util.msg('azdo: only available in the work-items dashboard', vim.log.levels.WARN)
  end
  if not next(hidden_states_set()) then
    return util.msg("azdo: nothing to toggle — set items.hide_states, e.g. { 'Done' }")
  end
  local showing = current_view(buf).show_hidden
  state.set_b_azdo(buf, { show_hidden = not showing })
  rerender_dashboard(buf)
  util.msg(showing and 'azdo: hiding configured states' or 'azdo: showing all states')
end

--- Filters the dashboard by assignee. Pops a multi-select (a markdown float)
--- of "All assignees", "Me", and the project's active assignees, pre-checked to
--- the current filter. The choice sticks across refreshes (stored in `b:azdo`),
--- and — unlike sort/group, which re-slice cached data — triggers a refetch,
--- since the assignee is part of the WIQL query. Only valid in a `workitems`
--- buffer.
function M.filter_assignee()
  local buf = vim.api.nvim_get_current_buf()
  local b = vim.b.azdo or {}
  if b.feat ~= 'workitems' then
    return util.msg('azdo: assignee filter is only available in the work-items dashboard',
      vim.log.levels.WARN)
  end
  local repo = b.repo
  if not repo then
    return util.msg('azdo: no project context here', vim.log.levels.WARN)
  end

  local cur = current_view(buf).assignee
  local me = az.get_user()

  -- Current selection, as lookups, so we can pre-check the popup.
  local cur_all = cur == 'all'
  local cur_me = cur == nil or cur == 'me'
  local cur_set, cur_list = {}, {}
  if type(cur) == 'table' then
    cur_list = cur
  elseif type(cur) == 'string' and not cur_all and not cur_me then
    cur_list = { cur }
  end
  for _, n in ipairs(cur_list) do
    cur_set[n] = true
  end

  -- Builds the popup from a roster of names, pre-checked to the current filter,
  -- and applies the choice (refetching, since the assignee is part of the query).
  local function show_popup(names)
    local entries = {} -- parallel to the popup's items: { value }
    local items, seen = {}, {}
    local function add(label, value, opts)
      items[#items + 1] = {
        label = label,
        checked = (opts or {}).checked,
        exclusive = (opts or {})
            .exclusive
      }
      entries[#entries + 1] = { value = value }
      seen[value] = true
    end

    add('All assignees', 'all', { exclusive = true, checked = cur_all })
    if me then
      add(('Me (%s)'):format(me), me, { checked = cur_me or cur_set[me] or false })
    end
    for _, n in ipairs(names) do
      if not seen[n] then
        add(n, n, { checked = cur_set[n] or false })
      end
    end
    -- Surface any currently-filtered names not in the roster, so they show (and
    -- stay) checked rather than silently vanishing on the next apply.
    for _, n in ipairs(cur_list) do
      if not seen[n] then
        add(n, n, { checked = true })
      end
    end

    util.multiselect({ title = 'Filter work items by assignee', items = items }, function(sel)
      if not sel then
        return
      end
      local chose_all, people = false, {}
      for _, idx in ipairs(sel) do
        local v = entries[idx].value
        if v == 'all' then
          chose_all = true
        else
          people[#people + 1] = v
        end
      end

      -- Normalise to the smallest equivalent filter: 'all', 'me' (uses @Me, so
      -- it's robust to display-name quirks), or the explicit people list.
      local newval
      if chose_all then
        newval = 'all'
      elseif #people == 0 then
        newval = 'me'
      elseif #people == 1 and people[1] == me then
        newval = 'me'
      else
        newval = people
      end

      state.set_b_azdo(buf, { assignee = newval })
      M.show_workitems(true, repo) -- refetch — the assignee is part of the query
    end)
  end

  -- Prefer the configured roster (instant, no query). Only fall back to deriving
  -- it from the project's active items when none is configured.
  local roster = (config.options.items or {}).assignees
  if type(roster) == 'table' and #roster > 0 then
    return show_popup(roster)
  end

  local done = util.progress('Loading assignees...')
  az.list_assignees(repo, function(names, err)
    if not names then
      done('failed')
      return util.msg(('azdo: failed to load assignees: %s'):format(err or ''), vim.log.levels.ERROR)
    end
    done('success')
    show_popup(names)
  end)
end

--- Sets a work item's State via a picker of the states valid for its type (so a
--- Bug offers different states than a PBI). In the dashboard, acts on the `#id`
--- under the cursor; in a work-item view, on that item. Mapped to `cc` by default
--- (where commenting has no meaning), mirroring the Azure board's drag-between-
--- columns. Reflects the change in place — a later `R` pulls fresh.
function M.set_state()
  local buf = vim.api.nvim_get_current_buf()
  local b = vim.b.azdo or {}
  local repo = b.repo
  if not repo then
    return util.msg('azdo: no project context here', vim.log.levels.WARN)
  end
  local id, wtype, current
  if b.feat == 'workitems' then
    id = tonumber(vim.api.nvim_get_current_line():match('#(%d+)'))
    if not id then
      return util.msg('azdo: put the cursor on a #id line to set its state')
    end
    local cached = wi_cache[buf]
    for _, list in ipairs({ cached and cached.items or {}, cached and cached.tagged or {} }) do
      for _, wi in ipairs(list) do
        if wi.id == id then
          wtype, current = wi.type, wi.state
          break
        end
      end
      if wtype then
        break
      end
    end
  elseif b.feat == 'issue' then
    id = tonumber(b.id)
  else
    return util.msg('azdo: set-state is only available on work items', vim.log.levels.WARN)
  end
  if not id then
    return util.msg('azdo: no work item here', vim.log.levels.WARN)
  end

  local function pick(states, cur)
    if not states or #states == 0 then
      return util.msg('azdo: could not load states for this item', vim.log.levels.ERROR)
    end
    local names = {}
    for _, s in ipairs(states) do
      names[#names + 1] = s.name
    end
    vim.ui.select(names, {
      prompt = ('Set state for #%d:'):format(id),
      format_item = function(n)
        return ('%s %s'):format(n == cur and '✓' or ' ', n)
      end,
    }, function(choice)
      if not choice or choice == cur then
        return
      end
      local done = util.progress(('Updating #%d → %s...'):format(id, choice))
      az.update_workitem(repo, id, { ['System.State'] = choice }, function(ok, stderr)
        if not ok then
          done('failed')
          return util.msg(('azdo: failed to set state: %s'):format(vim.trim(stderr or '')),
            vim.log.levels.ERROR)
        end
        done('success')
        util.msg(('azdo: #%d → %s'):format(id, choice))
        if b.feat == 'workitems' then
          local cached = wi_cache[buf]
          if cached then -- reflect the new state without a refetch
            for _, list in ipairs({ cached.items, cached.tagged }) do
              for _, wi in ipairs(list) do
                if wi.id == id then
                  wi.state = choice
                end
              end
            end
            rerender_dashboard(buf)
          end
        else
          M.refresh()
        end
      end)
    end)
  end

  if wtype then
    az.get_workitem_states(repo, wtype, function(states)
      pick(states, current)
    end)
  else -- issue view, or a cache miss: fetch the item to learn its type first.
    az.get_workitems(repo, { id }, function(its)
      local wi = (its or {})[1]
      if not wi then
        return util.msg('azdo: work item not found', vim.log.levels.ERROR)
      end
      az.get_workitem_states(repo, wi.type, function(states)
        pick(states, wi.state)
      end)
    end)
  end
end

--- Tags/untags a work item (local pin). In the dashboard, acts on the `#id` under the
--- cursor; in a work-item view, acts on that item. Persisted per-project via `azdo.tags`.
function M.tag_toggle()
  local b = vim.b.azdo or {}
  local repo = b.repo
  if not repo then
    return util.msg('azdo: no project context here', vim.log.levels.WARN)
  end
  local key = project_label(repo) or repo
  local id
  if b.feat == 'workitems' then
    id = tonumber(vim.api.nvim_get_current_line():match('#(%d+)'))
    if not id then
      return util.msg('azdo: put the cursor on a #id line to tag it')
    end
  else
    id = tonumber(b.id)
  end
  if not id then
    return util.msg('azdo: no work item to tag here', vim.log.levels.WARN)
  end
  local now = tags.toggle(key, id)
  util.msg(('azdo: #%d %s'):format(id, now and 'tagged ★' or 'untagged'))
  if b.feat == 'workitems' then
    M.show_workitems(true) -- refresh so the Tagged section updates
  end
end

--- Converts a work-item rich-text field (HTML) to markdown lines for display.
--- Best-effort: headings, bold/italic, inline code, links, and lists become their
--- markdown equivalents; everything else is stripped. Order matters — block-level
--- newlines first, then inline marks, then drop leftover tags, then decode entities.
--- @param html string?
--- @return string[]
local function html_to_markdown(html)
  if type(html) ~= 'string' or html == '' then
    return {}
  end
  local s = html:gsub('\r\n?', '\n')
  -- Block boundaries -> newlines.
  s = s:gsub('<%s*[bB][rR]%s*/?%s*>', '\n')
  s = s:gsub('<%s*[hH][rR]%s*/?%s*>', '\n\n---\n\n')
  for n = 1, 6 do
    s = s:gsub(('<%%s*[hH]%d[^>]*>'):format(n), ('\n\n%s '):format(('#'):rep(n + 2))) -- nest under our "## <section>"
    s = s:gsub(('</%%s*[hH]%d%%s*>'):format(n), '\n\n')
  end
  s = s:gsub('<%s*[lL][iI][^>]*>', '\n- ') -- list item -> markdown bullet (tight list)
  s = s:gsub('</?%s*[pP][^>]*>', '\n\n')   -- paragraph boundary
  s = s:gsub('</?%s*[dD][iI][vV][^>]*>', '\n')
  -- Inline marks -> markdown.
  s = s:gsub('<[aA][^>]-href="([^"]+)"[^>]*>(.-)</[aA]>', '[%2](%1)')
  s = s:gsub('</?%s*[sS][tT][rR][oO][nN][gG]%s*>', '**')
  s = s:gsub('</?%s*[bB]%s*>', '**')
  s = s:gsub('</?%s*[eE][mM]%s*>', '*')
  s = s:gsub('</?%s*[iI]%s*>', '*')
  s = s:gsub('</?%s*[cC][oO][dD][eE]%s*>', '`')
  s = s:gsub('<[^>]*>', '') -- drop remaining tags
  -- Decode entities (&amp; last, so "&amp;lt;" stays literal "&lt;").
  s = s:gsub('&nbsp;', ' '):gsub('&#160;', ' ')
  s = s:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&#39;', "'"):gsub('&amp;', '&')
  local out = {}
  for _, l in ipairs(vim.split(s, '\n', { plain = true })) do
    l = l:gsub('%s+$', '')
    -- Collapse runs of blank lines into one.
    if not (l == '' and (#out == 0 or out[#out] == '')) then
      out[#out + 1] = l
    end
  end
  while #out > 0 and out[#out] == '' do
    table.remove(out, #out)
  end
  return out
end

--- The editable sections for a work-item type (falls back to "default"). The
--- section catalog lives in |azdo-config| under `workitem_sections`; each entry
--- is `{ title, field }` where `field` is the Azure reference name.
--- @param wtype string
--- @return {[1]:string, [2]:string}[]
local function sections_for(wtype)
  local cfg = config.options.workitem_sections or {}
  return cfg[wtype] or cfg.default or {}
end

--- Converts markdown (the editable section body) back to the lenient HTML Azure stores.
--- Inverse of `html_to_markdown`, best-effort: paragraphs -> <div>, `- ` -> <ul><li>,
--- and inline **bold** / *italic* / `code` / [text](url). Plain enough that Azure's
--- editor re-opens it cleanly.
--- @param md string
--- @return string
local function markdown_to_html(md)
  local function inline(s)
    s = s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
    s = s:gsub('%[([^%]]*)%]%(([^%)]*)%)', '<a href="%2">%1</a>')
    s = s:gsub('%*%*([^*]+)%*%*', '<b>%1</b>')
    s = s:gsub('%*([^*]+)%*', '<i>%1</i>')
    s = s:gsub('`([^`]+)`', '<code>%1</code>')
    return s
  end
  local html = {}
  local in_list = false
  local function close_list()
    if in_list then
      html[#html + 1] = '</ul>'
      in_list = false
    end
  end
  for _, line in ipairs(vim.split(md or '', '\n', { plain = true })) do
    local item = line:match('^%s*[-*]%s+(.*)$')
    if item then
      if not in_list then
        html[#html + 1] = '<ul>'
        in_list = true
      end
      html[#html + 1] = ('<li>%s</li>'):format(inline(item))
    elseif vim.trim(line) == '' then
      close_list()
      html[#html + 1] = '<div><br></div>'
    else
      close_list()
      html[#html + 1] = ('<div>%s</div>'):format(inline(line))
    end
  end
  close_list()
  return table.concat(html)
end

--- Shows a work-item ("issue") via the REST API (`get_workitem`), rendered as markdown.
--- Uses the same auth/base-url path as the rest of the plugin (PAT or `az login`,
--- on-prem `azdo_base_url`) — no dependency on the `az boards` CLI.
--- @param id integer
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_issue(id, repo, focus)
  local buf = state.init_buf('issue', focus, repo, id)
  util.set_default_keymaps(buf)
  util.map_default(buf, 'n', 't', '<Plug>(azdo-tag-toggle)', 'Tag/untag this work item')
  local done = util.progress(('Loading work item #%d...'):format(id))
  az.get_workitem(repo, id, function(wi, err)
    if not wi or not wi.fields then
      done('failed')
      util.buf_set_readonly_lines(buf,
        { ('azdo: failed to load work item #%d: %s'):format(id, err or '') }, 'markdown')
      return
    end
    local fld = wi.fields
    local function person(p)
      return (type(p) == 'table' and (p.displayName or p.uniqueName)) or p or 'unassigned'
    end
    local tagged = tags.is_tagged(project_label(repo) or repo, id)
    local L = {}
    L[#L + 1] = ('# %s#%d — %s'):format(tagged and '★ ' or '', id, fld['System.Title'] or '')
    L[#L + 1] = ''
    L[#L + 1] = ('- **Type:** %s'):format(fld['System.WorkItemType'] or 'Work Item')
    L[#L + 1] = ('- **State:** %s'):format(fld['System.State'] or '?')
    L[#L + 1] = ('- **Assigned:** %s'):format(person(fld['System.AssignedTo']))
    if fld['Microsoft.VSTS.Common.Priority'] then
      L[#L + 1] = ('- **Priority:** %s'):format(fld['Microsoft.VSTS.Common.Priority'])
    end
    if fld['System.IterationPath'] then
      L[#L + 1] = ('- **Iteration:** %s'):format(fld['System.IterationPath'])
    end
    if type(fld['System.Tags']) == 'string' and fld['System.Tags'] ~= '' then
      L[#L + 1] = ('- **Tags:** %s'):format(fld['System.Tags'])
    end
    L[#L + 1] = ('- **Created:** %s · **Changed:** %s'):format(
      (fld['System.CreatedDate'] or ''):sub(1, 10),
      (fld['System.ChangedDate'] or ''):sub(1, 10)
    )
    L[#L + 1] = ''
    -- Record each section's header line so `c:` can edit the section at the cursor.
    -- The title (line 1) is a pseudo-section so `c:` in the header area edits it.
    local secmeta = { { line = 1, title = 'Title', field = 'System.Title', is_title = true } }
    for _, sec in ipairs(sections_for(fld['System.WorkItemType'] or '')) do
      L[#L + 1] = '## ' .. sec[1]
      secmeta[#secmeta + 1] = { line = #L, title = sec[1], field = sec[2] }
      L[#L + 1] = ''
      local body = html_to_markdown(fld[sec[2]])
      if #body > 0 then
        vim.list_extend(L, body)
      else
        L[#L + 1] = '_(empty)_'
      end
      L[#L + 1] = ''
    end
    L[#L + 1] = '---'
    L[#L + 1] = '_c: edit section · t tag/untag · gw open in browser · g? help_'
    util.buf_set_readonly_lines(buf, L, 'markdown')
    state.set_b_azdo(buf, { wi_sections = secmeta })
    done('success')
  end)
end

--- Edits the work-item section at the cursor, in its own editable buffer. The
--- read-only view records section line ranges in `b:azdo.wi_sections`; this picks
--- the section whose `## ` header is at/above the cursor (or the title). Bound to
--- `c:` (|<Plug>(azdo-edit)|) from a work-item view.
--- @param id integer
--- @param repo string "org/project/repo"
function M.edit_workitem(id, repo)
  local secs = (vim.b.azdo or {}).wi_sections
  local chosen
  if secs then
    local cur = vim.fn.line('.')
    for _, s in ipairs(secs) do
      if s.line <= cur then
        chosen = s
      else
        break
      end
    end
  end
  if not chosen then
    return util.msg('azdo: put the cursor in a section (## …) then c: to edit it',
      vim.log.levels.WARN)
  end
  M.edit_workitem_field(id, repo, chosen.field, chosen.title, chosen.is_title)
end

--- Opens an editable (multi-line) buffer for a single work-item field, prefilled with
--- its current value as markdown. `ZZ` saves (markdown -> HTML, plain text for the
--- title), `ZQ` aborts — same flow as comment/PR compose. |azdo-confirm|
--- @param id integer
--- @param repo string "org/project/repo"
--- @param field string Azure field reference name
--- @param title string Human-facing section name
--- @param is_title? boolean Title field (plain text, single line)
function M.edit_workitem_field(id, repo, field, title, is_title)
  local done = util.progress(('Loading %s...'):format(title))
  az.get_workitem(repo, id, function(wi, err)
    if not wi or not wi.fields then
      done('failed')
      return util.msg(('azdo: failed to load work item #%d: %s'):format(id, err or ''),
        vim.log.levels.ERROR)
    end
    done('success')
    local fld = wi.fields
    local wtype = fld['System.WorkItemType'] or ''
    local content, baseline
    if is_title then
      baseline = fld['System.Title'] or ''
      content = { baseline }
    else
      content = html_to_markdown(fld[field])
      if #content == 0 then
        content = { '' }
      end
      baseline = vim.trim(table.concat(content, '\n'))
    end

    local heading = { { ('Edit %s — #%d (%s) | ZZ save, ZQ abort'):format(title, id, wtype), 'Comment' } }
    vim.schedule(function()
      comments.edit_comment('edit', id, content, heading, function(input)
        local value
        if is_title then
          value = vim.trim((input:gsub('\n.*$', ''))) -- title is single-line, plain text
        else
          value = vim.trim(input)
        end
        if value == vim.trim(baseline) then
          return util.msg('azdo: no changes to save')
        end
        local payload = is_title and value or markdown_to_html(value)
        local progress = util.new_progress_report(('Updating %s...'):format(title), 0)
        progress('running')
        az.update_workitem(repo, id, { [field] = payload }, function(ok, stderr)
          if ok then
            progress('success', nil, ('#%d %s updated.'):format(id, title))
            if state.get_buf('issue', repo, id, false) then
              M.show_issue(id, repo, false) -- refresh the read-only view if open
            end
          else
            progress('failed', nil, ('Failed: %s'):format(vim.trim(stderr or '')))
          end
        end)
      end)
    end)
  end)
end

--- Renders the PR overview (metadata + description + commits + general discussion) as buffer lines.
--- @param pr PullRequest
--- @return string[]
local function render_overview(pr)
  local function vote_str(v)
    return (v == 10 and '✓approved')
        or (v == 5 and '✓w/suggestions')
        or (v == -5 and '⏳waiting')
        or (v == -10 and '✗rejected')
        or 'no vote'
  end
  local L = {}
  table.insert(L, ('#%s  %s'):format(pr.number, pr.title or ''))
  table.insert(
    L,
    ('%s  [%s]%s  %s → %s'):format(
      (pr.author or {}).login or '?',
      pr.status or '?',
      pr.isDraft and ' (draft)' or '',
      pr.headRefName or '?',
      pr.baseRefName or '?'
    )
  )
  table.insert(L, ('%s · %s'):format(pr.url or '', (pr.createdAt or ''):sub(1, 10)))
  if #(pr.reviews or {}) > 0 then
    local rs = {}
    for _, r in ipairs(pr.reviews) do
      table.insert(rs, ('%s (%s)'):format(r.login or '?', vote_str(r.vote or 0)))
    end
    table.insert(L, 'Reviewers: ' .. table.concat(rs, ', '))
  end
  if #(pr.labels or {}) > 0 then
    local ls = {}
    for _, l in ipairs(pr.labels) do
      table.insert(ls, l.name or l)
    end
    table.insert(L, 'Labels: ' .. table.concat(ls, ', '))
  end
  table.insert(L, '')
  for _, l in ipairs(vim.split(pr.body or '', '\n', { plain = true })) do
    table.insert(L, l)
  end
  table.insert(L, '')
  table.insert(L, ('Commits (%d):'):format(#(pr.commits or {})))
  for _, c in ipairs(pr.commits or {}) do
    table.insert(L,
      ('  %s  %s  %s'):format((c.oid or ''):sub(1, 12), (c.committedDate or ''):sub(1, 10),
        c.messageHeadline or ''))
  end
  if #(pr.general or {}) > 0 then
    table.insert(L, '')
    table.insert(L, ('Discussion (%d):'):format(#pr.general))
    for _, c in ipairs(pr.general) do
      table.insert(L, ('  %s  %s'):format(c.user, c.updated_at))
      for _, bl in ipairs(vim.split(c.body or '', '\n', { plain = true })) do
        table.insert(L, '    ' .. bl)
      end
    end
  end
  table.insert(L, '')
  table.insert(L, 'dd diff · cR review · cM complete · cC comment · g? help')
  return L
end

--- Shows PR overview, then loads the diff + comments split.
--- @param id integer
--- @param repo string "org/project/repo"
--- @param focus boolean
function M.show_pr(id, repo, focus)
  local buf = state.init_buf('pr', focus, repo, id)
  local progress = util.new_progress_report('Loading PR...', buf)
  progress('running')
  az.get_pr_data(id, repo, { force = true }, function(pr)
    if not pr then
      progress('failed')
      return util.buf_set_readonly_lines(buf, { ('azdo: PR #%s not found'):format(id) }, 'markdown')
    end
    util.buf_set_readonly_lines(buf, render_overview(pr), 'markdown')
    util.set_default_keymaps(buf)
    progress('success')
    -- Load the diff + comments split (the pr/ buf becomes prdiff/'s alt-buf).
    vim.schedule(function()
      M.show_pr_diff({ id = id, repo = repo })
    end)
  end)
end

--- Shows PR diff + comments as two 'scrollbind' windows.
function M.show_pr_diff(opts)
  local _, id, repo = resolve_pr(opts)
  local buf = state.init_buf('prdiff', true, repo, id)
  local diff_win = vim.api.nvim_get_current_win()

  local progress = util.new_progress_report('Loading PR diff...', buf)
  progress('running')

  local pr_data --[[@type PullRequest?]]
  local diff_stdout
  local function try_render()
    if not pr_data or not diff_stdout then
      return
    end
    local lines, threads, n_files, n_viewed_threads = comments.render_diff(pr_data, diff_stdout)
    util.log(('comment threads (total: %s)'):format(vim.tbl_count(threads)), threads)
    util.buf_set_readonly_lines(buf, lines, 'gitcommit')
    vim.api.nvim_buf_call(buf, function()
      vim.cmd([[syntax match AzdoWarning /^(viewed)/ containedin=ALL]])
      vim.cmd([[syntax match AzdoWarning /\<\(outdated\|outside\)\ze-\d\+:/ containedin=ALL]])
    end)
    util.set_default_keymaps(buf)
    comments.show_pr_comments(
      id,
      repo,
      diff_win,
      threads,
      pr_data.viewed,
      n_files,
      pr_data.n_threads,
      pr_data.n_resolved,
      n_viewed_threads
    )
    progress('success')
  end

  -- 1. Fetch PR data (cache-friendly; show_pr/refresh prime or clear the cache).
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return progress('failed')
    end
    pr_data = pr
    -- 2. Get the unified diff (local git).
    az.get_pr_diff(repo, pr, function(stdout, err)
      if not stdout then
        progress('failed', nil, err or '')
        diff_stdout = ('# Could not produce diff: %s\n'):format(err or '')
      else
        diff_stdout = stdout
      end
      try_render()
    end)
    try_render()
  end)
end

--- Toggles the PR diff + comments split. If the prdiff/prcomments windows are open, closes the
--- comments split and restores the PR overview into the diff window(s); otherwise opens the diff
--- (via `show_pr_diff`). Bound to `dd` in azdo:// buffers.
function M.toggle_pr_diff(opts)
  local ok, _, id, repo = pcall(resolve_pr, opts)
  if not ok or not (id and repo) then
    vim.notify('azdo: not in a PR buffer', vim.log.levels.WARN)
    return
  end

  local prdiff = state.get_buf('prdiff', repo, id, false)
  local prcomments = state.get_buf('prcomments', repo, id, false)
  local diff_wins = prdiff and vim.fn.win_findbuf(prdiff) or {}
  local cmt_wins = prcomments and vim.fn.win_findbuf(prcomments) or {}

  if #diff_wins == 0 and #cmt_wins == 0 then
    return M.show_pr_diff(opts) -- nothing open → toggle on
  end

  -- Toggle off: drop the comments split, return the diff window(s) to the PR overview.
  for _, w in ipairs(cmt_wins) do
    pcall(vim.api.nvim_win_close, w, false)
  end
  local pr_buf = state.get_buf('pr', repo, id, false)
  for _, w in ipairs(diff_wins) do
    if vim.api.nvim_win_is_valid(w) then
      if pr_buf then
        -- show_pr_comments set scrollbind/cursorbind on the diff window; clear them so the
        -- overview scrolls normally.
        vim.api.nvim_win_call(w, function()
          vim.cmd('setlocal noscrollbind nocursorbind')
        end)
        vim.api.nvim_win_set_buf(w, pr_buf)
      else
        pcall(vim.api.nvim_win_close, w, false)
      end
    end
  end
end

--- Posts a top-level comment on the current PR or work-item.
local function comment_overview()
  local feat, id, repo = resolve_pr()
  local kind = feat == 'issue' and 'issue' or 'pr'

  comments.edit_comment('comment', id, { '' }, nil, function(input)
    local progress = util.new_progress_report('Sending comment...', vim.api.nvim_get_current_buf())
    az.new_overview_comment(kind, id, repo, input, function(ok, stderr)
      if ok then
        progress('success', nil, 'Comment sent.')
      else
        progress('failed', nil, ('Failed to send comment: %s'):format(vim.trim(stderr or '')))
      end
    end)
  end)
end

--- Implements `:AzdoComment`.
--- @param args vim.api.keyset.create_user_command.command_args
M.comment = function(args)
  assert(args and args.line1 and args.line2)
  if args.bang then
    if (args.range or 0) == 0 then
      return util.msg('AzdoComment!: [range] is required', vim.log.levels.ERROR)
    end
    if args.line1 ~= args.line2 then
      return util.msg('AzdoComment!: [range] must be a single line', vim.log.levels.ERROR)
    end
    return comments.delete_comment(args.line1)
  end
  if (args.range or 0) > 0 and args.line1 == 1 and args.line2 == vim.fn.line('$') then
    return comment_overview()
  end
  if (vim.b.azdo or {}).feat == 'prcomments' then
    return comments.update_comment(args.line1)
  end
  comments.new_comment(args.line1, args.line2)
end

--- Edits PR properties (title/description), or a work item's sections, in an editable buffer.
function M.edit_pr()
  local feat, id, repo = resolve_pr()
  if feat == 'issue' then
    return M.edit_workitem(id, repo)
  end
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    vim.schedule(function()
      local content = vim.split(('%s\n\n%s'):format(pr.title or '', pr.body or ''):gsub('\r', ''),
        '\n', { plain = true })
      local heading = { { 'First line = title; rest = description | ZZ to save (ZQ to abort)', 'Comment' } }
      comments.edit_comment('edit', id, content, heading, function(input)
        local title, description = input:match('^([^\n]*)\n?(.*)$')
        local progress = util.new_progress_report('Updating PR...', vim.api.nvim_get_current_buf())
        az.update_pr(id, repo,
          { title = vim.trim(title or ''), description = vim.trim(description or '') },
          function(ok, stderr)
            if ok then
              progress('success', nil, 'PR updated.')
            else
              progress('failed', nil, ('Failed: %s'):format(vim.trim(stderr or '')))
            end
          end)
      end)
    end)
  end)
end

--- Opens a scratch editor (vim-fugitive style: ZZ submits, ZQ aborts), prefilled
--- with `content`. Mirrors `comments.edit_comment` but standalone, since PR
--- creation happens from a normal code buffer, not an azdo:// buffer.
--- @param content string[] initial lines
--- @param heading table winbar chunks (see util.show_winbar)
--- @param on_confirm fun(input: string)
local function compose(content, heading, on_confirm)
  vim.cmd('botright new')
  local buf = vim.api.nvim_get_current_buf()
  -- An acwrite buffer MUST have a name, or `:write` (which ZZ triggers) is a
  -- silent no-op: BufWriteCmd never fires and ZZ can't submit. (edit_comment
  -- gets its name from state.init_buf; here we name it ourselves.)
  vim.api.nvim_buf_set_name(buf, ('azdo://create-pr/%d'):format(buf))
  vim._with({ buf = buf }, function()
    vim.cmd('set wrap breakindent nonumber norelativenumber nolist')
  end)
  util.show_winbar(0, heading)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe' -- Ensure BufWipeout fires on :q.
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].textwidth = 0
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  -- Stay 'modified' so plain :q is refused: user must pick ZZ (submit) or ZQ (abort).
  vim.bo[buf].modified = true
  vim.cmd('normal! gg')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    once = true,
    callback = function()
      local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      vim.bo[buf].modified = false -- let ZZ's close step proceed
      vim.schedule(function()
        -- Close the compose window ourselves so the split doesn't linger when the
        -- user submits with `:w` (which writes but, unlike ZZ, doesn't close it).
        -- With ZZ the window is already gone, so this is a guarded no-op.
        if vim.api.nvim_win_is_valid(win) and #vim.api.nvim_tabpage_list_wins(0) > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        end
        if vim.trim(input) ~= '' then
          on_confirm(input)
        else
          util.msg('aborted (empty buffer)')
        end
      end)
    end,
  })
end

--- Creates a PR from the current branch. Source = current branch; target =
--- origin's default branch (falls back to "main"). Opens `compose` prefilled
--- from the branch-tip commit message; first line = title, rest = description.
function M.create_pr()
  local repo = resolve_local_repo()
  if not repo then
    return util.msg('azdo: Failed to resolve repo', vim.log.levels.ERROR)
  end
  util.system({ 'git', 'rev-parse', '--abbrev-ref', 'HEAD' }, function(branch, _, code)
    local cur_branch = code == 0 and vim.trim(branch) or ''
    util.system({ 'git', 'symbolic-ref', '--short', 'refs/remotes/origin/HEAD' },
      function(head, _, hc)
        local default_target = (hc == 0 and vim.trim(head):gsub('^origin/', '')) or 'main'
        -- Gather local + origin/* branch names for the branch prompts' Tab-completion.
        util.system(
          { 'git', 'for-each-ref', '--format=%(refname:short)', 'refs/heads', 'refs/remotes/origin' },
          function(refs)
            branch_candidates = collect_branches(refs)
            vim.schedule(function()
              local complete = "customlist,v:lua.require'azdo.pr'._complete_branch"
              -- Both branches are editable; source defaults to the current branch.
              local source = vim.trim(vim.fn.input({
                prompt = 'Source branch: ',
                default = cur_branch,
                completion =
                    complete
              }))
              if source == '' then
                return util.msg('azdo: PR creation aborted (no source branch)')
              end
              local target = vim.trim(vim.fn.input({
                prompt = 'Target branch: ',
                default =
                    default_target,
                completion = complete
              }))
              if target == '' then
                return util.msg('azdo: PR creation aborted (no target branch)')
              end
              if source == target then
                return util.msg('azdo: source and target branch are the same', vim.log.levels.WARN)
              end
              -- Prefill the title from the source branch's tip commit subject. The
              -- description stays empty unless the repo ships a PR template — in
              -- which case leaving it blank silently skips a checklist reviewers
              -- expect to see filled in, which is worse than a prefilled buffer.
              local subject = vim.trim((vim.fn.systemlist({ 'git', 'log', '-1', '--format=%s', source })[1]) or
                '')
              local content = { subject ~= '' and subject or source }
              local template = M._read_pr_template()
              if template then
                table.insert(content, '')
                vim.list_extend(content, template)
              end
              local heading = {
                { ('Create PR: %s → %s'):format(source, target), 'AzdoHeading' },
                { '  first line = title; rest = description | ZZ to create (ZQ to abort)', 'Comment' },
              }
              compose(content, heading, function(input)
                local title, description = input:match('^([^\n]*)\n?(.*)$')
                local progress = util.new_progress_report('Creating PR...',
                  vim.api.nvim_get_current_buf())
                az.create_pr(repo, source, target, vim.trim(title or ''), vim.trim(description or ''),
                  function(id, stderr)
                    if id then
                      progress('success', nil, ('Created PR #%d.'):format(id))
                      -- Open the new PR's diff view. By default in a new tab so it
                      -- doesn't clobber the window you created it from; set
                      -- `create_in_tab = false` in setup() to open it in place.
                      if config.options.create_in_tab ~= false then
                        vim.cmd('tabnew')
                      end
                      M.show_pr(id, repo, true)
                    else
                      progress('failed', nil, ('Failed: %s'):format(vim.trim(stderr or '')))
                    end
                  end)
              end)
            end)
          end)
      end)
  end)
end

--- Opens the current PR (or work item) in the web browser.
function M.open_web()
  local feat, id, repo = resolve_pr()
  local url
  if feat == 'issue' then
    url = az.wi_web_url(repo, id)
  else
    url = az.pr_web_url(repo, id)
  end
  util.msg('Opening in browser…')
  vim.ui.open(url)
end

--- Links a work item assigned to you to the current PR. Lists your assigned work
--- items, then links the chosen one (vim.ui.select).
function M.link_workitem()
  local feat, id, repo = resolve_pr()
  if feat == 'issue' then
    return util.msg('azdo: link works on a PR, not a work item', vim.log.levels.WARN)
  end
  local progress = util.new_progress_report('Loading work items...', 0)
  progress('running')
  az.list_my_workitems(repo, function(items, err)
    if not items then
      return progress('failed', nil, ('Failed: %s'):format(vim.trim(err or '')))
    end
    if #items == 0 then
      return progress('success', nil, 'No work items assigned to you.')
    end
    progress('success')
    vim.ui.select(items, {
      prompt = ('Link work item to PR #%d:'):format(id),
      format_item = function(wi)
        return ('#%d  [%s]  %s'):format(wi.id, wi_type_label(wi), wi.title)
      end,
    }, function(choice)
      if not choice then
        return util.msg('azdo: no work item selected')
      end
      local p2 = util.new_progress_report('Linking work item...', vim.api.nvim_get_current_buf())
      az.link_workitem(repo, id, choice.id, function(ok, lerr)
        if ok then
          p2('success', nil, ('Linked #%d to PR #%d.'):format(choice.id, id))
          M.refresh()
        else
          p2('failed', nil, ('Failed: %s'):format(vim.trim(lerr or '')))
        end
      end)
    end)
  end)
end

--- Shows a menu of CI (pipeline) logs for the PR.
function M.show_ci_logs(opts)
  local _, id, repo = resolve_pr(opts)
  az.get_pr_data(id, repo, nil, function(pr)
    if not pr then
      return util.msg(('PR #%s not found'):format(id), vim.log.levels.ERROR)
    end
    az.get_pr_ci_jobs_logs(pr, repo, function(jobs, jobs_err)
      if not jobs then
        return util.msg(('failed to list CI jobs: %s'):format(jobs_err or ''), vim.log.levels.WARN)
      end
      jobs = vim.tbl_filter(function(j)
        return j.conclusion ~= 'skipped'
      end, jobs)
      if #jobs == 0 then
        return util.msg(('No (non-skipped) CI jobs for PR #%s'):format(id), vim.log.levels.WARN)
      end

      vim.ui.select(jobs, {
        prompt = ('CI jobs for PR #%s'):format(id),
        format_item = function(j)
          return ('[%s] %s'):format(j.conclusion or j.status or '?', j.name)
        end,
      }, function(picked)
        if not picked then
          return
        end
        az.get_pr_ci_logs(picked.databaseId, repo, function(logs, err)
          if not logs then
            return util.msg(('failed to get CI log: %s'):format(err or ''), vim.log.levels.ERROR)
          end
          local buf = state.init_buf('logs', true, repo, picked.databaseId, { id = id })
          vim.cmd.buffer(buf)
          local chan = vim.api.nvim_open_term(0, {})
          vim.api.nvim_chan_send(chan, logs)
          vim.cmd.norm([[gg0]])
        end)
      end)
    end)
  end)
end

return M
