if not screenLoaded then
screen.setRenderScript([[
local rx, ry = getResolution()
local fontSize = 24
local font = loadFont('FiraMono-Bold', fontSize)
local headerFontSize = 14
local headerFont = loadFont('FiraMono-Bold', headerFontSize)
local gap = 6
local navWidth = 52
local headerButtonWidth = 144
local headerRowHeight = headerFontSize + gap * 2
local topBarHeight = headerRowHeight + gap * 2
local lineHeight = fontSize + gap * 2
local mousex, mousey = getCursor()

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

local function drawButton(text, x, y, w, h, outputValue, textFont)
    local layer = createLayer()
    local hovered = mousex >= x and mousex <= x + w and mousey >= y and mousey <= y + h
    if hovered then
        if getCursorPressed() then
            setDefaultFillColor(layer, Shape_Box, 0.2, 0.6, 1, 0.85)
            _output = outputValue
        else
            setDefaultFillColor(layer, Shape_Box, 0.2, 0.6, 1, 0.55)
        end
    else
        setDefaultFillColor(layer, Shape_Box, 0.15, 0.15, 0.2, 0.45)
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

local function drawRow(text, command, rowIndex)
    local x = navWidth
    local y = topBarHeight + rowIndex * lineHeight
    local w = rx - navWidth * 2
    local layer = createLayer()
    local hovered = mousex >= x and mousex <= x + w and mousey >= y and mousey <= y + lineHeight
    if hovered then
        if getCursorPressed() then
            setDefaultFillColor(layer, Shape_Box, 0.2, 0.6, 1, 0.85)
            _output = command
        else
            setDefaultFillColor(layer, Shape_Box, 0.2, 0.6, 1, 0.35)
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
    local y = topBarHeight + rowIndex * lineHeight
    local w = rx - navWidth * 2
    local layer = createLayer()
    setDefaultFillColor(layer, Shape_Box, 0, 0, 0, 0.12)
    addBox(layer, x, y, w, lineHeight)
    setDefaultFillColor(layer, Shape_Text, 1, 1, 1, 1)
    setNextTextAlign(layer, AlignH_Left, AlignV_Top)
    addText(layer, font, text, x + gap, y + gap / 2)
end

local raw = getInput() or ""
local parts = splitInput(raw)
local mode = parts[1] or "status"
local _output = ""

local headerLayer = createLayer()
setDefaultFillColor(headerLayer, Shape_Box, 0.05, 0.05, 0.08, 0.85)
addBox(headerLayer, 0, 0, rx, topBarHeight)
setDefaultFillColor(headerLayer, Shape_Text, 1, 1, 1, 1)

if mode == "results" then
    local page = tonumber(parts[2]) or 0
    local pageSize = tonumber(parts[3]) or 1
    local count = tonumber(parts[4]) or 0
    local summary = parts[5] or ""
    local maxPage = math.max(0, math.ceil(count / pageSize) - 1)

    drawHeaderLine(headerLayer, clipText("Recipe Scan - " .. summary, 64), navWidth, gap, rx, headerRowHeight)

    drawButton("Rescan", rx - navWidth - headerButtonWidth, gap + 2, headerButtonWidth, headerRowHeight - 4, "rescan", headerFont)

    if page > 0 then
        drawButton("<", 0, topBarHeight, navWidth, ry - topBarHeight, "page:" .. (page - 1))
    end
    if page < maxPage then
        drawButton(">", rx - navWidth, topBarHeight, navWidth, ry - topBarHeight, "page:" .. (page + 1))
    end

    local rowIndex = 0
    for i = 6, #parts do
        local label, id = parts[i]:match("^(.*)|(%d+)$")
        if label and id then
            drawRow(label, "item:" .. id, rowIndex)
            rowIndex = rowIndex + 1
        end
    end
elseif mode == "detail" then
    local itemId = parts[2] or ""
    local page = tonumber(parts[3]) or 0
    local pageSize = tonumber(parts[4]) or 1
    local count = tonumber(parts[5]) or 0
    local title = parts[6] or ""
    local maxPage = math.max(0, math.ceil(count / pageSize) - 1)

    drawHeaderLine(headerLayer, clipText(title .. " (" .. itemId .. ")  p" .. tostring(page + 1) .. "/" .. tostring(maxPage + 1), 56), navWidth, gap, rx, headerRowHeight)

    drawButton("Back", rx - navWidth - headerButtonWidth * 2 - gap, gap + 2, headerButtonWidth, headerRowHeight - 4, "results", headerFont)
    drawButton("Rescan", rx - navWidth - headerButtonWidth, gap + 2, headerButtonWidth, headerRowHeight - 4, "rescan", headerFont)

    if page > 0 then
        drawButton("<", 0, topBarHeight, navWidth, ry - topBarHeight, "page:" .. (page - 1))
    end
    if page < maxPage then
        drawButton(">", rx - navWidth, topBarHeight, navWidth, ry - topBarHeight, "page:" .. (page + 1))
    end

    local rowIndex = 0
    for i = 7, #parts do
        drawStaticRow(parts[i], rowIndex)
        rowIndex = rowIndex + 1
    end
else
    local message = parts[2] or "Waiting for data"
    drawHeaderLine(headerLayer, clipText("Recipe Scan - " .. message, 64), navWidth, gap, rx, headerRowHeight)
end

setOutput(_output)
requestAnimationFrame(1)
]])
end

unit.stopTimer("initScreen")
startScan()
