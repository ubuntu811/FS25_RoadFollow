-- The game's Lua has no coroutine library (RoadMapper once used one: it worked in these tests and failed in the game with "attempt to index nil with
-- 'create'"): hide it here too, so that cannot happen again.
coroutine = nil

-- tiny test harness (same shape as the sibling mods' tests): check(name, condition), finish(name)
local passed, failed = 0, 0
function check(name, condition)
    if condition then
        passed = passed + 1
        print("  PASS " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name)
    end
end
function finish(name)
    print(string.format("%s: %d/%d passed", name, passed, passed + failed))
    if failed > 0 then
        os.exit(1)
    end
end
