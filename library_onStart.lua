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

function yieldFrame()
    local runningCo, isMain = coroutine.running()
    if runningCo ~= nil and not isMain then
        coroutine.yield()
    end
end

function yieldFrames(count, frameYieldFn)
    local total = math.max(1, tonumber(count or 1) or 1)
    local doYieldFrame = frameYieldFn or yieldFrame
    for _ = 1, total do
        doYieldFrame()
    end
end

function sortedKeys(t, cooperativeYieldFn, yieldInterval)
    local keys = {}
    local doCooperativeYield = cooperativeYieldFn or function() end
    local interval = math.max(1, tonumber(yieldInterval or 1) or 1)

    for key in pairs(t or {}) do
        keys[#keys + 1] = key
        if #keys % interval == 0 then
            doCooperativeYield()
        end
    end

    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

function shallowValue(value, cooperativeYieldFn, yieldInterval)
    local valueType = type(value)
    if valueType ~= "table" then
        return tostring(value)
    end

    local keys = sortedKeys(value, cooperativeYieldFn, yieldInterval)
    local parts = {}
    for i = 1, math.min(5, #keys) do
        local key = keys[i]
        parts[#parts + 1] = tostring(key) .. ":" .. type(value[key])
    end
    return string.format("{count=%d %s}", #keys, table.concat(parts, ", "))
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

---------------------------------------------------------------------------
-- HierarchyCache class
-- Owns all cache concerns: runtime memoization, persistent databank I/O,
-- and compact serialization codecs.  Unit code should call the public API
-- instead of touching raw cache globals.
---------------------------------------------------------------------------
HierarchyCache = {}
HierarchyCache.__index = HierarchyCache

function HierarchyCache.new(options)
    options = options or {}
    local self = setmetatable({}, HierarchyCache)

    -- Persistent-cache configuration
    self.cacheKey        = options.cacheKey        or "hierarchy_scan_cache_v1"
    self.cacheVersion    = options.cacheVersion    or 1
    self.chunkLimit      = options.chunkLimit      or 2500
    self.writeFrameDelay = options.writeFrameDelay  or 5
    self.databank        = options.databank         -- may be nil

    -- Cooperative work pacing for normal cache operations such as item and
    -- recipe lookups. This is intentionally separate from frame waits used
    -- around databank writes.
    self.cooperativeYieldFn = options.cooperativeYieldFn or function() end
    self.frameYieldFn = options.frameYieldFn or self.cooperativeYieldFn

    -- Runtime memoization tables
    self.itemByIdCache              = {}
    self.producerInfoById           = {}
    self.productRecipeDataByItemId  = {}
    self.cacheSourceCodeById        = {}
    self.cacheSchematicIdByCode     = {}

    return self
end

function HierarchyCache:resetRuntime()
    self.itemByIdCache              = {}
    self.producerInfoById           = {}
    self.productRecipeDataByItemId  = {}
    self.cacheSourceCodeById        = {}
    self.cacheSchematicIdByCode     = {}
end

function HierarchyCache:hasDatabank()
    return self.databank ~= nil
end

---------------------------------------------------------------------------
-- Runtime memoization
---------------------------------------------------------------------------

function HierarchyCache:getItem(itemId)
    if self.itemByIdCache[itemId] ~= nil then
        return self.itemByIdCache[itemId]
    end
    local item = system.getItem(itemId)
    self.itemByIdCache[itemId] = item
    self.cooperativeYieldFn()
    return item
end

function HierarchyCache:getRecipes(itemId)
    local recipes = system.getRecipes(itemId) or {}
    self.cooperativeYieldFn()
    return recipes
end

function HierarchyCache:classifyProducerBucket(producerRef)
    local lowerName = tostring(producerRef and producerRef.name or ""):lower()
    if lowerName:find("glass furnace", 1, true) then
        return "Glass Furnace"
    end
    if lowerName:find("chemical industry", 1, true) then
        return "Chemical"
    end
    if lowerName:find("honeycomb", 1, true) then
        return "Honeycomb"
    end
    return nil
end

function HierarchyCache:bucketFromOrderedList(orderedBuckets)
    if #orderedBuckets == 0 then
        return "Unknown"
    end
    if #orderedBuckets == 1 then
        return orderedBuckets[1]
    end
    return "Mixed"
end

function HierarchyCache:getProducerInfo(producerId)
    local cached = self.producerInfoById[producerId]
    if cached ~= nil then
        return cached
    end

    local producerItem = self:getItem(producerId)
    cached = {
        id = producerId,
        name = displayName(producerItem),
        tier = producerItem and producerItem.tier or 0,
        classId = producerItem and producerItem.classId or 0,
    }
    cached.bucket = self:classifyProducerBucket(cached)
    self.producerInfoById[producerId] = cached
    return cached
end

function HierarchyCache:buildProductRecipeData(productId, recipes)
    recipes = recipes or {}
    local producerRefs = {}
    local seenProducerIds = {}
    local seenBuckets = {}
    local orderedBuckets = {}

    for _, recipe in ipairs(recipes) do
        for _, rawProducerId in ipairs(recipe.producers or {}) do
            local producerId = tonumber(rawProducerId or 0)
            if producerId and producerId > 0 and not seenProducerIds[producerId] then
                seenProducerIds[producerId] = true
                local producerInfo = self:getProducerInfo(producerId)
                producerRefs[#producerRefs + 1] = {
                    id = producerInfo.id,
                    name = producerInfo.name,
                    quantity = 0,
                    sourcePath = "producers",
                    tier = producerInfo.tier,
                    classId = producerInfo.classId,
                }
                if producerInfo.bucket and not seenBuckets[producerInfo.bucket] then
                    seenBuckets[producerInfo.bucket] = true
                    orderedBuckets[#orderedBuckets + 1] = producerInfo.bucket
                end
            end
            self.cooperativeYieldFn()
        end
    end

    return {
        recipeCount = #recipes,
        producerRefs = producerRefs,
        bucket = self:bucketFromOrderedList(orderedBuckets),
    }
end

function HierarchyCache:getProductRecipeData(productId, knownRecipes)
    local cached = self.productRecipeDataByItemId[productId]
    if cached ~= nil then
        return cached
    end

    local recipes = knownRecipes or self:getRecipes(productId)
    cached = self:buildProductRecipeData(productId, recipes)
    self.productRecipeDataByItemId[productId] = cached
    return cached
end

function HierarchyCache:buildSchematicCodeMaps(relevantSchematicList)
    local codeById = {}
    local idByCode = {}
    for index, schematic in ipairs(relevantSchematicList or {}) do
        local schematicId = tonumber(schematic and schematic.id or 0) or 0
        if schematicId > 0 then
            local code = encodeIndexCode(index)
            codeById[schematicId] = code
            idByCode[code] = schematicId
        end
    end
    return codeById, idByCode
end

---------------------------------------------------------------------------
-- Persistent-cache low-level helpers
---------------------------------------------------------------------------

function HierarchyCache:yieldFrames(count)
    local total = math.max(1, tonumber(count or 1) or 1)
    for _ = 1, total do
        self.frameYieldFn()
    end
end

function HierarchyCache:clearDatabankKeySlow(key)
    self.databank.clearValue(key)
    self:yieldFrames(self.writeFrameDelay)
end

function HierarchyCache:writeDatabankStringVerified(label, key, value)
    self:yieldFrames(self.writeFrameDelay)
    self.databank.setStringValue(key, value)
    self:yieldFrames(self.writeFrameDelay)
    local storedValue = self.databank.getStringValue(key)
    self:yieldFrames(self.writeFrameDelay)
    if tostring(storedValue or "") ~= tostring(value or "") then
        system.print("cache write verify failed: " .. tostring(label))
        return false
    end
    return true
end

function HierarchyCache:getCacheMetaKey()
    return self.cacheKey .. ":meta"
end

function HierarchyCache:getCacheChunkKey(index)
    return self.cacheKey .. ":chunk:" .. tostring(index)
end

function HierarchyCache:getExistingCacheKeys()
    local keys = {}
    local keyList = self.databank.getKeyList() or {}
    local prefix = self.cacheKey .. ":"
    for _, key in ipairs(keyList) do
        local keyText = tostring(key or "")
        if keyText == self.cacheKey or string.sub(keyText, 1, string.len(prefix)) == prefix then
            keys[#keys + 1] = keyText
        end
        self.cooperativeYieldFn()
    end
    table.sort(keys)
    return keys
end

function HierarchyCache:clearExistingCacheData()
    if not self:hasDatabank() then
        return 0
    end

    local keys = self:getExistingCacheKeys()
    local totalOps = #keys
    for index, key in ipairs(keys) do
        self:clearDatabankKeySlow(key)
    end

    return #keys
end

---------------------------------------------------------------------------
-- Compact entry contract (save / load / lazy rehydration defined together)
---------------------------------------------------------------------------

function HierarchyCache:makeCachedEntry(entry)
    return {
        id = entry.id,
        branch = entry.branch,
        sourceSchematics = entry.sourceSchematics or {},
    }
end

function HierarchyCache:makeCompactCachedLine(entry)
    local fields = {
        tostring(entry.id or 0),
        encodeBucket(entry.branch),
        encodeSourceSchematics(entry.sourceSchematics or {}, self.cacheSourceCodeById),
    }
    return table.concat(fields, "|")
end

function HierarchyCache:parseCompactCachedLine(line)
    local fields = splitCacheLine(tostring(line or ""))
    local entryId = tonumber(fields[1] or 0)
    if not entryId or entryId <= 0 then
        return nil
    end

    return {
        id = entryId,
        name = "",
        branch = decodeBucket(fields[2]),
        itemType = "",
        tier = "",
        size = "",
        displayClassId = 0,
        childCount = 0,
        recipeCount = 0,
        matchedRecipeCount = 0,
        sourceCount = 0,
        itemIndustryHits = {},
        itemProductHits = {},
        itemSchematicHits = {},
        itemIndustryRefs = {},
        itemProductRefs = {},
        sourceSchematics = decodeSourceSchematics(fields[3], self.cacheSchematicIdByCode),
        matches = {},
        detailLoaded = false,
    }
end

---------------------------------------------------------------------------
-- Meta string serialization (owns its own version instead of global)
---------------------------------------------------------------------------

function HierarchyCache:buildCacheMetaString(meta)
    return table.concat({
        "compact_v3",
        tostring(self.cacheVersion),
        tostring(meta.generatedAt or 0),
        safeText(meta.scanSummary or ""),
        tostring(meta.schematicCount or 0),
        tostring(meta.resultCount or 0),
        tostring(meta.chunkCount or 0),
        sanitizeCacheField(meta.schematicMap or ""),
    }, "|")
end

function HierarchyCache:parseCacheMetaString(raw)
    local fields = splitCacheLine(tostring(raw or ""))
    if fields[1] ~= "compact_v3" then
        return nil
    end

    local version = tonumber(fields[2] or 0) or 0
    if version ~= self.cacheVersion then
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

---------------------------------------------------------------------------
-- High-level public API
---------------------------------------------------------------------------

function HierarchyCache:buildCompactCachePayload(scanResults, relevantSchematicList, scanSummary)
    local maxChunkLength = tonumber(self.chunkLimit) or 2500
    local chunks = {}
    local currentChunkLines = {}
    local currentChunkLength = 0
    self.cacheSourceCodeById, self.cacheSchematicIdByCode = self:buildSchematicCodeMaps(relevantSchematicList)

    for _, entry in ipairs(scanResults) do
        local line = self:makeCompactCachedLine(self:makeCachedEntry(entry))
        local extraLength = #line
        if currentChunkLength > 0 then
            extraLength = extraLength + 1
        end

        if currentChunkLength > 0 and currentChunkLength + extraLength > maxChunkLength then
            chunks[#chunks + 1] = table.concat(currentChunkLines, "\n")
            currentChunkLines = {}
            currentChunkLength = 0
        end

        currentChunkLines[#currentChunkLines + 1] = line
        currentChunkLength = currentChunkLength + #line
        if #currentChunkLines > 1 then
            currentChunkLength = currentChunkLength + 1
        end
        self.cooperativeYieldFn()
    end

    if #currentChunkLines > 0 then
        chunks[#chunks + 1] = table.concat(currentChunkLines, "\n")
    end

    local meta = {
        format = "compact_v3",
        version = self.cacheVersion,
        generatedAt = system.getUtcTime(),
        scanSummary = scanSummary,
        schematicCount = #relevantSchematicList,
        resultCount = #scanResults,
        chunkCount = #chunks,
        schematicMap = encodeSchematicMap(self.cacheSchematicIdByCode),
    }
    return meta, chunks
end

function HierarchyCache:saveScanResults(scanResults, relevantSchematicList, scanSummary)
    if not self:hasDatabank() then
        return false
    end

    local meta, chunks = self:buildCompactCachePayload(scanResults, relevantSchematicList, scanSummary)
    self:clearExistingCacheData()
    for index, chunk in ipairs(chunks or {}) do
        if not self:writeDatabankStringVerified("chunk " .. tostring(index), self:getCacheChunkKey(index), chunk) then
            return false
        end
    end
    if not self:writeDatabankStringVerified("meta", self:getCacheMetaKey(), self:buildCacheMetaString(meta)) then
        self:clearDatabankKeySlow(self:getCacheMetaKey())
        return false
    end
    system.print(string.format("cache saved: chunks=%d results=%d", #chunks, #scanResults))
    return true
end

function HierarchyCache:loadScanResults()
    if not self:hasDatabank() then
        return nil
    end

    local meta = self:parseCacheMetaString(self.databank.getStringValue(self:getCacheMetaKey()))
    if type(meta) ~= "table" then
        return nil
    end

    self.cacheSchematicIdByCode = decodeSchematicMap(meta.schematicMap or "")
    local scanResults = {}
    local resultByItemId = {}
    local chunkCount = tonumber(meta.chunkCount or 0) or 0
    for index = 1, chunkCount do
        local chunk = self.databank.getStringValue(self:getCacheChunkKey(index))
        for line in tostring(chunk or ""):gmatch("[^\n]+") do
            local entry = self:parseCompactCachedLine(line)
            if entry then
                scanResults[#scanResults + 1] = entry
                resultByItemId[entry.id] = entry
            end
            self.cooperativeYieldFn()
        end
    end

    return {
        scanResults = scanResults,
        resultByItemId = resultByItemId,
        scanSummary = tostring(meta.scanSummary or ""),
        schematicCount = tonumber(meta.schematicCount or 0) or 0,
        resultCount = #scanResults,
    }
end

function HierarchyCache:clearPersistent()
    return self:clearExistingCacheData()
end
