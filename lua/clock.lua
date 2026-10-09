-- Times are ns since the session started. NEVER is a time that never
-- happened: since(now, NEVER) is longer than any real wait.

local M = {}

M.NEVER = -2 ^ 63

local LONGEST = 2 ^ 63

-- since is how long ago at was, in ns.
function M.since(now, at)
  if at <= M.NEVER then
    if now <= M.NEVER then
      return 0
    end
    return LONGEST
  end
  return now - at
end

-- secs is a duration in ns as seconds: the whole seconds, then the rest.
function M.secs(d)
  if d > LONGEST then
    d = LONGEST
  elseif d < -LONGEST then
    d = -LONGEST
  end
  local s
  if d >= 0 then
    s = math.floor(d / 1e9)
  else
    s = -math.floor(-d / 1e9)
  end
  return s + (d - s * 1e9) / 1e9
end

return M
