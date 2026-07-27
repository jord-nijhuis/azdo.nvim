-- Self-contained tests for azdo.nvim's pure logic (no network, no Neovim source build).
-- Run with:  nvim -l test/az_spec.lua   (or `make test`)
--
-- These cover the provider-specific parsing that everything else depends on: remote-url parsing,
-- :Azdo argument parsing, and the buffer-uri <-> key roundtrip. The REST/diff layers require a live
-- Azure DevOps org and are exercised manually (see README "Manual smoke test").

vim.opt.runtimepath:append(vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, 'S').source:sub(2)), ':h:h'))

local az = require('azdo.az')
local util = require('azdo.util')
local config = require('azdo.config')

local n_fail = 0
local function check(label, got, want)
  local g, w = vim.inspect(got), vim.inspect(want)
  if g ~= w then
    n_fail = n_fail + 1
    io.write(('not ok - %s\n   got:  %s\n   want: %s\n'):format(label, g, w))
  else
    io.write(('ok - %s\n'):format(label))
  end
end

-- parse_remote: every Azure DevOps remote-url shape resolves to "org/project/repo".
check('remote https', az.parse_remote('https://dev.azure.com/myorg/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check('remote https .git', az.parse_remote('https://dev.azure.com/myorg/MyProj/_git/myrepo.git'), 'myorg/MyProj/myrepo')
check('remote org@host', az.parse_remote('https://myorg@dev.azure.com/myorg/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check('remote ssh', az.parse_remote('git@ssh.dev.azure.com:v3/myorg/MyProj/myrepo'), 'myorg/MyProj/myrepo')
check('remote visualstudio.com', az.parse_remote('https://myorg.visualstudio.com/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')
check(
  'remote legacy ssh',
  az.parse_remote('myorg@vs-ssh.visualstudio.com:v3/myorg/MyProj/myrepo'),
  'myorg/MyProj/myrepo'
)
check(
  'remote legacy ssh .git',
  az.parse_remote('myorg@vs-ssh.visualstudio.com:v3/myorg/MyProj/myrepo.git'),
  'myorg/MyProj/myrepo'
)
check('remote non-azure', az.parse_remote('https://github.com/owner/repo'), nil)

-- parse_remote: on-prem Azure DevOps Server (base_url configured). org token = collection name.
config.setup({ base_url = 'https://tfs.example.com/tfs/MyCollection' })
check('remote on-prem', az.parse_remote('https://tfs.example.com/tfs/MyCollection/MyProj/_git/myrepo'), 'MyCollection/MyProj/myrepo')
check('remote on-prem .git', az.parse_remote('https://tfs.example.com/tfs/MyCollection/MyProj/_git/myrepo.git'), 'MyCollection/MyProj/myrepo')
check('remote on-prem user@host', az.parse_remote('https://me@tfs.example.com/tfs/MyCollection/MyProj/_git/myrepo'), 'MyCollection/MyProj/myrepo')
check('remote on-prem ssh', az.parse_remote('ssh://tfs.example.com:22/tfs/MyCollection/MyProj/_git/myrepo'), 'MyCollection/MyProj/myrepo')
config.setup({ base_url = 'https://tfs.example.com/tfs/MyCollection/' }) -- trailing slash tolerated
check('remote on-prem trailing /', az.parse_remote('https://tfs.example.com/tfs/MyCollection/MyProj/_git/myrepo'), 'MyCollection/MyProj/myrepo')
config.setup({}) -- reset to defaults (base_url = nil)
-- cloud parsing still works once the on-prem base is unset
check('remote cloud after on-prem', az.parse_remote('https://dev.azure.com/myorg/MyProj/_git/myrepo'), 'myorg/MyProj/myrepo')

-- parse_target: URLs, azdo:// URIs, slugs, bare ids/shas.
local pt = util.parse_target
check('pr url', pt('https://dev.azure.com/o/p/_git/r/pullrequest/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('commit url', pt('https://dev.azure.com/o/p/_git/r/commit/a1b2c3d'), { repo = 'o/p/r', sha = 'a1b2c3d' })
check('workitem url', pt('https://dev.azure.com/o/p/_workitems/edit/99'), { id = 99, is_pr = false })
check('repo url', pt('https://dev.azure.com/o/p/_git/r'), { repo = 'o/p/r' })
check('uri pr', pt('azdo://o/p/r/pr/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('uri prdiff', pt('azdo://o/p/r/prdiff/42'), { repo = 'o/p/r', id = 42, is_pr = true })
check('uri issue', pt('azdo://o/p/r/issue/7'), { repo = 'o/p/r', id = 7 })
check('uri commit', pt('azdo://o/p/r/commit/abc1234'), { repo = 'o/p/r', sha = 'abc1234' })
check('uri status', pt('azdo://status'), {})
check('slug#id', pt('o/p/r#42'), { repo = 'o/p/r', id = 42 })
check('slug', pt('o/p/r'), { repo = 'o/p/r' })
check('#id', pt('#42'), { id = 42 })
check('bare num', pt('42'), { id = 42 })
check('bare sha', pt('a1b2c3d'), { sha = 'a1b2c3d' })
check('garbage', pt('???'), nil)

-- Branch names from work items: "<type>/<id>-<slug>". Bug maps to fix, Task to chore, and every
-- backlog type to feat; the slug is cut at a word boundary so the tail doesn't read as a typo.
local bn = require('azdo.pr')._branch_name
check('branch pbi', bn(11, 'Product Backlog Item', 'User auth'), 'feat/11-user-auth')
check('branch bug', bn(123, 'Bug', 'Login redirect fails'), 'fix/123-login-redirect-fails')
check('branch task', bn(7, 'Task', 'Bump deps'), 'chore/7-bump-deps')
check('branch feature', bn(9, 'Feature', 'Prometheus metrics'), 'feat/9-prometheus-metrics')
check('branch unknown type', bn(1, 'Epic', 'Big thing'), 'feat/1-big-thing')
check('branch punctuation', bn(5, 'Bug', "Don't crash on `null` (again)!"), 'fix/5-dont-crash-on-null-again')
check('branch no title', bn(42, 'Bug', ''), 'fix/42')
-- 37 chars of slug: "forty" would push it past the 40-char limit, so the whole word is dropped
-- rather than cut mid-word.
check(
  'branch truncates on a word boundary',
  bn(3, 'Bug', 'this title is quite a lot longer than forty characters in total'),
  'fix/3-this-title-is-quite-a-lot-longer-than'
)
-- A single word longer than the limit has no boundary to fall back to, so it is cut hard.
check('branch hard-cuts one long word', bn(4, 'Bug', ('x'):rep(60)), 'fix/4-' .. ('x'):rep(40))

-- Worktree porcelain: `checkout` reuses an existing worktree for the PR's branch rather than failing
-- to create a second one, so mis-parsing this silently breaks reuse. The first entry is the main
-- worktree; a detached entry has no branch line.
local pw = require('azdo.pr')._parse_worktrees
check('worktrees: main only', pw('worktree /repo\nHEAD abc\nbranch refs/heads/main\n'), {
  { path = '/repo', branch = 'main' },
})
check(
  'worktrees: linked + detached',
  pw(
    'worktree /repo\nHEAD abc\nbranch refs/heads/main\n\n'
      .. 'worktree /repo/.claude/worktrees/pr-42\nHEAD def\nbranch refs/heads/feature/their-work\n\n'
      .. 'worktree /repo/.claude/worktrees/pr-9\nHEAD 123\ndetached\n'
  ),
  {
    { path = '/repo', branch = 'main' },
    { path = '/repo/.claude/worktrees/pr-42', branch = 'feature/their-work' },
    { path = '/repo/.claude/worktrees/pr-9' },
  }
)
check('worktrees: empty', pw(''), {})

-- Pipeline folders: Azure DevOps stores the path Windows-style, and the folder is what distinguishes
-- same-named pipelines ("CI", "PR Review") across repos in one project.
check('pipeline folder root', az.pipeline_folder('\\'), '')
check('pipeline folder empty', az.pipeline_folder(nil), '')
check('pipeline folder flat', az.pipeline_folder('\\Backend'), 'Backend')
check('pipeline folder nested', az.pipeline_folder('\\Devops\\Nightly'), 'Devops/Nightly')
check('pipeline folder trailing', az.pipeline_folder('\\Backend\\'), 'Backend')

--- Runs `fn` with the cwd inside a throwaway git repo, then cleans up.
local function in_temp_repo(fn)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local cwd = vim.uv.cwd()
  vim.uv.chdir(dir)
  vim.system({ 'git', 'init', '-q', '.' }):wait()
  vim.system({ 'git', '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'i' }):wait()
  local ok, err = pcall(fn, dir)
  vim.uv.chdir(cwd)
  vim.fn.delete(dir, 'rf')
  if not ok then
    error(err)
  end
end

-- Credentials are never sourced from the environment unless explicitly opted in: a var exported for
-- the `az devops` CLI must not silently decide which identity the editor authenticates as.
check('pat_from_env defaults off', config.options.pat_from_env, false)

-- PRs open as drafts, and a repo's PR template prefills the description. Publishing on create
-- notifies every reviewer, and an empty description silently skips a checklist reviewers expect.
check('create_draft defaults on', config.options.create_draft, true)
check('create_template defaults on', config.options.create_template, true)

local pr = require('azdo.pr')
in_temp_repo(function(dir)
  check('no template, no repo template', pr._read_pr_template(), nil)

  vim.fn.mkdir(dir .. '/.azuredevops', 'p')
  vim.fn.writefile({ '### What has changed?', '', '- [ ] Tests added' }, dir .. '/.azuredevops/pull_request_template.md')
  check('finds .azuredevops template', pr._read_pr_template(), { '### What has changed?', '', '- [ ] Tests added' })

  -- .azuredevops wins: it is the location Azure DevOps itself checks first.
  vim.fn.mkdir(dir .. '/docs', 'p')
  vim.fn.writefile({ 'docs one' }, dir .. '/docs/pull_request_template.md')
  check('search order prefers .azuredevops', pr._read_pr_template()[1], '### What has changed?')

  vim.fn.delete(dir .. '/.azuredevops', 'rf')
  check('falls back to docs/', pr._read_pr_template(), { 'docs one' })

  config.setup({ create_template = false })
  check('create_template = false opts out', pr._read_pr_template(), nil)
  config.setup({})
end)

-- get_pr_diff / get_commit shell out to git. Branch names come from whoever opened the PR and git's
-- ref rules permit `$(…)`, backticks and `|`, so passing them through a shell turns "read a PR's
-- diff" into arbitrary code execution. These drive the real functions against a throwaway repo and
-- assert the payload did not run.
in_temp_repo(function(dir)
  local marker = dir .. '/pwned'
  local done = false
  az.get_pr_diff('o/p/r', {
    number = 1,
    headRefName = 'feature/x$(touch ' .. marker .. ')',
    baseRefName = 'main',
    baseRefOid = 'HEAD',
    headRefOid = 'HEAD',
  }, function()
    done = true
  end)
  vim.wait(15000, function()
    return done
  end, 50)
  check('get_pr_diff does not execute branch names', vim.uv.fs_stat(marker) ~= nil, false)
end)

in_temp_repo(function(dir)
  local marker = dir .. '/pwned'
  local done = false
  az.get_commit('o/p/r', 'HEAD$(touch ' .. marker .. ')', function()
    done = true
  end)
  vim.wait(15000, function()
    return done
  end, 50)
  check('get_commit does not execute the sha', vim.uv.fs_stat(marker) ~= nil, false)
end)

if n_fail > 0 then
  io.write(('\n%d test(s) FAILED\n'):format(n_fail))
  os.exit(1)
end
io.write('\nall tests passed\n')
