if not screenLoaded then
local renderScript = "local linkedIndustryFilters = " .. buildLinkedIndustryFiltersRenderDefs() .. "\n" .. [[
local rx, ry = getResolution()
local fontSize = 22
local font = loadFont('Play', fontSize)
local headerFontSize = 16
local headerFont = loadFont('Play', headerFontSize)
local filterFontSize = 13
local filterFont = loadFont('Play', filterFontSize)
local gap = 6
local navWidth = 52
local headerButtonWidth = 112
local pageButtonWidth = 88
local headerRowHeight = headerFontSize + gap * 2
local topBarHeight = headerRowHeight + gap * 2
local pagerBarHeight = headerRowHeight + gap * 2
local lineHeight = fontSize + gap * 2
local mousex, mousey = getCursor()
local loadedLinkedIndustryImages = loadedLinkedIndustryImages or {}

local function splitInput(raw)
    local parts = {}
    for part in string.gmatch(raw or "", "[^;]+") do
        table.insert(parts, part)
    end
    return parts
end

local function drawCenteredText(layer, text, x, y, w, h, textFont)
    setNextTextAlign(layer, AlignH_Center, AlignV_Middle)
    addText(layer, textFont or font, text, x + w / 2, y + h / 2)
end

local function drawHeaderLine(layer, text, x, y, w, h)
    setNextTextAlign(layer, AlignH_Left, AlignV_Middle)
    addText(layer, headerFont, text, x, y + h / 2)
end

local function drawStatusView(message, current, total)
    local centerY = math.floor(ry * 0.5)
    local barWidth = math.floor(rx * 0.72)
    local barHeight = 28
    local barX = math.floor((rx - barWidth) / 2)
    local barY = centerY + 18
    local pct = 0
    if total > 0 then
        pct = math.max(0, math.min(1, current / total))
    end

    local titleLayer = createLayer()
    setDefaultFillColor(titleLayer, Shape_Text, 1, 1, 1, 1)
    drawCenteredText(titleLayer, "Recipe Scan", 0, centerY - 70, rx, 36, font)
    drawCenteredText(titleLayer, tostring(message or "Working"), 0, centerY - 28, rx, 32, font)

    local barLayer = createLayer()
    setDefaultFillColor(barLayer, Shape_Box, 0.12, 0.12, 0.18, 0.9)
    addBox(barLayer, barX, barY, barWidth, barHeight)
    if pct > 0 then
        setDefaultFillColor(barLayer, Shape_Box, 0.2, 0.6, 1, 0.95)
        addBox(barLayer, barX, barY, math.max(6, math.floor(barWidth * pct)), barHeight)
    end

    local infoLayer = createLayer()
    setDefaultFillColor(infoLayer, Shape_Text, 1, 1, 1, 1)
    if total > 0 then
        drawCenteredText(infoLayer, tostring(current) .. " / " .. tostring(total), 0, barY + barHeight + 12, rx, 28, headerFont)
    else
        drawCenteredText(infoLayer, "Please wait", 0, barY + barHeight + 12, rx, 28, headerFont)
    end
end

local function drawButton(text, x, y, w, h, outputValue, textFont, variant)
    local layer = createLayer()
    local hovered = mousex >= x and mousex <= x + w and mousey >= y and mousey <= y + h
    local baseR, baseG, baseB, baseA = 0.15, 0.15, 0.2, 0.45
    local hoverR, hoverG, hoverB, hoverA = 0.15, 0.4, 0.7, 0.42
    local pressR, pressG, pressB, pressA = 0.2, 0.6, 1, 0.85
    if variant == "danger" then
        baseR, baseG, baseB, baseA = 0.55, 0.1, 0.1, 0.72
        hoverR, hoverG, hoverB, hoverA = 0.8, 0.16, 0.16, 0.8
        pressR, pressG, pressB, pressA = 0.95, 0.2, 0.2, 0.92
    end
    if hovered then
        if getCursorPressed() then
            setDefaultFillColor(layer, Shape_Box, pressR, pressG, pressB, pressA)
            output = outputValue
        else
            setDefaultFillColor(layer, Shape_Box, hoverR, hoverG, hoverB, hoverA)
        end
    else
        setDefaultFillColor(layer, Shape_Box, baseR, baseG, baseB, baseA)
    end
    addBox(layer, x, y, w, h)
    setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
    drawCenteredText(layer, text, x, y, w, h, textFont)
end

local function clipText(text, maxLen)
    text = tostring(text or "")
    if string.len(text) <= maxLen then
        return text
    end
    if maxLen <= 3 then
        return string.sub(text, 1, maxLen)
    end
    return string.sub(text, 1, maxLen - 3) .. "..."
end

local function getLinkedIndustryImage(filterDef)
    local key = tostring(filterDef and filterDef.key or "")
    if key == "" then
        return nil
    end

    local cachedImage = loadedLinkedIndustryImages[key]
    if cachedImage == nil then
        local iconPath = tostring(filterDef.iconPath or "")
        if iconPath ~= "" then
            cachedImage = loadImage(iconPath)
        else
            cachedImage = false
        end
        loadedLinkedIndustryImages[key] = cachedImage or false
    end

    if cachedImage == false then
        return nil
    end
    return cachedImage
end

local function getLinkedIndustryFilterLabel(filterKey)
    if filterKey == nil or filterKey == "" or filterKey == "all" then
        return "All linked industry"
    end

    local labels = {}
    for _, filterDef in ipairs(linkedIndustryFilters or {}) do
        local key = tostring(filterDef.key or "")
        if string.find("." .. tostring(filterKey) .. ".", "." .. key .. ".", 1, true) ~= nil then
            labels[#labels + 1] = tostring(filterDef.label or filterDef.key or "Unknown")
        end
    end
    if #labels == 0 then
        return tostring(filterKey)
    end
    if #labels == 1 then
        return labels[1]
    end
    return tostring(#labels) .. " selected"
end

local function buildActiveFilterSet(activeFilterId)
    local activeFilterSet = {}
    local activeCount = 0
    for key in tostring(activeFilterId or ""):gmatch("[^.]+") do
        if key ~= "" and key ~= "all" then
            if not activeFilterSet[key] then
                activeCount = activeCount + 1
            end
            activeFilterSet[key] = true
        end
    end
    return activeFilterSet, activeCount
end

local function drawRow(text, command, rowIndex)
    local x = navWidth
    local y = topBarHeight + pagerBarHeight + rowIndex * lineHeight
    local w = rx - navWidth * 2
    local layer = createLayer()
    local hovered = mousex >= x and mousex <= x + w and mousey >= y and mousey <= y + lineHeight
    if hovered then
        if getCursorPressed() then
            setDefaultFillColor(layer, Shape_Box, 0.2, 0.6, 1, 0.85)
            output = command
        else
            setDefaultFillColor(layer, Shape_Box, 0.15, 0.4, 0.7, 0.24)
        end
    else
        setDefaultFillColor(layer, Shape_Box, 0, 0, 0, 0.12)
    end
    addBox(layer, x, y, w, lineHeight)
    setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
    setNextTextAlign(layer, AlignH_Left, AlignV_Top)
    addText(layer, font, text, x + gap, y + gap / 2)
end

local function drawStaticRow(text, rowIndex)
    local x = navWidth
    local y = topBarHeight + pagerBarHeight + rowIndex * lineHeight
    local w = rx - navWidth * 2
    local textTopPadding = 4
    local layer = createLayer()
    local isSectionHeader = tostring(text or "") == "Recipe"
    if isSectionHeader then
        setDefaultFillColor(layer, Shape_BoxRounded, 0.08, 0.08, 0.14, 0.52)
        addBoxRounded(layer, x + 4, y + 3, w - 8, lineHeight - 6, 8)
    else
        setDefaultFillColor(layer, Shape_Box, 0, 0, 0, 0.12)
        addBox(layer, x, y, w, lineHeight)
    end
    setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
    setNextTextAlign(layer, AlignH_Left, AlignV_Top)
    addText(layer, isSectionHeader and headerFont or font, text, x + gap, y + gap / 2 + textTopPadding)
end

local function drawLinkedIndustryFilterButton(filterDef, x, y, size, activeFilterSet, activeCount)
    local layer = createLayer()
    local hovered = mousex >= x and mousex <= x + size and mousey >= y and mousey <= y + size
    local filterKey = "all"
    local isActive = activeCount == 0
    if filterDef ~= nil then
        filterKey = tostring(filterDef.key or "all")
        isActive = activeFilterSet[filterKey] == true
    end

    local baseAlpha = isActive and 0.72 or 0.35
    local fillR, fillG, fillB = 0.12, 0.12, 0.18
    if hovered then
        fillR, fillG, fillB = 0.15, 0.4, 0.7
        baseAlpha = isActive and 0.84 or 0.42
        if getCursorPressed() then
            output = "filter:" .. filterKey
            baseAlpha = 0.92
        end
    elseif isActive then
        fillR, fillG, fillB = 0.18, 0.5, 0.9
    end

    setDefaultFillColor(layer, Shape_Box, fillR, fillG, fillB, baseAlpha)
    addBox(layer, x, y, size, size)
    if isActive then
        setDefaultFillColor(layer, Shape_BoxRounded, 0, 0, 0, 0)
        setDefaultStrokeColor(layer, Shape_BoxRounded, 0.55, 1, 0.2, 0.95)
    else
        setDefaultFillColor(layer, Shape_BoxRounded, 0, 0, 0, 0)
        setDefaultStrokeColor(layer, Shape_BoxRounded, 0.38, 0.08, 0.08, 0.95)
    end
    setDefaultStrokeWidth(layer, Shape_BoxRounded, 2)
    addBoxRounded(layer, x + 1, y + 1, size - 2, size - 2, 8)
    setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)

    if filterDef == nil then
        drawCenteredText(layer, "All", x, y, size, size, filterFont)
        return
    end

    local image = getLinkedIndustryImage(filterDef)
    if image ~= nil then
        local imageInset = 1
        addImage(layer, image, x + imageInset, y + imageInset, size - imageInset * 2, size - imageInset * 2, 1)
    else
        drawCenteredText(layer, clipText(filterDef.label or "?", 7), x, y, size, size, filterFont)
    end
end

local function drawLinkedIndustryFilters(activeFilterId, count)
    if #(linkedIndustryFilters or {}) == 0 then
        return
    end

    local barX = navWidth
    local barY = topBarHeight + pagerBarHeight + lineHeight * 12 + gap * 2
    local barWidth = rx - navWidth * 2
    local barHeight = math.max(76, ry - barY - gap * 2)
    if barHeight < 44 then
        return
    end

    local label = getLinkedIndustryFilterLabel(activeFilterId)
    local activeFilterSet, activeCount = buildActiveFilterSet(activeFilterId)

    local barLayer = createLayer()
    setDefaultFillColor(barLayer, Shape_Box, 0.05, 0.05, 0.08, 0.82)
    addBox(barLayer, barX, barY, barWidth, barHeight)
    setDefaultFillColor(barLayer, Shape_Text, 1, 1, 1, 1)
    setNextTextAlign(barLayer, AlignH_Left, AlignV_Middle)
    addText(barLayer, headerFont, "Linked industry filter: " .. clipText(label, 28), barX + gap, barY + 14)
    setNextTextAlign(barLayer, AlignH_Right, AlignV_Middle)
    addText(barLayer, headerFont, "Results: " .. tostring(tonumber(count or 0) or 0), barX + barWidth - gap, barY + 14)

    local buttonSize = math.min(58, math.max(44, barHeight - 24))
    local buttonGap = 10
    local buttonBottomMargin = gap + 10
    local buttonY = barY + barHeight - buttonSize - buttonBottomMargin
    local x = barX + gap

    drawLinkedIndustryFilterButton(nil, x, buttonY, buttonSize, activeFilterSet, activeCount)
    x = x + buttonSize + buttonGap

    for _, filterDef in ipairs(linkedIndustryFilters or {}) do
        if x + buttonSize > barX + barWidth - gap then
            break
        end
        drawLinkedIndustryFilterButton(filterDef, x, buttonY, buttonSize, activeFilterSet, activeCount)
        x = x + buttonSize + buttonGap
    end
end

local function drawPagerBar(page, maxPage)
    local centerWidth = 160
    local buttonWidth = 120
    local y = topBarHeight + gap
    local h = headerRowHeight
    local totalWidth = centerWidth
    if page > 0 then
        totalWidth = totalWidth + buttonWidth + gap
    end
    if page < maxPage then
        totalWidth = totalWidth + buttonWidth + gap
    end

    local startX = math.floor((rx - totalWidth) / 2)
    local x = startX
    local pagerLayer = createLayer()
    setDefaultFillColor(pagerLayer, Shape_Box, 0.05, 0.05, 0.08, 0.85)
    addBox(pagerLayer, 0, topBarHeight, rx, pagerBarHeight)

    if page > 0 then
        drawButton("Prev", x, y, buttonWidth, h, "page:" .. (page - 1), headerFont)
        x = x + buttonWidth + gap
    end

    local pageLayer = createLayer()
    setDefaultFillColor(pageLayer, Shape_Box, 0.15, 0.15, 0.2, 0.45)
    addBox(pageLayer, x, y, centerWidth, h)
    setDefaultFillColor(pageLayer, Shape_Text, 1, 1, 1, 1)
    drawCenteredText(pageLayer, "Page " .. tostring(page + 1) .. " / " .. tostring(maxPage + 1), x, y, centerWidth, h, headerFont)
    x = x + centerWidth + gap

    if page < maxPage then
        drawButton("Next", x, y, buttonWidth, h, "page:" .. (page + 1), headerFont)
    end
end

local function drawSidePagerHotzones(page, maxPage)
    local sideWidth = navWidth
    local topY = topBarHeight
    local height = ry - topBarHeight
    local layer = createLayer()

    if page > 0 then
        if mousex >= 0 and mousex <= sideWidth and mousey >= topY and mousey <= topY + height then
            if getCursorPressed() then
                setDefaultFillColor(layer, Shape_Box, 0.1, 0.1, 0.5, 0.35)
                output = "page:" .. (page - 1)
            else
                setDefaultFillColor(layer, Shape_Box, 0.08, 0.08, 0.32, 0.12)
            end
        else
            setDefaultFillColor(layer, Shape_Box, 0.1, 0.1, 0.5, 0.08)
        end
        addBox(layer, 0, topY, sideWidth, height)
        setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
        drawCenteredText(layer, "<", 0, topY, sideWidth, height, font)
    end

    if page < maxPage then
        local x = rx - sideWidth
        if mousex >= x and mousex <= rx and mousey >= topY and mousey <= topY + height then
            if getCursorPressed() then
                setDefaultFillColor(layer, Shape_Box, 0.1, 0.1, 0.5, 0.35)
                output = "page:" .. (page + 1)
            else
                setDefaultFillColor(layer, Shape_Box, 0.08, 0.08, 0.32, 0.12)
            end
        else
            setDefaultFillColor(layer, Shape_Box, 0.1, 0.1, 0.5, 0.08)
        end
        addBox(layer, x, topY, sideWidth, height)
        setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
        drawCenteredText(layer, ">", x, topY, sideWidth, height, font)
    end
end

local raw = getInput() or ""
local parts = splitInput(raw)
local mode = parts[1] or "status"
lastInput = lastInput or ""
output = output or ""
if raw ~= lastInput then
    output = ""
    lastInput = raw
end

local headerLayer = createLayer()
setDefaultFillColor(headerLayer, Shape_Box, 0.05, 0.05, 0.08, 0.85)
addBox(headerLayer, 0, 0, rx, topBarHeight)
setDefaultFillColor(headerLayer, Shape_Text, 1, 1, 1, 1)

if mode == "results" then
    local page = tonumber(parts[2]) or 0
    local pageCount = tonumber(parts[3]) or 1
    local count = tonumber(parts[4]) or 0
    local summary = parts[5] or ""
    local activeFilterId = parts[6] or "all"
    if activeFilterId == "all" then
        activeFilterId = ""
    end
    local maxPage = math.max(0, pageCount - 1)
    local headerButtonsWidth = headerButtonWidth + gap

    drawHeaderLine(headerLayer, clipText("Recipe Scan - " .. summary, 56), navWidth, gap, rx - navWidth - headerButtonsWidth, headerRowHeight)

    local buttonX = rx - navWidth - headerButtonWidth
    drawButton("Rescan", buttonX, gap + 2, headerButtonWidth, headerRowHeight - 4, "rescan", headerFont)

    local rowIndex = 0
    for i = 7, #parts do
        local label, id = parts[i]:match("^(.*)|(%d+)$")
        if label and id then
            drawRow(label, "item:" .. id, rowIndex)
            rowIndex = rowIndex + 1
        end
    end
    drawLinkedIndustryFilters(activeFilterId, count)
    drawSidePagerHotzones(page, maxPage)
    drawPagerBar(page, maxPage)
elseif mode == "detail" then
    local itemId = parts[2] or ""
    local page = tonumber(parts[3]) or 0
    local pageSize = tonumber(parts[4]) or 1
    local count = tonumber(parts[5]) or 0
    local title = parts[6] or ""
    local maxPage = math.max(0, math.ceil(count / pageSize) - 1)
    local headerButtonsWidth = headerButtonWidth + gap + headerButtonWidth + gap

    local detailTitle = title .. " (" .. itemId .. ")"
    drawHeaderLine(headerLayer, clipText(detailTitle, 50), navWidth, gap, rx - navWidth - headerButtonsWidth, headerRowHeight)

    local buttonX = rx - navWidth - headerButtonWidth
    drawButton("Rescan", buttonX, gap + 2, headerButtonWidth, headerRowHeight - 4, "rescan", headerFont)
    buttonX = buttonX - gap - headerButtonWidth
    drawButton("Back", buttonX, gap + 2, headerButtonWidth, headerRowHeight - 4, "results", headerFont)

    local firstLineIndex = 7
    for i = 7, #parts do
        if tostring(parts[i] or "") == "lines" then
            firstLineIndex = i + 1
            break
        end
    end

    local rowIndex = 0
    for i = firstLineIndex, #parts do
        drawStaticRow(parts[i], rowIndex)
        rowIndex = rowIndex + 1
    end
    if maxPage > 0 then
        drawSidePagerHotzones(page, maxPage)
        drawPagerBar(page, maxPage)
    end
else
    local message = parts[2] or "Waiting for data"
    local current = tonumber(parts[3]) or 0
    local total = tonumber(parts[4]) or 0
    if mode == "idle" then
        drawHeaderLine(headerLayer, clipText("Recipe Scan - " .. message, 64), navWidth, gap, rx, headerRowHeight)
        drawStatusView(message, 0, 0)
        drawButton("Rescan", math.floor((rx - 160) / 2), math.floor(ry * 0.5) + 78 + lineHeight, 160, headerRowHeight + 6, "rescan", headerFont)
    else
        drawHeaderLine(headerLayer, clipText("Recipe Scan - " .. message, 64), navWidth, gap, rx, headerRowHeight)
        drawStatusView(message, current, total)
        drawButton("Stop", math.floor((rx - 140) / 2), math.floor(ry * 0.5) + 78 + lineHeight, 140, headerRowHeight + 6, "stop", headerFont, "danger")
    end
end

setOutput(output)
requestAnimationFrame(1)
]]
screen.setRenderScript(renderScript)
end

unit.stopTimer("initScreen")
screen.setScriptInput("status;Initializing screen;0;1")
startScan()
