--- Azure DevOps transport + data layer.
---
--- This module is the *only* provider-specific layer of azdo.nvim. It shells out to the Azure CLI
--- (`az rest` for arbitrary REST, plus local `git` for diffs/commits) and marshals the responses into
--- the provider-agnostic `PullRequest`/`Comment` shapes that the rest of the plugin consumes. Keeping
--- the mapping here means `comments.lua`/`state.lua`/`util.lua` never learn that the backend is Azure.
---
--- Cloud vs on-prem: by default urls target cloud `https://dev.azure.com/<org>`. For an on-prem Azure
--- DevOps Server, set `base_url` in setup() to the collection root (e.g.
--- "https://tfs.example.com/tfs/MyCollection") and, if the server is older, `api_version`
--- (e.g. '6.0'). See `base_url`/`api_version`. On-prem almost always pairs with PAT auth (below).
---
--- Auth: two modes. By default it relies on `az login` (every `az rest` call passes
--- `--resource <Azure DevOps GUID>` so the token audience targets dev.azure.com). If a PAT is configured
--- (the `pat` option, or the `AZDO_PAT` / `AZURE_DEVOPS_EXT_PAT` env vars) it instead talks to the REST
--- API directly via `curl` with HTTP Basic auth (`:<pat>`) — no Azure CLI / `az login` required. The PAT
--- is handed to curl on stdin (never argv) so it can't leak via `ps`. See `get_pat`/`build_request`.

local state = require('azdo.state')
local util = require('azdo.util')
local config = require('azdo.config')

require('azdo.types')

local f = string.format

local M = {}

--- Azure DevOps resource id (token audience for `az rest --resource`).
local AZDO_RESOURCE = '499b84ac-1321-427f-aa17-267ca6975798'
--- REST api-version used throughout. 7.1 is GA on Azure DevOps Services.
local API = '7.1'

--- Collection base url for an on-prem Azure DevOps Server, e.g.
--- "https://tfs.example.com/tfs/MyCollection" (no trailing slash). When set, all REST + web urls are
--- built from it instead of cloud "https://dev.azure.com/<org>", and identity comes from
--- `_apis/connectionData` (the cloud vssps profile api doesn't exist on-prem). Leave unset for cloud.
--- @return string?
local function base_url()
  local b = config.options.base_url
  if type(b) == 'string' and b ~= '' then
    return (b:gsub('/+$', ''))
  end
  return nil
end

--- REST api-version. Defaults to 7.1 (GA on Azure DevOps Services); older on-prem servers may need an
--- older value — set `api_version` in setup() (e.g. '6.0').
local function api_version()
  local v = config.options.api_version
  if type(v) == 'string' and v ~= '' then
    return v
  end
  return API
end
--- Azure comment ids are per-thread (1..n), not globally unique. We synthesize a globally-unique
--- id as `thread_id * MULT + comment_id` so the agnostic thread-grouping in comments.lua works, and
--- decode it back to (thread_id, comment_id) for the per-thread REST routes.
local COMMENT_MULT = 1000000

local function composite_id(thread_id, comment_id)
  return thread_id * COMMENT_MULT + comment_id
end

--- @return integer thread_id, integer comment_id
local function decode_id(cid)
  return math.floor(cid / COMMENT_MULT), cid % COMMENT_MULT
end

local function parse_or_default(str, default)
  local ok, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
  if ok then
    return result
  end
  return default
end

--- Percent-encodes a single URL path segment (so org/project/repo names with spaces work).
local function urlencode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return f('%%%02X', c:byte())
  end))
end

--- @param repo string "org/project/repo"
--- @return string? org, string? project, string? name
local function parse_repo(repo)
  return tostring(repo):match('^([^/]+)/([^/]+)/(.+)$')
end

--- Collection base: the on-prem url if configured, else cloud `https://dev.azure.com/<org>`.
local function collection_base(org)
  return base_url() or f('https://dev.azure.com/%s', urlencode(org))
end

--- Base REST url for a repo's git resource: `.../<project>/_apis/git/repositories/<repo>`.
local function repo_base(repo)
  local org, project, name = parse_repo(repo)
  if not org then
    return nil
  end
  return f('%s/%s/_apis/git/repositories/%s', collection_base(org), urlencode(project), urlencode(name))
end

--- Project-level REST base: `.../<project>/_apis`.
local function project_base(repo)
  local org, project = parse_repo(repo)
  if not org then
    return nil
  end
  return f('%s/%s/_apis', collection_base(org), urlencode(project))
end

--- Human-facing web url for a PR.
local function pr_web_url(repo, prnum)
  local org, project, name = parse_repo(repo)
  return f('%s/%s/_git/%s/pullrequest/%s', collection_base(org), urlencode(project), urlencode(name), prnum)
end

--- Appends `api-version` (and any extra query) to a url.
local function with_api(url, extra)
  local sep = url:find('?', 1, true) and '&' or '?'
  return url .. sep .. 'api-version=' .. api_version() .. (extra and ('&' .. extra) or '')
end

--- Optional Personal Access Token. When set, azdo.nvim authenticates with the PAT (HTTP Basic)
--- instead of `az login`. Source order: the `pat` option, then `$AZDO_PAT`, then `$AZURE_DEVOPS_EXT_PAT`
--- (the var the `az devops` CLI itself reads). The PAT needs the "Code (read & write)" scope, plus
--- "Build (read)" if you use the CI-logs view.
--- @return string?
local function get_pat()
  local p = config.pat()
  if p then
    return p
  end
  for _, name in ipairs({ 'AZDO_PAT', 'AZURE_DEVOPS_EXT_PAT' }) do
    local e = vim.env[name]
    if type(e) == 'string' and e ~= '' then
      return e
    end
  end
  return nil
end

--- Builds the (argv, stdin) for one REST request. With a PAT we use curl + HTTP Basic (`:<pat>`),
--- feeding the auth header via stdin (`--config -`) so the token never lands in argv (and thus not in
--- `ps`). Without a PAT we use `az rest --resource` (token from `az login`). `-w '\n%{http_code}'`
--- appends the HTTP status so `parse_response` can map non-2xx to failure (curl's own exit code is 0
--- even for 4xx/5xx, and we want the error body, so we don't use `--fail`).
--- @param raw boolean? request a non-JSON body (e.g. build logs); sets `Accept: */*`
--- @param content_type string? body Content-Type (default "application/json"; work-item
---   relation patches need "application/json-patch+json").
--- @return string[] cmd, string? stdin
local function build_request(method, url, body, pat, raw, content_type)
  content_type = content_type or 'application/json'
  if pat then
    local cmd = {
      'curl',
      '-sS',
      '--config',
      '-',
      '-X',
      method:upper(),
      '-H',
      raw and 'Accept: */*' or 'Accept: application/json',
      '-w',
      '\n%{http_code}',
    }
    if body ~= nil then
      vim.list_extend(cmd, { '-H', 'Content-Type: ' .. content_type, '--data-binary', vim.json.encode(body) })
    end
    cmd[#cmd + 1] = url
    return cmd, f('header = "Authorization: Basic %s"\n', vim.base64.encode(':' .. pat))
  end
  local cmd = { 'az', 'rest', '--method', method:lower(), '--url', url, '--resource', AZDO_RESOURCE }
  if body ~= nil then
    vim.list_extend(cmd, { '--headers', 'Content-Type=' .. content_type, '--body', vim.json.encode(body) })
  end
  return cmd, nil
end

--- Normalizes a `vim.system` result into `(value, stderr, code)` where `code == 0` means success.
--- For the PAT/curl path, strips the trailing `%{http_code}` line and maps non-2xx to failure; for the
--- `az` path, the process exit code is authoritative. `raw` returns the response text instead of JSON.
--- @return any value, string stderr, integer code
local function parse_response(r, pat, raw)
  if pat then
    if r.code ~= 0 then
      return nil, vim.trim(r.stderr or 'curl request failed'), r.code
    end
    local out, http = (r.stdout or ''):match('^(.*)\n(%d+)%s*$')
    out = out or (r.stdout or '')
    http = tonumber(http) or 0
    if http < 200 or http >= 300 then
      local msg = vim.trim(out ~= '' and out or (r.stderr or ''))
      return nil, msg ~= '' and msg or ('HTTP ' .. http), http ~= 0 and http or 1
    end
    return (raw and out or parse_or_default(out, {})), '', 0
  end
  if r.code ~= 0 then
    return nil, r.stderr or '', r.code
  end
  return (raw and (r.stdout or '') or parse_or_default(r.stdout or '', {})), r.stderr or '', 0
end

--- Async REST call. Uses a PAT (curl + HTTP Basic) when one is configured, else `az rest`.
--- Calls `cb(decoded|nil, stderr, code)` — code 0 means success (HTTP 2xx, or `az` exit 0).
---
--- @param method 'get'|'post'|'patch'|'put'|'delete'
--- @param url string Full request url (including api-version).
--- @param body? table JSON body for write methods.
--- @param cb fun(resp: table?, stderr: string, code: integer)
--- @param content_type string? body Content-Type (default "application/json").
local function az_rest(method, url, body, cb, content_type)
  local pat = get_pat()
  local cmd, stdin = build_request(method, url, body, pat, false, content_type)
  util.log('rest ' .. method, url)
  vim.system(cmd, { text = true, stdin = stdin }, vim.schedule_wrap(function(r)
    local resp, stderr, code = parse_response(r, pat, false)
    if code ~= 0 then
      util.log('rest error', { url = url, stderr = stderr, code = code })
    end
    cb(resp, stderr, code)
  end))
end

--- Write helper shaped like the rest of the plugin expects: `cb(resp)` where `resp.errors == nil`
--- means success. (comments.lua keys success off `resp.errors == nil`.)
---
--- @param logname string
--- @param method 'post'|'patch'|'put'|'delete'
--- @param url string
--- @param body? table
--- @param cb fun(resp: table)
local function az_write(logname, method, url, body, cb)
  az_rest(method, url, body, function(resp, stderr, code)
    util.log(logname .. ' resp', { code = code, resp = resp })
    if code ~= 0 or resp == nil then
      cb({ errors = { vim.trim(stderr or 'request failed') } })
    else
      cb(resp)
    end
  end)
end

---------------------------------------------------------------------------
-- Repo + user resolution
---------------------------------------------------------------------------

--- Resolves the local repo "org/project/repo" by parsing the `origin` remote url. Supports
--- `https://dev.azure.com/org/project/_git/repo`, the `org@dev.azure.com` and ssh
--- (`git@ssh.dev.azure.com:v3/org/project/repo`) variants, and legacy `org.visualstudio.com`.
---
--- @param cb fun(repo?: string)
function M.get_repo(cb)
  local progress = util.new_progress_report('Resolving repo...', 0)
  progress('running')
  util.system({ 'git', 'remote', 'get-url', 'origin' }, function(stdout, _, code)
    if code ~= 0 then
      progress('failed')
      return cb(nil)
    end
    local repo = M.parse_remote(vim.trim(stdout))
    progress(repo and 'success' or 'failed')
    cb(repo)
  end)
end

--- Parses an Azure DevOps remote url into "org/project/repo". Exposed for tests.
--- @return string? repo
function M.parse_remote(url)
  url = (url or ''):gsub('%.git$', '')
  -- on-prem Azure DevOps Server: a remote under the configured collection base, e.g.
  -- https://tfs.example.com/tfs/MyCollection/<project>/_git/<repo>. The org token in the returned
  -- key is the collection name (last path segment of the base); repo_base ignores it and uses
  -- base_url() directly, so the key stays stable across sessions / uri reopens.
  local base = base_url()
  if base then
    -- Match on the collection *path* (everything after scheme+host in the base), so both the https
    -- and ssh (ssh://host:22/tfs/Collection/...) remote forms resolve, regardless of any `user@`.
    local base_path = base:gsub('^https?://[^/]+', '')
    local rest = base_path ~= '' and url:match(vim.pesc(base_path) .. '/(.+)$')
    if rest then
      local project, name = rest:match('^(.+)/_git/(.+)$')
      if project then
        return f('%s/%s/%s', base:match('([^/]+)$') or 'collection', project, name)
      end
    end
  end
  -- https://dev.azure.com/org/project/_git/repo  (also https://org@dev.azure.com/...)
  local org, project, name = url:match('https?://[^/]*dev%.azure%.com/([^/]+)/([^/]+)/_git/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  -- ssh: git@ssh.dev.azure.com:v3/org/project/repo
  org, project, name = url:match('ssh%.dev%.azure%.com:v3/([^/]+)/([^/]+)/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  -- legacy: https://org.visualstudio.com/project/_git/repo
  org, project, name = url:match('https?://([^%.]+)%.visualstudio%.com/([^/]+)/_git/(.+)$')
  if org then
    return f('%s/%s/%s', org, project, name)
  end
  return nil
end

local cached_user, cached_user_id

--- Loads the signed-in Azure DevOps profile (displayName + id) via the vssps profile API.
--- Synchronous; cached for the session. No-op if already loaded or not logged in.
local function load_profile()
  if cached_user then
    return
  end
  local pat = get_pat()
  local base = base_url()
  -- On-prem has no vssps profile api; `connectionData` returns the authenticated identity instead.
  -- NB: this endpoint 400s if given an api-version, so request it bare.
  local url = base and (base .. '/_apis/connectionData')
    or with_api('https://app.vssps.visualstudio.com/_apis/profile/profiles/me')
  local cmd, stdin = build_request('get', url, nil, pat)
  local r = vim.system(cmd, { text = true, stdin = stdin }):wait()
  local p, _, code = parse_response(r, pat, false)
  if code == 0 and type(p) == 'table' then
    if base then
      local u = p.authenticatedUser or {}
      cached_user = u.providerDisplayName or u.customDisplayName
      cached_user_id = u.id
    else
      cached_user = p.displayName or p.emailAddress
      cached_user_id = p.id
    end
  end
end

--- @return string? displayName
function M.get_user()
  load_profile()
  return cached_user
end

--- @return string? identity id (for reviewer-vote routes)
function M.get_user_id()
  load_profile()
  return cached_user_id
end

---------------------------------------------------------------------------
-- PR data (metadata + commits + comment threads)
---------------------------------------------------------------------------

--- @param votes integer[] reviewer votes
local function review_decision(votes)
  local approved, rejected = false, false
  for _, v in ipairs(votes) do
    if v == -10 then
      rejected = true
    elseif v == 10 or v == 5 then
      approved = true
    end
  end
  if rejected then
    return 'CHANGES_REQUESTED'
  elseif approved then
    return 'APPROVED'
  end
  return 'REVIEW_REQUIRED'
end

--- Azure thread.status values that mean "resolved" (dropped from the diff view, like gh resolved threads).
local RESOLVED_STATUS = { fixed = true, closed = true, wontFix = true, byDesign = true }

--- Flattens Azure PR threads into the flat `Comment[]` list the UI expects.
---
--- - Drops resolved threads (counts them).
--- - Keeps only file-anchored threads with at least one human ("text") comment — general threads
---   surface in the PR overview, not the diff.
---
--- @return Comment[] comments, integer n_threads, integer n_resolved
local function flatten_threads(threads, web_url)
  local out = {}
  local n_threads, n_resolved = 0, 0
  for _, thread in ipairs((threads or {}).value or {}) do
    local ctx = thread.threadContext
    local text_comments = {}
    for _, c in ipairs(thread.comments or {}) do
      if not c.isDeleted and (c.commentType == nil or c.commentType == 'text' or c.commentType == 'codeChange') then
        table.insert(text_comments, c)
      end
    end
    if ctx and ctx.filePath and #text_comments > 0 then
      n_threads = n_threads + 1
      if RESOLVED_STATUS[thread.status] then
        n_resolved = n_resolved + 1
      else
        local path = (ctx.filePath:gsub('^/', ''))
        local side, start_line, end_line
        if ctx.rightFileStart then
          side = 'RIGHT'
          start_line = ctx.rightFileStart.line
          end_line = (ctx.rightFileEnd or ctx.rightFileStart).line
        elseif ctx.leftFileStart then
          side = 'LEFT'
          start_line = ctx.leftFileStart.line
          end_line = (ctx.leftFileEnd or ctx.leftFileStart).line
        end
        -- Synthetic single-line diff-hunk so threads anchored *off* the current diff
        -- ("outdated"/"outside") still render. Azure returns no hunk snippet like GitHub does.
        local diff_hunk = side == 'LEFT' and f('@@ -%d,1 +0,0 @@\n-', end_line or 0)
          or f('@@ -0,0 +%d,1 @@\n+', end_line or 0)
        if end_line and path then
          local head_id = text_comments[1].id
          for _, c in ipairs(text_comments) do
            local reply_to
            if c.parentCommentId and c.parentCommentId ~= 0 and c.id ~= head_id then
              reply_to = composite_id(thread.id, c.parentCommentId)
            end
            table.insert(out, {
              id = composite_id(thread.id, c.id),
              comment_id = c.id, -- real per-thread id (for REST routes)
              thread_id = thread.id,
              thread_node_id = tostring(thread.id),
              html_url = web_url,
              user = { login = (c.author or {}).displayName or '?' },
              body = c.content or '',
              diff_hunk = diff_hunk,
              path = path,
              start_line = start_line,
              end_line = end_line,
              side = side,
              updated_at = (c.lastUpdatedDate or c.publishedDate or ''):sub(1, 16):gsub('T', ' '),
              in_reply_to_id = reply_to,
              outdated = false,
            })
          end
        end
      end
    end
  end
  return out, n_threads, n_resolved
end

--- Collects general (non-file-anchored) discussion comments for the PR overview.
--- @return { user: string, updated_at: string, body: string }[]
local function general_threads(threads)
  local out = {}
  for _, thread in ipairs((threads or {}).value or {}) do
    if not thread.threadContext and not RESOLVED_STATUS[thread.status] then
      for _, c in ipairs(thread.comments or {}) do
        if not c.isDeleted and (c.commentType == nil or c.commentType == 'text') and vim.trim(c.content or '') ~= '' then
          table.insert(out, {
            user = (c.author or {}).displayName or '?',
            updated_at = (c.lastUpdatedDate or c.publishedDate or ''):sub(1, 16):gsub('T', ' '),
            body = c.content or '',
          })
        end
      end
    end
  end
  return out
end

--- @return PullRequest
local function to_pr(detail, threads, commits_resp, repo)
  local web_url = pr_web_url(repo, detail.pullRequestId)

  local commits = {}
  for _, c in ipairs((commits_resp or {}).value or {}) do
    local msg = c.comment or ''
    table.insert(commits, {
      oid = c.commitId,
      committedDate = ((c.committer or c.author or {}).date or ''),
      messageHeadline = msg:match('^([^\n]*)') or '',
      messageBody = (msg:match('^[^\n]*\n+(.*)$') or ''),
    })
  end

  local votes, reviewers = {}, {}
  for _, r in ipairs(detail.reviewers or {}) do
    table.insert(votes, r.vote or 0)
    table.insert(reviewers, { login = r.displayName, vote = r.vote })
  end

  local raw_comments, n_threads, n_resolved = flatten_threads(threads, web_url)

  return {
    author = { login = (detail.createdBy or {}).displayName },
    baseRefName = (detail.targetRefName or ''):gsub('^refs/heads/', ''),
    baseRefOid = (detail.lastMergeTargetCommit or {}).commitId,
    body = detail.description or '',
    changedFiles = 0,
    commits = commits,
    createdAt = detail.creationDate,
    headRefName = (detail.sourceRefName or ''):gsub('^refs/heads/', ''),
    headRefOid = (detail.lastMergeSourceCommit or {}).commitId,
    isDraft = detail.isDraft or false,
    labels = detail.labels or {},
    number = detail.pullRequestId,
    reviewDecision = review_decision(votes),
    reviews = reviewers,
    status = detail.status,
    title = detail.title,
    url = web_url,
    raw_comments = raw_comments,
    general = general_threads(threads),
    viewed = {}, -- Azure has no reliable per-file "viewed" state via API.
    n_threads = n_threads,
    n_resolved = n_resolved,
  }
end

--- Gets PR data: metadata + commits + comment threads, marshaled into `PullRequest`.
---
--- Mirrors the gh impl's cache contract: caches on the `pr/…` buffer unless `opts.force`.
---
--- @param prnum string|integer
--- @param repo string "org/project/repo"
--- @param opts? { force?: boolean }
--- @param cb fun(pr?: PullRequest)
function M.get_pr_data(prnum, repo, opts, cb)
  vim.validate('repo', repo, 'string')
  opts = opts or {}
  if not opts.force then
    local pr_buf = state.get_buf('pr', repo, prnum, false)
    local pr_data = pr_buf and (vim.b[pr_buf].azdo or {}).pr_data
    if pr_data then
      return cb(pr_data)
    end
  end
  local base = repo_base(repo)
  if not base then
    util.log('get_pr_data invalid repo', repo)
    return cb(nil)
  end

  local detail, threads, commits, pending = nil, nil, nil, 3
  local failed = false
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    if failed or not detail then
      return cb(nil)
    end
    local pr = to_pr(detail, threads, commits, repo)
    state.set_b_azdo(assert(state.get_buf('pr', repo, prnum)), { pr_data = pr })
    util.log('get_pr_data ok', { comments = #pr.raw_comments, commits = #pr.commits })
    cb(pr)
  end

  az_rest('get', with_api(f('%s/pullRequests/%s', base, prnum)), nil, function(resp, _, code)
    if code ~= 0 or not resp then
      failed = true
    else
      detail = resp
    end
    done()
  end)
  az_rest('get', with_api(f('%s/pullRequests/%s/threads', base, prnum)), nil, function(resp)
    threads = resp or {}
    done()
  end)
  az_rest('get', with_api(f('%s/pullRequests/%s/commits', base, prnum)), nil, function(resp)
    commits = resp or {}
    done()
  end)
end

--- Probes whether `id` is a PR in `repo` (else treat as a work item). @param cb fun(is_pr: boolean)
function M.probe_is_pr(repo, id, cb)
  az_rest('get', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), nil, function(_, _, code)
    cb(code == 0)
  end)
end

---------------------------------------------------------------------------
-- Comment write actions
---------------------------------------------------------------------------

--- Replies to a thread. `reply_to` is the composite id of any comment in the thread.
function M.reply_to_comment(prnum, body, reply_to, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, parent = decode_id(reply_to)
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments', repo_base(repo), prnum, thread_id))
  az_write('reply_to_comment', 'post', url, { content = body, parentCommentId = parent, commentType = 1 }, cb)
end

--- Creates a new file-anchored comment thread.
function M.new_comment(pr, body, path, start_line, line, side, repo, cb)
  vim.validate('repo', repo, 'string')
  side = side or 'RIGHT'
  local anchor = side == 'LEFT' and 'leftFile' or 'rightFile'
  local thread_context = {
    filePath = '/' .. path:gsub('^/', ''),
    [anchor .. 'Start'] = { line = start_line, offset = 1 },
    [anchor .. 'End'] = { line = line, offset = 1 },
  }
  local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), pr.number))
  az_write('new_comment', 'post', url, {
    comments = { { content = body, commentType = 1 } },
    status = 1, -- active
    threadContext = thread_context,
  }, cb)
end

--- Posts a top-level (non-file-anchored) comment on a PR, or a work-item discussion comment.
--- @param kind 'pr'|'issue'
--- @param cb fun(ok: boolean, stderr?: string)
function M.new_overview_comment(kind, id, repo, body, cb)
  if kind == 'issue' then
    local url = with_api(f('%s/wit/workItems/%s/comments', project_base(repo), id))
    return az_rest('post', url, { text = body }, function(_, stderr, code)
      cb(code == 0, stderr)
    end)
  end
  local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), id))
  az_rest('post', url, { comments = { { content = body, commentType = 1 } }, status = 1 }, function(_, stderr, code)
    cb(code == 0, stderr)
  end)
end

function M.update_comment(comment_id, body, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, cid = decode_id(comment_id)
  local prnum = (vim.b.azdo or {}).id
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments/%d', repo_base(repo), prnum, thread_id, cid))
  az_write('update_comment', 'patch', url, { content = body }, cb)
end

function M.delete_comment(comment_id, repo, cb)
  vim.validate('repo', repo, 'string')
  local thread_id, cid = decode_id(comment_id)
  local prnum = (vim.b.azdo or {}).id
  local url = with_api(f('%s/pullRequests/%s/threads/%d/comments/%d', repo_base(repo), prnum, thread_id, cid))
  az_write('delete_comment', 'delete', url, nil, cb)
end

--- Resolves a comment thread (sets status=closed). `thread_node_id` is the Azure thread id (string).
function M.resolve_thread(thread_node_id, cb)
  vim.validate('thread_node_id', thread_node_id, 'string')
  local b = vim.b.azdo or {}
  local repo, prnum = b.repo, b.id
  if not repo or not prnum then
    return cb({ errors = { 'not in an azdo:// buffer' } })
  end
  local url = with_api(f('%s/pullRequests/%s/threads/%s', repo_base(repo), prnum, thread_node_id))
  -- status 4 = closed (resolved).
  az_write('resolve_thread', 'patch', url, { status = 4 }, cb)
end

---------------------------------------------------------------------------
-- PR-level actions: review (vote), merge (complete)
---------------------------------------------------------------------------

--- Submits a review by setting the signed-in user's reviewer vote (+ optional comment thread).
--- @param action 'approve'|'request-changes'|'comment'
--- @param cb fun(ok: boolean, stderr: string)
function M.review_pr(id, repo, action, body, cb)
  vim.validate('repo', repo, 'string')
  local uid = M.get_user_id()
  if not uid then
    return cb(false, 'Not authenticated (run `az login`, or set a PAT via setup{ pat = … } / $AZDO_PAT)')
  end
  local vote = (action == 'approve' and 10) or (action == 'request-changes' and -10) or 0
  local function set_vote()
    local url = with_api(f('%s/pullRequests/%s/reviewers/%s', repo_base(repo), id, uid))
    az_rest('put', url, { vote = vote }, function(_, stderr, code)
      cb(code == 0, stderr or '')
    end)
  end
  -- For comment/request-changes with a body, post the body as a general thread first.
  if body and body ~= '' and action ~= 'approve' then
    local url = with_api(f('%s/pullRequests/%s/threads', repo_base(repo), id))
    az_rest('post', url, { comments = { { content = body, commentType = 1 } }, status = 1 }, set_vote)
  else
    set_vote()
  end
end

--- Completes (merges) a PR.
--- @param method 'merge'|'squash'|'rebase'
--- @param cb fun(ok: boolean, stderr: string)
function M.merge_pr(id, repo, method, subject, body, admin, cb)
  vim.validate('id', id, 'number')
  vim.validate('repo', repo, 'string')
  local strategy = (method == 'squash' and 'squash') or (method == 'rebase' and 'rebase') or 'noFastForward'
  -- Need the source commit id to complete; fetch fresh PR detail.
  az_rest('get', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), nil, function(detail, stderr, code)
    if code ~= 0 or not detail then
      return cb(false, stderr or 'failed to load PR')
    end
    local completion = {
      mergeStrategy = strategy,
      deleteSourceBranch = false,
      bypassPolicy = admin or false,
    }
    if admin then
      completion.bypassReason = 'azdo.nvim --admin'
    end
    if method ~= 'rebase' and subject and subject ~= '' then
      completion.mergeCommitMessage = vim.trim(subject .. '\n\n' .. (body or ''))
    end
    local payload = {
      status = 'completed',
      lastMergeSourceCommit = { commitId = (detail.lastMergeSourceCommit or {}).commitId },
      completionOptions = completion,
    }
    az_rest('patch', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), payload, function(_, e, c)
      cb(c == 0, e or '')
    end)
  end)
end

--- Patches PR properties (e.g. `{ title = ..., description = ... }`).
--- @param cb fun(ok: boolean, stderr: string)
function M.update_pr(id, repo, fields, cb)
  vim.validate('repo', repo, 'string')
  az_rest('patch', with_api(f('%s/pullRequests/%s', repo_base(repo), id)), fields, function(_, stderr, code)
    cb(code == 0, stderr or '')
  end)
end

--- Creates a PR from `source` -> `target` branch (short names, no `refs/heads/`).
--- The source branch must already be pushed to the remote, or the API rejects it.
--- @param cb fun(id: integer?, stderr: string) `id` is the new pullRequestId on success.
function M.create_pr(repo, source, target, title, description, cb)
  vim.validate('repo', repo, 'string')
  local body = {
    sourceRefName = 'refs/heads/' .. source,
    targetRefName = 'refs/heads/' .. target,
    title = title,
    description = description,
  }
  az_rest('post', with_api(f('%s/pullRequests', repo_base(repo))), body, function(resp, stderr, code)
    if code ~= 0 or not resp or not resp.pullRequestId then
      return cb(nil, stderr or 'failed to create PR')
    end
    cb(resp.pullRequestId, '')
  end)
end

--- Human-facing web url for a PR (public wrapper around the internal builder).
--- @return string
function M.pr_web_url(repo, id)
  return pr_web_url(repo, id)
end

--- Human-facing web url for a work item. Project-scoped, so it respects on-prem
--- `azdo_base_url` (the repo segment is unused). `repo` is "org/project/<anything>".
--- @return string
function M.wi_web_url(repo, id)
  local org, project = parse_repo(repo)
  return f('%s/%s/_workitems/edit/%s', collection_base(org), urlencode(project), id)
end

---------------------------------------------------------------------------
-- Diff + commit (local git; Azure has no unified-diff REST endpoint)
---------------------------------------------------------------------------

--- Produces a git unified diff for a PR by fetching the Azure refs and diffing
--- merge-base(target, source)..source. Requires a local clone whose `origin` is this repo.
---
--- @param pr PullRequest
--- @param cb fun(diff?: string, err?: string)
function M.get_pr_diff(repo, pr, cb)
  local id = pr.number
  -- argv, never `sh -c`: branch names come from the PR author and are only
  -- constrained by git's ref rules, which permit `$(…)`, backticks and `|`. Run
  -- through a shell and reading a hostile PR's diff would execute it.
  local fetch = {
    'git',
    'fetch',
    '--no-tags',
    '--quiet',
    'origin',
    f('refs/pull/%s/merge', id),
    pr.headRefName,
    pr.baseRefName,
  }
  -- The fetch is best-effort — the refs are often already local, and a failure
  -- here (deleted source branch, no network) still leaves a diffable pair. So the
  -- diff runs regardless, exactly as the old `;`-joined script did.
  util.system(fetch, function()
    local diff = { 'git', 'diff', '--no-color', f('%s...%s', pr.baseRefOid or 'HEAD', pr.headRefOid or 'HEAD') }
    util.system(diff, function(stdout, stderr, code)
      if code ~= 0 or vim.trim(stdout or '') == '' then
        return cb(nil, vim.trim(stderr or 'git diff failed (is the cwd a local clone of the PR repo?)'))
      end
      cb(stdout)
    end)
  end)
end

--- Shows a commit as a patch (via local `git show`).
--- @param cb fun(patch?: string, err?: string)
function M.get_commit(repo, sha, cb)
  -- argv, never `sh -c` — see get_pr_diff. `sha` reaches here from :Azdo arguments
  -- and from API payloads, so it is not guaranteed to be bare hex.
  util.system({ 'git', 'fetch', '--no-tags', '--quiet', 'origin', sha }, function()
    util.system({ 'git', 'show', '--no-color', sha }, function(stdout, stderr, code)
      if code ~= 0 or vim.trim(stdout or '') == '' then
        return cb(nil, vim.trim(stderr or 'git show failed'))
      end
      cb(stdout)
    end)
  end)
end

---------------------------------------------------------------------------
-- Status (list of open PRs)
---------------------------------------------------------------------------

--- @param cb fun(prs?: { number: integer, title: string, isDraft: boolean, status: string }[], err?: string)
function M.list_prs(repo, cb)
  local url = with_api(f('%s/pullRequests', repo_base(repo)), 'searchCriteria.status=active&$top=50')
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr)
    end
    local prs = {}
    for _, p in ipairs(resp.value or {}) do
      table.insert(prs, { number = p.pullRequestId, title = p.title, isDraft = p.isDraft, status = p.status })
    end
    cb(prs)
  end)
end

---------------------------------------------------------------------------
-- Work items ("issues")
---------------------------------------------------------------------------

--- @param cb fun(wi?: table, err?: string)
function M.get_workitem(repo, id, cb)
  local url = with_api(f('%s/wit/workItems/%s', project_base(repo), id), '$expand=all')
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr)
    end
    cb(resp)
  end)
end

--- Batch-fetches display fields for up to 200 work-item ids. `errorPolicy=omit` so a
--- since-deleted id drops out instead of failing the whole batch (tagged items may vanish).
--- @param ids integer[]
--- @param cb fun(items?: {id:integer, title:string, type:string, state:string, assignee:string, created:string, changed:string}[], err?: string)
local function fetch_workitem_fields(repo, ids, cb)
  if #ids == 0 then
    return cb({})
  end
  local capped = {}
  for i = 1, math.min(#ids, 200) do
    capped[i] = ids[i]
  end
  local extra = ('ids=%s&fields=System.Id,System.Title,System.WorkItemType,System.State,System.AssignedTo,System.CreatedDate,System.ChangedDate&errorPolicy=omit'):format(
    table.concat(capped, ',')
  )
  az_rest('get', with_api(f('%s/wit/workitems', project_base(repo)), extra), nil, function(batch, berr, bcode)
    if bcode ~= 0 or not batch then
      return cb(nil, berr or 'failed to load work items')
    end
    local items = {}
    for _, wi in ipairs(batch.value or {}) do
      local fld = wi.fields or {}
      local a = fld['System.AssignedTo']
      items[#items + 1] = {
        id = wi.id,
        title = fld['System.Title'] or '',
        type = fld['System.WorkItemType'] or 'Work Item',
        state = fld['System.State'] or '',
        assignee = (type(a) == 'table' and (a.displayName or a.uniqueName)) or a or 'Unassigned',
        -- ISO-8601 timestamps; sort lexicographically (azdo.pr sort feature).
        created = fld['System.CreatedDate'] or '',
        changed = fld['System.ChangedDate'] or '',
      }
    end
    cb(items)
  end)
end

--- Updates work-item fields via a JSON-patch PATCH. `fields` is a map of
--- reference-name -> value (HTML for rich-text fields, plain string for others).
--- A no-op (empty `fields`) succeeds without a request.
--- @param fields table<string, string>
--- @param cb fun(ok: boolean, stderr: string)
function M.update_workitem(repo, id, fields, cb)
  local patch = {}
  for ref, val in pairs(fields) do
    patch[#patch + 1] = { op = 'add', path = '/fields/' .. ref, value = val }
  end
  if #patch == 0 then
    return cb(true, '')
  end
  local url = with_api(f('%s/wit/workItems/%s', project_base(repo), id))
  az_rest('patch', url, patch, function(_, perr, pcode)
    cb(pcode == 0, perr or '')
  end, 'application/json-patch+json')
end

--- Fetches display fields for an explicit list of work-item ids (e.g. tagged items).
--- @param ids integer[]
--- @param cb fun(items?: {id:integer, title:string, type:string, state:string, assignee:string, created:string, changed:string}[], err?: string)
function M.get_workitems(repo, ids, cb)
  fetch_workitem_fields(repo, ids, cb)
end

--- Lists the valid states for a work-item type, in the type's own workflow order
--- (which Azure returns "backlog → done"). Used by the dashboard's set-state picker.
--- @param wtype string work-item type name, e.g. "Product Backlog Item"
--- @param cb fun(states?: {name:string, category:string}[], err?: string)
function M.get_workitem_states(repo, wtype, cb)
  local url = with_api(f('%s/wit/workitemtypes/%s/states', project_base(repo), urlencode(wtype)))
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr or 'failed to load states')
    end
    local states = {}
    for _, s in ipairs(resp.value or {}) do
      states[#states + 1] = { name = s.name, category = s.stateCategory or '' }
    end
    cb(states)
  end)
end

--- Builds the WIQL `[System.AssignedTo]` clause for an assignee filter:
---   nil / 'me' → assigned to the authenticated user (`= @Me`)
---   'all'      → no clause (everyone's items)
---   a string   → that one person (matched on display name or unique name)
---   a list     → any of those people (OR'd)
--- Single quotes in names are WIQL-escaped (doubled). Returns a clause that
--- starts with "AND " (or "" for 'all'), ready to splice after the State filters.
--- @param assignee nil|string|string[]
--- @return string
local function assigned_to_clause(assignee)
  if assignee == nil or assignee == 'me' then
    return 'AND [System.AssignedTo] = @Me '
  end
  if assignee == 'all' then
    return ''
  end
  local people = type(assignee) == 'table' and assignee or { assignee }
  local ors = {}
  for _, name in ipairs(people) do
    if type(name) == 'string' and name ~= '' then
      ors[#ors + 1] = ("[System.AssignedTo] = '%s'"):format(name:gsub("'", "''"))
    end
  end
  if #ors == 0 then -- empty list → fall back to "mine"
    return 'AND [System.AssignedTo] = @Me '
  end
  return 'AND (' .. table.concat(ors, ' OR ') .. ') '
end

--- Lists active work items (not Closed/Removed) for the given assignee filter,
--- newest-changed first. Runs a WIQL query for ids, then a batch fetch for
--- display fields. See `assigned_to_clause` for the accepted `assignee` shapes.
--- @param assignee nil|string|string[] who to list (nil/'me' = the signed-in user)
--- @param cb fun(items?: {id:integer, title:string, type:string, state:string, assignee:string, created:string, changed:string}[], err?: string)
function M.list_workitems(repo, assignee, cb)
  local wiql = {
    query = "SELECT [System.Id] FROM WorkItems WHERE [System.State] <> 'Closed' "
      .. "AND [System.State] <> 'Removed' "
      .. assigned_to_clause(assignee)
      .. 'ORDER BY [System.ChangedDate] DESC',
  }
  -- Bound the result server-side with `$top`. Without it, an unfiltered query
  -- (assignee = 'all') returns *every* active item in the project — a slow,
  -- huge response — only for us to discard all but the first 200 anyway (the
  -- `ids=` batch fetch caps at 200). `$top` moves that cap to the server.
  local url = with_api(f('%s/wit/wiql', project_base(repo)), '$top=200')
  az_rest('post', url, wiql, function(resp, stderr, code)
    if code ~= 0 or not resp then
      return cb(nil, stderr or 'WIQL query failed')
    end
    local ids = {}
    for _, w in ipairs(resp.workItems or {}) do
      ids[#ids + 1] = w.id
      if #ids >= 200 then -- `ids=` batch fetch caps at 200
        break
      end
    end
    fetch_workitem_fields(repo, ids, cb)
  end)
end

--- Lists work items assigned to the authenticated user. Thin wrapper over
--- `list_workitems` kept for callers/back-compat.
--- @param cb fun(items?: table[], err?: string)
function M.list_my_workitems(repo, cb)
  return M.list_workitems(repo, 'me', cb)
end

--- The distinct assignees on the project's active work items, A→Z (for the
--- dashboard's assignee-filter picker). Derived from the same active-items query
--- as the dashboard, so it's capped at 200 items — a roster of who's currently
--- working, not the full directory. "Unassigned" is dropped.
--- @param cb fun(names?: string[], err?: string)
function M.list_assignees(repo, cb)
  M.list_workitems(repo, 'all', function(items, err)
    if not items then
      return cb(nil, err)
    end
    local seen, names = {}, {}
    for _, wi in ipairs(items) do
      local a = wi.assignee
      if a and a ~= '' and a ~= 'Unassigned' and not seen[a] then
        seen[a] = true
        names[#names + 1] = a
      end
    end
    table.sort(names, function(x, y)
      return x:lower() < y:lower()
    end)
    cb(names)
  end)
end

--- Links work item `wi_id` to PR `pr_id` by adding an ArtifactLink relation to the work item.
--- The PR's project/repo GUIDs (needed for the `vstfs://` artifact URI) are read from PR detail.
--- @param cb fun(ok: boolean, stderr: string)
function M.link_workitem(repo, pr_id, wi_id, cb)
  az_rest('get', with_api(f('%s/pullRequests/%s', repo_base(repo), pr_id)), nil, function(detail, stderr, code)
    if code ~= 0 or not detail or not detail.repository then
      return cb(false, stderr or 'failed to load PR')
    end
    local repo_guid = detail.repository.id
    local proj_guid = (detail.repository.project or {}).id
    if not repo_guid or not proj_guid then
      return cb(false, 'could not resolve project/repo id from PR')
    end
    -- vstfs:///Git/PullRequestId/<projectGuid>%2F<repoGuid>%2F<prId> (the %2F are literal in the URI).
    local artifact = ('vstfs:///Git/PullRequestId/%s%%2F%s%%2F%s'):format(proj_guid, repo_guid, pr_id)
    local patch = {
      {
        op = 'add',
        path = '/relations/-',
        value = { rel = 'ArtifactLink', url = artifact, attributes = { name = 'Pull Request' } },
      },
    }
    local url = with_api(f('%s/wit/workItems/%s', project_base(repo), wi_id))
    az_rest('patch', url, patch, function(_, perr, pcode)
      cb(pcode == 0, perr or '')
    end, 'application/json-patch+json')
  end)
end

---------------------------------------------------------------------------
-- CI / Pipelines
---------------------------------------------------------------------------

--- Lists pipeline-build jobs for the latest build on the PR's merge ref.
--- `databaseId` encodes `buildId * MULT + logId` for `get_pr_ci_logs`.
---
--- @param pr PullRequest
--- @param cb fun(jobs?: table[], error?: string)
function M.get_pr_ci_jobs_logs(pr, repo, cb)
  local progress = util.new_progress_report('Loading CI builds', 0)
  progress('running')
  local pbase = project_base(repo)
  local url = with_api(
    f('%s/build/builds', pbase),
    f('branchName=refs/pull/%s/merge&$top=5&queryOrder=finishTimeDescending', pr.number)
  )
  az_rest('get', url, nil, function(resp, stderr, code)
    if code ~= 0 or not resp or #(resp.value or {}) == 0 then
      progress('failed')
      return cb(nil, vim.trim(stderr or '') ~= '' and stderr or f('No pipeline builds for PR #%s', pr.number))
    end
    local build = resp.value[1] -- latest
    az_rest('get', with_api(f('%s/build/builds/%s/timeline', pbase, build.id)), nil, function(tl, terr, tcode)
      if tcode ~= 0 or not tl then
        progress('failed')
        return cb(nil, terr)
      end
      local jobs = {}
      for _, rec in ipairs(tl.records or {}) do
        if (rec.type == 'Job' or rec.type == 'Task') and rec.log and rec.log.id then
          table.insert(jobs, {
            databaseId = build.id * COMMENT_MULT + rec.log.id,
            name = rec.name,
            conclusion = rec.result,
            status = rec.state,
            startedAt = rec.startTime or '',
            url = build._links and build._links.web and build._links.web.href,
          })
        end
      end
      if #jobs == 0 then
        progress('failed')
        return cb(nil, f('No logs for build %s', build.id))
      end
      table.sort(jobs, function(a, b)
        local as, bs = a.conclusion or a.status or '?', b.conclusion or b.status or '?'
        if as ~= bs then
          return as < bs
        end
        return (a.name or '') < (b.name or '')
      end)
      progress('success')
      cb(jobs)
    end)
  end)
end

--- @param job_id integer encodes `buildId * MULT + logId`.
--- @param cb fun(log?: string, error?: string)
function M.get_pr_ci_logs(job_id, repo, cb)
  local progress = util.new_progress_report('Loading CI log', 0)
  progress('running')
  local build_id, log_id = decode_id(job_id)
  -- The logs endpoint returns plain text, not JSON; fetch raw (Accept: */*).
  local url = with_api(f('%s/build/builds/%d/logs/%d', project_base(repo), build_id, log_id))
  local pat = get_pat()
  local cmd, stdin = build_request('get', url, nil, pat, true)
  vim.system(cmd, { text = true, stdin = stdin }, vim.schedule_wrap(function(r)
    local raw, stderr, code = parse_response(r, pat, true)
    if code ~= 0 or vim.trim(raw or '') == '' then
      progress('failed')
      return cb(nil, vim.trim(stderr ~= '' and stderr or 'log unavailable'))
    end
    progress('success')
    cb(vim.trim(raw))
  end))
end

return M
