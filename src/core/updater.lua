-- Optional self-update check for the CLI: compares the checkout against origin/main
-- and, on request, fast-forwards. Any error is a silent no-op, and a dirty or
-- diverged tree refuses the update rather than discarding local work.

local Updater = {}

local IS_WIN = package.config:sub(1, 1) == "\\"
local NULDEV = IS_WIN and "NUL" or "/dev/null"

-- Repo root the git commands operate on (via `git -C`), so the updater works no
-- matter what working directory VSCode / a task runner launches the CLI from.
local repo_root = "."
function Updater.configure(root)
    if type(root) == "string" and root ~= "" then repo_root = root end
end

-- Force git to be non-interactive so an auth prompt on a private remote can't hang
-- the CLI; git fails fast instead and the failure becomes a no-op.
local function env_prefix()
    if IS_WIN then
        return 'set "GIT_TERMINAL_PROMPT=0" && set "GCM_INTERACTIVE=never" && '
    end
    return "GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "
end

-- Config flags applied to every git call: never open a credential UI, and abort a
-- transfer that stalls below ~1 KB/s for 8s so a slow network can't hang the build.
local GIT_FLAGS = '-c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8'

-- Run `git <args>` against the repo root, returning trimmed stdout (stderr
-- discarded), or nil if git could not run. Never raises and never blocks on input.
local function git(args)
    local ok, result = pcall(function()
        local cmd = env_prefix() .. 'git -C "' .. repo_root .. '" ' .. GIT_FLAGS .. " " .. args .. " 2>" .. NULDEV
        local handle = io.popen(cmd)
        if not handle then return nil end
        local out = handle:read("*a") or ""
        handle:close()
        return (out:gsub("%s+$", ""))
    end)
    if ok then return result end
    return nil
end

local function is_git_repo()
    return git("rev-parse --is-inside-work-tree") == "true"
end

local function origin_is_github()
    local url = git("remote get-url origin")
    return type(url) == "string" and url:find("github%.com") ~= nil, url
end

-- true when the working tree (or index) has uncommitted changes. A lone submodule
-- gitlink change (vendor/Fiu) is ignored so it never blocks an otherwise-clean tree.
local function is_dirty()
    local status = git("status --porcelain --untracked-files=no")
    if type(status) ~= "string" or status == "" then return false end
    for line in (status .. "\n"):gmatch("(.-)\n") do
        local path = line:match("^..%s+(.+)$")
        if line ~= "" and path ~= "vendor/Fiu" then return true end
    end
    return false
end

-- How many commits origin/main is ahead of HEAD (behind) and HEAD is ahead of
-- origin/main (ahead). Returns nil if it cannot be determined.
local function behind_ahead()
    local counts = git("rev-list --left-right --count origin/main...HEAD")
    if type(counts) ~= "string" then return nil end
    local behind, ahead = counts:match("^(%d+)%s+(%d+)$")
    if not behind then return nil end
    return tonumber(behind), tonumber(ahead)
end

-- Fetch quietly and report whether the checkout is behind origin/main. Returns
-- { behind, ahead, current, latest } when behind, else nil. Offline just falls back
-- to the last-known ref.
function Updater.check(opts)
    if not is_git_repo() then return nil end
    if not origin_is_github() then return nil end

    git("fetch --quiet --no-tags origin main")

    local behind, ahead = behind_ahead()
    if not behind or behind == 0 then return nil end
    return {
        behind = behind,
        ahead = ahead or 0,
        current = git("rev-parse --short HEAD") or "?",
        latest = git("log -1 --format=%s origin/main") or "",
    }
end

-- Apply the update by fast-forwarding to origin/main. Returns (ok, message).
-- Refuses on a dirty tree or a diverged history so local work is never lost. The
-- running process still holds the OLD code, so on success the caller should re-run.
function Updater.apply()
    if is_dirty() then
        return false, "Update skipped: you have uncommitted local changes. Commit or stash them first (git stash), then update."
    end
    local behind, ahead = behind_ahead()
    if behind and ahead and ahead > 0 then
        return false, "Update skipped: local history has diverged from origin/main (" ..
            ahead .. " local commit(s)). Resolve it manually (git pull --rebase)."
    end
    git("pull --ff-only origin main")
    local behind2 = behind_ahead()
    if behind2 == 0 then
        return true, "Updated to the latest version. Re-run your command to use it."
    end
    return false, "Update did not complete. Update manually with: git pull --ff-only origin main"
end

return Updater
