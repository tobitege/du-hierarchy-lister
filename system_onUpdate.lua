local rawOutput = screen.getScriptOutput()
if rawOutput and rawOutput ~= "" and rawOutput ~= lastOutput then
    lastOutput = rawOutput

    local pong = lastOutput:match("^pong:(%d+)$")
    if pong ~= nil then
        screenLoaded = (pong == loadingCheck)
        return
    end

    if rawOutput == "rescan" then
        startScan(true)
        return
    end

    if rawOutput == "stop" then
        stopRequested = true
        _loadCo = nil
        _loadArgs = {}
        unit.stopTimer("coTick")
        renderIdle("Stopped")
        return
    end

    if rawOutput == "results" then
        renderResults(currentResultsPage or 0)
        return
    end

    local pageNum = rawOutput:match("^page:(%-?%d+)$")
    if pageNum then
        local page = tonumber(pageNum) or 0
        if currentView == "detail" and selectedItemId ~= nil then
            renderDetail(selectedItemId, page)
        else
            renderResults(page)
        end
        return
    end

    local itemId = rawOutput:match("^item:(%d+)$")
    if itemId then
        renderDetail(tonumber(itemId), 0)
    end
end
