if _loadCo == nil then
    unit.stopTimer("coTick")
    return
end
if coroutine.status(_loadCo) == "suspended" then
    local ok, err = coroutine.resume(_loadCo, table.unpack(_loadArgs or {}))
    _loadArgs = {}  -- only pass args on first resume
    if not ok then
        system.print("co error: " .. tostring(err))
        _loadCo = nil
        unit.stopTimer("coTick")
    end
else
    _loadCo = nil
    unit.stopTimer("coTick")
end

