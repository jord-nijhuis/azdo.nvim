local state = require('azdo.state')
local config = require('azdo.config')

local M = {}

local overlay_ns = vim.api.nvim_create_namespace('azdo.info_overlay')
local flash_ns = vim.api.nvim_create_namespace('azdo.flash')

--- Flashes the given region so the user can see the target of an action.
---
--- If `start`/`end_` are integers, the region is treated as linewise (regtype="V").
---
--- @param buf integer
--- @param start integer|[integer, integer]
--- @param end_ integer|[integer, integer]
function M.hl_flash(buf, start, end_)
  local linewise = type(start) == 'number'
  vim.hl.range(buf, flash_ns, 'Visual', linewise and { start, 0 } or start, linewise and { end_, 0 } or end_, {
    regtype = linewise and 'V' or 'v',
    priority = 300, -- Overrule diffs.nvim: https://github.com/barrettruth/diffs.nvim/blob/d280baf3e937a487038766f51156dd41ceb0f8e7/lua/diffs/config.lua#L124-L129
    timeout = 200,
  })
end

--- Shared `nvim_echo` notification id. Re-using it makes successive emits
--- update the same notification in place, so progress events from different
--- callers (e.g. <CR>'s "Loading..." and the real work's progress) collapse
--- into one row.
local progress_echo_id = nil ---@type integer?

--- Builds an argv that runs `string.format(cmdstring, ...)` through a shell.
---
--- The purpose of this is to linearize a bunch of `cmd1 && cmd2 && …` shell commands into one terminal invocation.
---
--- TODO: this would not be needed if Nvim allowed appending-to a buftype=terminal buffer.
---
--- @param cmdstring string `string.format`-style script: "cmd1 && cmd2 && …"
--- @param ... string|number values to quote and substitute into `cmdstring`.
--- @return string[] argv
function M.shell_cmd(cmdstring, ...)
  local shell, flag, q
  if vim.fn.has('win32') == 1 then
    shell, flag, q = 'cmd.exe', '/c', '"'
  else
    shell, flag, q = 'sh', '-c', "'"
  end
  local args = { ... }
  for i, v in ipairs(args) do
    args[i] = q .. tostring(v) .. q
  end
  return { shell, flag, cmdstring:format(unpack(args)) }
end

--- Runs a command asynchronously via `vim.system`. The callback is deferred (`vim.schedule_wrap`).
---
--- @param cmd string[] argv list.
--- @param cb? fun(stdout: string, stderr: string, code: integer)
function M.system(cmd, cb)
  vim.system(cmd, { text = true }, function(result)
    if type(cb) == 'function' then
      vim.schedule_wrap(cb)(result.stdout, result.stderr, result.code)
    end
  end)
end

--- URL-decodes percent-escapes (e.g. "My%20Project" -> "My Project").
local function urldecode(s)
  return (s:gsub('%%(%x%x)', function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Parses an :Azdo argument. `repo` (when present) is the full "org/project/repo" triplet. Accepts:
---   - bare number: `"13"` (PR/work-item in the current repo)
---   - bare commit SHA (7-40 hex chars, must contain a-f): `"a1b2c3d"`
---   - Azure DevOps PR URL: `"https://dev.azure.com/org/project/_git/repo/pullrequest/13"`
---   - Azure DevOps commit URL: `"…/_git/repo/commit/<sha>"`
---   - Azure DevOps work-item URL: `"https://dev.azure.com/org/project/_workitems/edit/13"`
---   - Repo URL: `"https://dev.azure.com/org/project/_git/repo"` -> status view
---   - slug: `"org/project/repo#13"`, or bare repo slug `"org/project/repo"`.
---   - azdo URI: `"azdo://org/project/repo/pr/13"`, `"…/issue/13"`, `"…/commit/<sha>"`, `"azdo://status"`
---
--- @param arg string
--- @return { repo?: string, id?: integer, sha?: string, is_pr?: boolean }?
function M.parse_target(arg)
  arg = vim.trim(arg or '')
  local org, project, repo, num, sha, feat

  -- Azure DevOps PR URL.
  org, project, repo, num = arg:match('^https?://[^/]*dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(%d+)')
  if org then
    return { repo = urldecode(('%s/%s/%s'):format(org, project, repo)), id = tonumber(num), is_pr = true }
  end
  -- Azure DevOps commit URL.
  org, project, repo, sha = arg:match('^https?://[^/]*dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)/commit/(%x+)')
  if org then
    return { repo = urldecode(('%s/%s/%s'):format(org, project, repo)), sha = sha }
  end
  -- Azure DevOps work-item URL (project-level; repo resolved from context).
  num = arg:match('^https?://[^/]*dev%.azure%.com/[^/]+/[^/]+/_workitems/edit/(%d+)')
  if num then
    return { id = tonumber(num), is_pr = false }
  end
  -- Bare Azure DevOps repo URL (optional trailing slash) -> status view.
  org, project, repo = arg:match('^https?://[^/]*dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)/?$')
  if org then
    return { repo = urldecode(('%s/%s/%s'):format(org, project, repo)) }
  end

  -- azdo:// URIs. `repo` may contain slashes (org/project/repo), so match greedily up to the feat/id.
  repo, sha = arg:match('^azdo://(.+)/commit/(%x+)$')
  if repo then
    return { repo = repo, sha = sha }
  end
  repo, feat, num = arg:match('^azdo://(.+)/(%a+)/(%d+)$')
  if repo then
    local is_pr = (feat == 'pr' or feat == 'prdiff' or feat == 'prcomments') or nil
    return { repo = repo, id = tonumber(num), is_pr = is_pr }
  end
  if arg:match('^azdo://%a+$') then
    return {} -- global (status)
  end

  -- "org/project/repo#13" slug.
  org, project, repo, num = arg:match('^([%w%._-]+)/([%w%._%- ]+)/([%w%._-]+)#(%d+)$')
  if org then
    return { repo = ('%s/%s/%s'):format(org, project, repo), id = tonumber(num) }
  end
  -- Bare "org/project/repo" slug -> status view.
  org, project, repo = arg:match('^([%w%._-]+)/([%w%._%- ]+)/([%w%._-]+)$')
  if org then
    return { repo = ('%s/%s/%s'):format(org, project, repo) }
  end

  num = arg:match('^#(%d+)$')
  if num then
    return { id = tonumber(num) }
  end

  -- Bare commit SHA: 7-40 hex chars with at least one a-f letter (disambiguates from numeric IDs).
  if arg:match('^[%da-fA-F]+$') and #arg >= 7 and #arg <= 40 and arg:match('[a-fA-F]') then
    return { sha = arg }
  end

  num = tonumber(arg)
  if num then
    return { id = num }
  end
  return nil
end

function M.is_empty(value)
  return value == nil or value == '' or value == 0 or #value == 0
end

--- Appends a debug log entry to `stdpath('log')/azdo.log` when the `debug`
--- option is true. No-op otherwise.
---
--- @param key string
--- @param message any
function M.log(key, message)
  if not config.options.debug then
    return
  end
  local log_file_name = vim.fn.stdpath('log') .. '/azdo.log'
  local log_file = io.open(log_file_name, 'a')
  if not log_file then
    return
  end
  log_file:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. key .. ':\n')
  log_file:write(vim.inspect(message))
  log_file:write('\n\n')
  log_file:close()
end

--- Shows a notification prefixed with "azdo:".
--- @param message string
--- @param level? integer one of `vim.log.levels.*`
function M.msg(message, level)
  vim.schedule(function()
    vim.notify(('azdo: %s'):format(message), level)
  end)
end

--- Returns the named `b:azdo` fields in order, as multiple return-values, or emits an error and returns nil if
--- a required `b:azdo` field is missing.
---
--- @param required string[] field names that must be non-nil on `b:azdo`.
--- @param errmsg? string Defaults to "Not in a azdo:// buffer".
--- @return any ...
function M.require_b_azdo(required, errmsg)
  local b_azdo = vim.b.azdo or {}
  local vals = {}
  for i, k in ipairs(required) do
    if b_azdo[k] == nil then
      M.msg(errmsg or 'Not in a azdo:// buffer', vim.log.levels.ERROR)
      return
    end
    vals[i] = b_azdo[k]
  end
  return unpack(vals)
end

--- @param action string
--- @param buf integer
--- @return fun(status: 'running'|'success'|'failed'|'cancel', percent?: integer, fmt?: string, ...:any): nil
function M.new_progress_report(action, buf)
  local progress = { kind = 'progress', title = 'azdo' }
  local incremented = false
  if buf and not vim.in_fast_event() and buf > 0 then
    vim.bo[buf].busy = vim.bo[buf].busy + 1
    incremented = true
  end

  return vim.schedule_wrap(function(status, percent, fmt, ...)
    local done = (status == 'failed' or status == 'success' or status == 'cancel')
    progress.source = 'azdo.nvim'
    progress.status = status
    progress.percent = not done and percent or nil
    progress.title = not done and progress.title or nil
    progress.id = progress_echo_id
    local msg = done and '' or ('%s %s'):format(action, (fmt or ''):format(...))
    progress_echo_id = vim.api.nvim_echo({ { msg } }, status ~= 'running', progress)
    if done then
      progress_echo_id = nil
    end

    -- Only decrement on done, and only if we incremented in the first place.
    if done and incremented and buf and vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].busy = math.max(0, vim.bo[buf].busy - 1)
      incremented = false
    end
  end)
end

--- Synchronously emits "Loading..." (or `label`) under a shared progress-id.
--- Returns a finalizer that emits `status` (default 'success') to dismiss.
---
--- @param label? string default: "Loading..."
--- @return fun(status?: 'success'|'failed'|'cancel')
function M.progress(label)
  progress_echo_id = vim.api.nvim_echo({ { label or 'Loading...' } }, false, {
    kind = 'progress',
    source = 'azdo.nvim',
    title = 'azdo',
    status = 'running',
    id = progress_echo_id,
  })
  return function(status)
    progress_echo_id = vim.api.nvim_echo({ { '' } }, false, {
      kind = 'progress',
      source = 'azdo.nvim',
      status = status or 'success',
      id = progress_echo_id,
    })
    progress_echo_id = nil
  end
end

--- Sets a buffer-local `lhs` → `rhs_plug` mapping, unless the user already
--- mapped that `<Plug>` to a different key (per |hasmapto()|).
---
--- @param mode string|string[] Mode name, or list thereof.
--- @param extra? table extra keymap opts (e.g. `{ nowait = true }`).
function M.map_default(buf, mode, lhs, rhs_plug, desc, extra)
  local modes = type(mode) == 'table' and mode or { mode }
  for _, m in ipairs(modes) do
    local has = vim.api.nvim_buf_call(buf, function()
      return vim.fn.hasmapto(rhs_plug, m) ~= 0
    end)
    if not has then
      local opts = vim.tbl_extend('keep', extra or {}, {
        buffer = buf,
        remap = true,
        silent = true,
        desc = desc,
      })
      vim.keymap.set(m, lhs, rhs_plug, opts)
    end
  end
end

--- Defines buffer-local defaults for the global `<Plug>(azdo-…)` mappings, if necessary.
--- These defaults are shared across all `azdo://*` views (status, PR, issue, prdiff, prcomments).
---
--- @param buf integer
--- Static wiring for the default buffer mappings: each action's mode, the
--- `<Plug>` it fires, its description, extra keymap opts, and (optionally) the
--- `azdo://` features it applies to. The *keys* are configurable — they come
--- from `config.options.keymaps[name]` — but the plug/desc are fixed here.
--- `feats = nil` means "all features".
local KEYMAP_SPEC = {
  -- "Global" (buffer-relative) VIEW actions:
  { name = 'refresh', plug = '<Plug>(azdo-refresh)', desc = 'Refresh this azdo:// buffer' },
  { name = 'diff_toggle', plug = '<Plug>(azdo-diff-toggle)', desc = 'Toggle the PR diff + comments split' },
  { name = 'logs', plug = '<Plug>(azdo-logs)', desc = 'View the CI logs for this PR' },
  { name = 'next_commit', plug = '<Plug>(azdo-next-commit)', desc = 'View the next PR commit' },
  { name = 'prev_commit', plug = '<Plug>(azdo-prev-commit)', desc = 'View the previous PR commit' },
  { name = 'web', plug = '<Plug>(azdo-web)', desc = 'Open this PR/work-item in the web browser' },
  { name = 'link', plug = '<Plug>(azdo-link)', desc = 'Link a work item (assigned to you) to this PR' },
  { name = 'help', plug = '<Plug>(azdo-help)', desc = 'Show azdo-mappings help', extra = { nowait = true } },

  -- "Global" (buffer-relative) UPDATE actions:
  { name = 'comment_overview', plug = '<Plug>(azdo-comment-overview)', desc = 'Comment on PR/issue overview' },
  { name = 'merge', plug = '<Plug>(azdo-merge)', desc = 'Merge PR' },
  {
    name = 'pipeline',
    plug = '<Plug>(azdo-pipeline)',
    desc = "Queue a pipeline for this PR's source branch",
  },
  { name = 'review', plug = '<Plug>(azdo-review)', desc = 'Review PR (approve/request-changes/comment)' },
  {
    name = 'edit',
    plug = '<Plug>(azdo-edit)',
    desc = 'Edit PR/issue properties (az repos pr update, az boards work-item update)',
  },

  -- "Local" (cursor-relative) actions:
  {
    name = 'comment',
    plug = '<Plug>(azdo-comment)',
    desc = 'Comment on PR or diff',
    feats = { pr = true, prdiff = true, prcomments = true },
  },
  {
    name = 'comment_visual',
    mode = 'x',
    plug = '<Plug>(azdo-comment)',
    desc = 'Comment on PR or diff',
    feats = { pr = true, prdiff = true, prcomments = true },
  },
  { name = 'thread', plug = '<Plug>(azdo-thread)', desc = 'Reply-to or Resolve a comment thread' },
  { name = 'comment_delete', plug = '<Plug>(azdo-comment-delete)', desc = 'Delete a comment (prompts to confirm)' },
  { name = 'comment_update', plug = '<Plug>(azdo-comment-update)', desc = 'Update/edit a comment' },
  { name = 'open', plug = '<Plug>(azdo-open)', desc = 'Open :Azdo target at cursor' },
  { name = 'open_split', plug = '<Plug>(azdo-open-split)', desc = 'Open :Azdo target at cursor in a split' },
  { name = 'open_tab', plug = '<Plug>(azdo-open-tab)', desc = 'Open :Azdo target at cursor in a new tab' },
  {
    name = 'checkout',
    plug = '<Plug>(azdo-checkout)',
    desc = "Check out this PR's branch in a worktree, in a new tab",
  },

  -- Comment-thread navigation: only useful in the diff + comments panes, where
  -- threads are anchored. (Both panes are line-aligned, so this works in either.)
  {
    name = 'next_comment',
    plug = '<Plug>(azdo-next-comment)',
    desc = 'Jump to next comment thread',
    feats = { prdiff = true, prcomments = true },
  },
  {
    name = 'prev_comment',
    plug = '<Plug>(azdo-prev-comment)',
    desc = 'Jump to previous comment thread',
    feats = { prdiff = true, prcomments = true },
  },

  -- Work-items dashboard only:
  {
    name = 'tag_toggle',
    plug = '<Plug>(azdo-tag-toggle)',
    desc = 'Tag/untag the work item under the cursor',
    feats = { workitems = true },
  },
  {
    name = 'sort',
    plug = '<Plug>(azdo-sort)',
    desc = 'Sort the work-items dashboard (picks a field)',
    feats = { workitems = true },
  },
  {
    name = 'set_state',
    plug = '<Plug>(azdo-set-state)',
    desc = "Set the work item's state (picks from its type's states)",
    feats = { workitems = true, issue = true },
  },
  {
    name = 'start_branch',
    plug = '<Plug>(azdo-start-branch)',
    desc = 'Create and check out a branch for the work item under the cursor',
    feats = { workitems = true, issue = true },
  },
  {
    name = 'toggle_hidden',
    plug = '<Plug>(azdo-toggle-hidden)',
    desc = 'Show/hide the dashboard\'s hidden states (items.hide_states)',
    feats = { workitems = true },
  },
  {
    name = 'assignee',
    plug = '<Plug>(azdo-assignee)',
    desc = 'Filter the dashboard by assignee (All / you / pick people)',
    feats = { workitems = true },
  },
}

--- Defines the buffer-local default mappings for this `azdo://` buffer, reading
--- the per-action keys from `config.options.keymaps`. Skipped entirely when
--- `keymaps = false`; a single action with a falsey/empty key is skipped too.
function M.set_default_keymaps(buf)
  local keymaps = config.options.keymaps
  if keymaps == false or keymaps == nil then
    return
  end
  local feat = (vim.b[buf].azdo or {}).feat
  for _, spec in ipairs(KEYMAP_SPEC) do
    if not spec.feats or spec.feats[feat] then
      local lhs = keymaps[spec.name]
      if type(lhs) == 'string' and lhs ~= '' then
        M.map_default(buf, spec.mode or 'n', lhs, spec.plug, spec.desc, spec.extra)
      end
    end
  end
end

function M.buf_keymap(buf, mode, lhs, desc, rhs)
  if not M.is_empty(lhs) then
    local opts = {}
    opts.desc = opts.desc == nil and desc or opts.desc
    opts.noremap = opts.noremap == nil and true or opts.noremap
    opts.silent = opts.silent == nil and true or opts.silent
    opts.buffer = buf
    local function wrap_rhs(args)
      -- Fixup because apparently mappings don't get args?
      if not args then
        args = {}
        local region = vim.fn.getregionpos(vim.fn.getpos('v'), vim.fn.getpos('.'), {
          type = 'v',
          exclusive = false,
          eol = false,
        })
        args.line1 = region[1][1][2]
        args.line2 = region[#region][1][2]
        -- vim.fn.feedkeys(vim.keycode('<Esc>'), 'nx')
      end
      rhs(args)
    end
    vim.keymap.set(mode, lhs, type(rhs) == 'function' and wrap_rhs or rhs, opts)
  end
end

--- Replaces `buf` contents with `lines` and sets the buffer as non-writable scratch
--- (buftype=nofile, 'nomodifiable', 'readonly').
---
--- @param buf integer
--- @param lines string[]
--- @param ft string filetype to apply.
function M.buf_set_readonly_lines(buf, lines, ft)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].filetype = ft
end

--- Overwrites the current :terminal buffer with the given cmd.
---
--- The buffer must have been initialized via `state.init_buf()` (`b:azdo` is used to re-apply
--- the `azdo://…` name on term exit, since Nvim stomps it).
---
--- @param buf integer (must have `b:azdo` set by `state.init_buf()`)
--- @param cmd string[]
--- @param on_done? fun()
function M.run_term_cmd(buf, cmd, on_done)
  -- Fail fast if b:azdo is invalid (init_buf() wasn't called?).
  local b_azdo = vim.b[buf].azdo
  assert(b_azdo and b_azdo.feat and b_azdo.bufkey, ('run_term_cmd: invalid b:azdo on buf %d'):format(buf))
  local progress = M.new_progress_report('Loading...', buf)
  progress('running')
  vim.schedule(function()
    local isempty = 1 == vim.fn.line('$') and '' == vim.fn.getline(1)
    assert(isempty or not vim.api.nvim_buf_is_loaded(buf) or (vim.o.buftype == 'terminal' and not not vim.b[buf].azdo))
    vim.o.modifiable = true
    vim.o.modified = false
    vim.fn.jobstart(cmd, {
      term = true,
      env = {
        GH_PAGER = 'cat',
        PAGER = 'cat',
      },
      on_exit = function()
        local ns = vim.api.nvim_get_namespaces()['nvim.terminal.exitmsg']
        if ns and vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        end
        state.set_buf_name(buf, b_azdo.feat, b_azdo.bufkey)
        if on_done then
          on_done()
        end
        progress('success')
      end,
    })
  end)
end

--- Sets the window-local 'winbar' to a list of `{text, hl_group?}` chunks.
---
--- Pass `chunks=nil` to clear/disable.
---
--- @param win integer
--- @param chunks? [string, string?][] List of `{text, hl_group}` pairs, or nil to disable the winbar.
function M.show_winbar(win, chunks)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  if not chunks then
    vim.wo[win].winbar = ''
    return
  end
  local parts = {}
  for i, ck in ipairs(chunks) do
    local text, hl = ck[1]:gsub('%%', '%%%%'), ck[2] -- escape `%` for statusline syntax
    assert(hl == nil or type(hl) == 'string', 'show_winbar: hl_group must be a string')
    -- Example: ({'foo', 'Comment'}) -> "%#Comment#foo%*"
    table.insert(parts, hl and ('%%#%s#%s%%*'):format(hl, text) or text)
    -- After the first chunk insert `%<` so the title is preserved and truncation (">" marker) cuts from there.
    if i == 1 then
      table.insert(parts, '%<')
    end
  end
  vim.wo[win].winbar = table.concat(parts)
end

--- A small centered, markdown-styled multi-select popup. Each item is
--- `{ label = string, checked? = boolean, exclusive? = boolean }`; toggling an
--- `exclusive` item on clears the rest, and toggling any normal item on clears
--- the exclusive ones (so e.g. an "All" entry can't coexist with specific picks).
--- Keys: `<Space>`/`<Tab>` toggle the line under the cursor, `<CR>` applies,
--- `q`/`<Esc>` (or leaving the float) cancels.
---
--- @param opts { title?: string, items: { label: string, checked?: boolean, exclusive?: boolean }[] }
--- @param cb fun(selected?: integer[]) indices (into opts.items) of checked items, or nil if cancelled.
function M.multiselect(opts, cb)
  opts = opts or {}
  local items = opts.items or {}
  if #items == 0 then
    M.msg('azdo: nothing to choose from')
    return cb(nil)
  end

  local HEADER = 3 -- title, blank, help — items start at HEADER+1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'

  local function render()
    local lines = {
      '# ' .. (opts.title or 'Select'),
      '',
      '`<Space>` toggle · `<CR>` apply · `q` cancel',
    }
    for _, it in ipairs(items) do
      lines[#lines + 1] = ('- [%s] %s'):format(it.checked and 'x' or ' ', it.label)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = 'markdown'
  end

  local width = 50
  for _, it in ipairs(items) do
    width = math.max(width, #it.label + 8)
  end
  width = math.min(width, math.max(40, vim.o.columns - 8))
  local height = math.min(#items + HEADER, math.max(8, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' azdo ',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true
  render()
  vim.api.nvim_win_set_cursor(win, { HEADER + 1, 0 })

  local done = false
  local function finish(result)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    cb(result)
  end

  local function toggle()
    local idx = vim.api.nvim_win_get_cursor(win)[1] - HEADER
    local it = items[idx]
    if not it then
      return
    end
    it.checked = not it.checked
    if it.checked then
      for j, other in ipairs(items) do
        -- exclusive on → clear everyone else; normal on → clear the exclusives.
        if (it.exclusive and j ~= idx) or (not it.exclusive and other.exclusive) then
          other.checked = false
        end
      end
    end
    render()
  end

  local kopts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<Space>', toggle, kopts)
  vim.keymap.set('n', '<Tab>', toggle, kopts)
  vim.keymap.set('n', '<CR>', function()
    local sel = {}
    for i, it in ipairs(items) do
      if it.checked then
        sel[#sel + 1] = i
      end
    end
    finish(sel)
  end, kopts)
  vim.keymap.set('n', 'q', function()
    finish(nil)
  end, kopts)
  vim.keymap.set('n', '<Esc>', function()
    finish(nil)
  end, kopts)
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })
end

return M
