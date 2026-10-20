-- The test runner: each file in checks/ is a module of checks, and `ptest` runs them. A check
-- passes when its function returns without an error, and is skipped when it returns h.skip(why)
-- (it needs something there is not now, such as a skater); a later check passes when it calls
-- done(true) in time. Only failures and the summary are printed, to stay under the 50 lines a second a plugin has.
local harness = {}
local modules, order = {}, {}
local running = nil

function harness.module(name)
    if not modules[name] then
        modules[name] = {}
        table.insert(order, name)
    end
    local list = modules[name]
    local m = {}
    function m.check(title, fn)
        table.insert(list, {title = title, fn = fn})
    end
    -- fn(done): call done(ok, why) within `within` ms of the run starting.
    function m.later(title, within, fn)
        table.insert(list, {title = title, fn = fn, within = within})
    end
    return m
end

-- What the call raised; an error when it was allowed.
function harness.refused(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then error("was allowed", 2) end
    return tostring(err)
end

local skip_mark = {}
function harness.skip(why)
    return {[skip_mark] = true, why = why}
end

function harness.names()
    return table.clone(order)
end

function harness.has(name)
    return modules[name] ~= nil
end

local function finish(run)
    running = nil
    local shown = 0
    for _, line in run.failures do
        shown += 1
        if shown > 20 then
            reskate.console.print("FAIL ... and " .. (#run.failures - 20) .. " more")
            break
        end
        reskate.console.print("FAIL " .. line)
    end
    local parts = {}
    for _, name in run.names do
        local tally = run.per[name]
        table.insert(parts, name .. " " .. tally.passed .. "/" .. tally.total)
    end
    local skipped = run.skipped > 0 and (", " .. run.skipped .. " skipped (" .. table.concat(run.skips, "; ") .. ")") or ""
    reskate.console.print("ptest: " .. run.passed .. " passed, " .. run.failed .. " failed" .. skipped .. " (" .. table.concat(parts, ", ") .. ")")
end

local function record(run, name, title, ok, why)
    local tally = run.per[name]
    if ok then
        run.passed += 1
        tally.passed += 1
    else
        run.failed += 1
        table.insert(run.failures, name .. ": " .. title .. ": " .. tostring(why or "failed"))
    end
end

function harness.run(names)
    if running then
        reskate.console.print("ptest: a run is still going on")
        return
    end
    local run = {names = names, passed = 0, failed = 0, skipped = 0, pending = 0, failures = {}, skips = {}, per = {}}
    running = run
    for _, name in names do
        run.per[name] = {passed = 0, total = #modules[name]}
    end
    for _, name in names do
        for _, item in modules[name] do
            if item.within then
                run.pending += 1
                local finished = false
                local function done(ok, why)
                    if finished then return end
                    finished = true
                    record(run, name, item.title, ok, why)
                    run.pending -= 1
                    if run.pending == 0 then finish(run) end
                end
                reskate.time.after(item.within, function() done(false, "did not finish within " .. item.within .. " ms") end)
                local ok, err = pcall(item.fn, done)
                if not ok then done(false, err) end
            else
                local ok, err = pcall(item.fn)
                if ok and type(err) == "table" and err[skip_mark] then
                    run.skipped += 1
                    run.per[name].total -= 1
                    table.insert(run.skips, name .. ": " .. item.title .. ": " .. err.why)
                else
                    record(run, name, item.title, ok, err)
                end
            end
        end
    end
    if run.pending == 0 then finish(run) end
end

return harness
