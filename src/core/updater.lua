--[[ optional self-update check for the CLI: compares the checkout against origin/main
     and, on request, fast-forwards. any error is a silent no-op; a dirty or diverged
     tree refuses rather than discarding local work. ]]

local Updater = {}

local IS_WIN = package.config:sub(1, 1) == "\\"
local NULDEV = IS_WIN and "NUL" or "/dev/null"

-- repo root for the git commands (via `git -C`), so cwd doesn't matter
local repo_root = "."
function Updater.configure(root)
    if type(root) == "string" and root ~= "" then repo_root = root end
end

-- at most one GitHub fetch per day; the last-check time lives in a local, gitignored stamp
local CHECK_INTERVAL = 24 * 60 * 60
local function stamp_path() return repo_root .. "/.colisseum-update-stamp" end

local function last_check()
    local f = io.open(stamp_path(), "rb")
    if not f then return nil end
    local body = f:read("*a") or ""
    f:close()
    return tonumber(body:match("^%s*(%d+)"))
end

local function mark_checked()
    local f = io.open(stamp_path(), "wb")
    if not f then return end
    f:write(tostring(os.time()))
    f:close()
end

-- force git non-interactive so an auth prompt on a private remote can't hang the CLI
local function env_prefix()
    if IS_WIN then
        return 'set "GIT_TERMINAL_PROMPT=0" && set "GCM_INTERACTIVE=never" && '
    end
    return "GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never "
end

-- flags on every git call: no credential UI, and abort a transfer stalled below ~1 KB/s for 8s
local GIT_FLAGS = '-c credential.interactive=false -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=8'

-- run `git <args>` at the repo root -> trimmed stdout (stderr dropped), or nil; never raises
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

-- true when the tree has uncommitted changes; a lone vendor/Fiu gitlink change is ignored
local function is_dirty()
    local status = git("status --porcelain --untracked-files=no")
    if type(status) ~= "string" or status == "" then return false end
    for line in (status .. "\n"):gmatch("(.-)\n") do
        local path = line:match("^..%s+(.+)$")
        if line ~= "" and path ~= "vendor/Fiu" then return true end
    end
    return false
end

-- commits origin/main is ahead of HEAD (behind) and HEAD ahead of origin/main (ahead); nil if unknown
local function behind_ahead()
    local counts = git("rev-list --left-right --count origin/main...HEAD")
    if type(counts) ~= "string" then return nil end
    local behind, ahead = counts:match("^(%d+)%s+(%d+)$")
    if not behind then return nil end
    return tonumber(behind), tonumber(ahead)
end

--[[ fetch quietly and report whether the checkout is behind origin/main:
     { behind, ahead, current, latest } when behind, else nil. offline falls back to
     the last-known ref. ]]
function Updater.check(opts)
    opts = opts or {}
    if not is_git_repo() then return nil end
    if not origin_is_github() then return nil end

    -- throttle: skip the fetch if we already checked within CHECK_INTERVAL. Mark the
    -- attempt before fetching, so a slow/offline fetch doesn't make every build retry.
    if not opts.force then
        local last = last_check()
        if last then
            local age = os.time() - last
            if age >= 0 and age < CHECK_INTERVAL then return nil end
        end
    end
    mark_checked()

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

--[[ fast-forward to origin/main -> (ok, message). refuses on a dirty tree or diverged
     history so local work is never lost. the process still holds the old code, so the
     caller re-runs on success. ]]
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
