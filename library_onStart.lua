function displayName(item)
    if not item then
        return "Unknown item"
    end
    if item.locDisplayNameWithSize ~= nil and item.locDisplayNameWithSize ~= "" then
        return item.locDisplayNameWithSize
    end
    if item.locDisplayName ~= nil and item.locDisplayName ~= "" then
        return item.locDisplayName
    end
    if item.displayName ~= nil and item.displayName ~= "" then
        return item.displayName
    end
    if item.name ~= nil and item.name ~= "" then
        return item.name
    end
    return "Unknown item"
end

function safeText(value)
    return tostring(value or ""):gsub("[;\r\n]", " ")
end

function clipLabel(text, maxLength)
    text = tostring(text or "")
    maxLength = tonumber(maxLength or 0) or 0
    if maxLength <= 0 or #text <= maxLength then
        return text
    end
    if maxLength <= 3 then
        return string.sub(text, 1, maxLength)
    end
    return string.sub(text, 1, maxLength - 3) .. "..."
end

function appendLine(lines, text)
    lines[#lines + 1] = safeText(text)
end

function hasRelevantSchematicName(name)
    local lowerName = tostring(name or ""):lower()
    return lowerName:find("schematic") and (
        lowerName:find("pure")
        or lowerName:find("product")
        or lowerName:find("fuel")
    )
end

function matchesAnyTerm(text, terms)
    local lowerText = tostring(text or ""):lower()
    for _, term in ipairs(terms or {}) do
        if lowerText:find(term, 1, true) then
            return true
        end
    end
    return false
end

function pushDumpLine(lines, text, maxLines)
    if #lines >= maxLines then
        return
    end
    lines[#lines + 1] = safeText(text)
end

function printDumpLines(prefix, lines)
    local chunk = {}
    local chunkLength = 0
    for _, line in ipairs(lines or {}) do
        local text = tostring(line or "")
        local extra = #text
        if #chunk > 0 then
            extra = extra + 4
        end
        if chunkLength + extra > 950 then
            system.print(prefix .. " " .. table.concat(chunk, " || "))
            chunk = {}
            chunkLength = 0
        end
        chunk[#chunk + 1] = text
        chunkLength = chunkLength + extra
    end
    if #chunk > 0 then
        system.print(prefix .. " " .. table.concat(chunk, " || "))
    end
end

function summarizeIdList(values)
    local ids = {}
    for _, value in ipairs(values or {}) do
        ids[#ids + 1] = tostring(value)
    end
    if #ids == 0 then
        return "[]"
    end
    if #ids <= 8 then
        return "[" .. table.concat(ids, ", ") .. "]"
    end
    local shown = {}
    for index = 1, 8 do
        shown[#shown + 1] = ids[index]
    end
    return "[" .. table.concat(shown, ", ") .. ", ...]"
end

function appendTokenWithinLimit(tokens, token, limit)
    local current = table.concat(tokens, ";")
    local candidate = current
    if candidate ~= "" then
        candidate = candidate .. ";"
    end
    candidate = candidate .. tostring(token or "")
    if #candidate > (tonumber(limit or 0) or 0) then
        return false
    end
    tokens[#tokens + 1] = tostring(token or "")
    return true
end

function joinProducerNames(producerRefs)
    local names = {}
    for _, producerRef in ipairs(producerRefs or {}) do
        local suffix = ""
        if producerRef.tier ~= nil and producerRef.tier ~= "" then
            suffix = " T" .. tostring(producerRef.tier)
        end
        names[#names + 1] = tostring(producerRef.name or producerRef.id or "?") .. suffix
    end
    if #names == 0 then
        return "none"
    end
    return table.concat(names, ", ")
end

function sanitizeCacheField(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n|]", " ")
    return text
end

function encodeBucket(branch)
    local branchName = tostring(branch or "Unknown")
    if branchName == "Honeycomb" then
        return "H"
    end
    if branchName == "Chemical" then
        return "C"
    end
    if branchName == "Glass Furnace" then
        return "G"
    end
    if branchName == "Mixed" then
        return "M"
    end
    return "U"
end

function decodeBucket(code)
    local bucketCode = tostring(code or "")
    if bucketCode == "H" then
        return "Honeycomb"
    end
    if bucketCode == "C" then
        return "Chemical"
    end
    if bucketCode == "G" then
        return "Glass Furnace"
    end
    if bucketCode == "M" then
        return "Mixed"
    end
    return "Unknown"
end

function encodeIndexCode(index)
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local value = tonumber(index or 0) or 0
    if value <= 0 then
        return ""
    end

    local parts = {}
    while value > 0 do
        local remainder = value % 36
        if remainder == 0 then
            remainder = 36
            value = math.floor(value / 36) - 1
        else
            value = math.floor(value / 36)
        end
        parts[#parts + 1] = string.sub(digits, remainder, remainder)
    end

    local code = {}
    for i = #parts, 1, -1 do
        code[#code + 1] = parts[i]
    end
    return table.concat(code)
end

function encodeSourceSchematics(sourceSchematics, codeById)
    local parts = {}
    local seenCodes = {}
    for _, source in ipairs(sourceSchematics or {}) do
        local schematicId = tonumber(source and source.schematicId or 0) or 0
        local code = codeById and codeById[schematicId] or nil
        if code ~= nil and code ~= "" and not seenCodes[code] then
            parts[#parts + 1] = code
            seenCodes[code] = true
        end
    end
    table.sort(parts)
    return table.concat(parts, ".")
end

function decodeSourceSchematics(encoded, idByCode)
    local sourceSchematics = {}
    for code in tostring(encoded or ""):gmatch("[^.]+") do
        local schematicId = idByCode and idByCode[code] or nil
        if schematicId ~= nil and schematicId > 0 then
            sourceSchematics[#sourceSchematics + 1] = {
                schematicId = schematicId,
                quantity = 1,
            }
        end
    end
    return sourceSchematics
end

function encodeSchematicMap(idByCode)
    local parts = {}
    for code, schematicId in pairs(idByCode or {}) do
        parts[#parts + 1] = code .. ":" .. tostring(schematicId)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function decodeSchematicMap(raw)
    local idByCode = {}
    for pairText in tostring(raw or ""):gmatch("[^,]+") do
        local code, idText = pairText:match("^([^:]+):(%d+)$")
        if code ~= nil and idText ~= nil then
            idByCode[code] = tonumber(idText) or 0
        end
    end
    return idByCode
end

function splitCacheLine(line)
    local fields = {}
    local startIndex = 1
    while true do
        local separatorIndex = string.find(line, "|", startIndex, true)
        if separatorIndex == nil then
            fields[#fields + 1] = string.sub(line, startIndex)
            break
        end
        fields[#fields + 1] = string.sub(line, startIndex, separatorIndex - 1)
        startIndex = separatorIndex + 1
    end
    return fields
end

function buildCacheMetaString(meta)
    return table.concat({
        "compact_v3",
        tostring(CACHE_VERSION),
        tostring(meta.generatedAt or 0),
        safeText(meta.scanSummary or ""),
        tostring(meta.schematicCount or 0),
        tostring(meta.resultCount or 0),
        tostring(meta.chunkCount or 0),
        sanitizeCacheField(meta.schematicMap or ""),
    }, "|")
end

function parseCacheMetaString(raw)
    local fields = splitCacheLine(tostring(raw or ""))
    if fields[1] ~= "compact_v3" then
        return nil
    end

    local version = tonumber(fields[2] or 0) or 0
    if version ~= CACHE_VERSION then
        return nil
    end

    return {
        format = fields[1],
        version = version,
        generatedAt = tonumber(fields[3] or 0) or 0,
        scanSummary = fields[4] or "",
        schematicCount = tonumber(fields[5] or 0) or 0,
        resultCount = tonumber(fields[6] or 0) or 0,
        chunkCount = tonumber(fields[7] or 0) or 0,
        schematicMap = fields[8] or "",
    }
end
