SCHEMATIC_ROOT_ID = 2332967944
CONSUMABLES_ROOT_ID = 1464163325
PARTS_ROOT_ID = 1237953170
DEBUG_SCHEMATIC_ID = 2479827059
DEBUG_ONLY = false
ENABLE_DEBUG_DUMPS = false
SCREEN_INPUT_LIMIT = 900
DEBUG_MARKER = "DBG20260409M"
CACHE_KEY = "hierarchy_scan_cache_v7"
CACHE_VERSION = 1
MAX_PRODUCTS_TO_RESOLVE = 0

core = nil
screen = nil
databank = nil
linkedIndustryElements = {}
for slotName, slot in pairs(unit) do
    if type(slot) == "table"
        and type(slot.export) == "table"
        and type(slot.getClass) == "function"
    then
        local elementClass = tostring(slot.getClass() or ""):lower()
        slot.slotName = slotName
        slot.elementClass = elementClass

        if core == nil and elementClass:find("coreunit", 1, true) then
            core = slot
        elseif screen == nil and elementClass:find("screen", 1, true) then
            screen = slot
        elseif databank == nil and elementClass:find("databankunit", 1, true) then
            databank = slot
        end

        if (elementClass:find("industry", 1, true) or elementClass:find("furnace", 1, true)) and type(slot.getItemId) == "function" then
            linkedIndustryElements[#linkedIndustryElements + 1] = slot
        end
    end
end

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

if screen == nil then
    system.print("Screen needs to be linked to programming board")
    unit.exit()
end

screenLoaded = false
loadingCheck = math.floor(system.getUtcTime())
lastOutput = ""

RESULTS_PER_PAGE = 12
DETAIL_LINES_PER_PAGE = 16
BATCH = 10

scanResults = {}
resultByItemId = {}
relevantSchematics = {}
relevantSchematicList = {}
schematicProductsByItemId = {}
productRecipeDataByItemId = {}
producerInfoById = {}
itemByIdCache = {}
remainingRelevantProductIds = {}
remainingRelevantItemCount = 0
firstRelevantSchematicId = nil
dumpedSchematicId = nil
selectedItemId = nil
currentView = "status"
currentResultsPage = 0
currentDetailPage = 0
scanSummary = "Waiting to scan"

_loadCo = nil
_loadArgs = nil
_yieldCounter = 0

function bumpYield()
    _yieldCounter = _yieldCounter + 1
    if _yieldCounter % BATCH == 0 then
        local runningCo, isMain = coroutine.running()
        if runningCo ~= nil and not isMain then
            coroutine.yield()
        end
    end
end

function getItemYielded(itemId)
    if itemByIdCache[itemId] ~= nil then
        return itemByIdCache[itemId]
    end
    local item = system.getItem(itemId)
    itemByIdCache[itemId] = item
    bumpYield()
    return item
end

function getRecipesYielded(itemId)
    local recipes = system.getRecipes(itemId) or {}
    bumpYield()
    return recipes
end

function safeText(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n;|]", " ")
    return text
end

function clipLabel(text, maxLength)
    text = safeText(text)
    maxLength = tonumber(maxLength or 0) or 0
    if maxLength <= 0 or string.len(text) <= maxLength then
        return text
    end
    if maxLength <= 3 then
        return string.sub(text, 1, maxLength)
    end
    return string.sub(text, 1, maxLength - 3) .. "..."
end

function sortedKeys(t)
    local keys = {}
    for key in pairs(t or {}) do
        keys[#keys + 1] = key
        if #keys % BATCH == 0 then
            bumpYield()
        end
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

function shallowValue(value)
    local valueType = type(value)
    if valueType ~= "table" then
        return tostring(value)
    end

    local keys = sortedKeys(value)
    local parts = {}
    for i = 1, math.min(5, #keys) do
        local key = keys[i]
        parts[#parts + 1] = tostring(key) .. ":" .. type(value[key])
    end
    return string.format("{count=%d %s}", #keys, table.concat(parts, ", "))
end

function appendLine(lines, text)
    lines[#lines + 1] = safeText(text)
end

function hasDatabank()
    return databank ~= nil
end

function serializeValue(value)
    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    end
    if valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end
    if valueType == "string" then
        return string.format("%q", value)
    end
    if valueType ~= "table" then
        return "nil"
    end

    local isArray = true
    local maxIndex = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            isArray = false
            break
        end
        if key > maxIndex then
            maxIndex = key
        end
        bumpYield()
    end

    local parts = {}
    if isArray then
        for i = 1, maxIndex do
            parts[#parts + 1] = serializeValue(value[i])
            bumpYield()
        end
    else
        for _, key in ipairs(sortedKeys(value)) do
            parts[#parts + 1] = "[" .. serializeValue(key) .. "]=" .. serializeValue(value[key])
            bumpYield()
        end
    end

    return "{" .. table.concat(parts, ",") .. "}"
end

function deserializeValue(serialized)
    if serialized == nil or serialized == "" then
        return nil
    end

    local loader, loadErr = load(serialized)
    if loader == nil then
        system.print("cache load error: " .. tostring(loadErr))
        return nil
    end

    return loader()
end

function walkTree(itemId, visited, callback, stopState)
    if stopState and stopState.done then
        return
    end
    if not itemId or visited[itemId] then
        return
    end

    visited[itemId] = true
    local item = getItemYielded(itemId)
    if not item or item.id == nil or item.id <= 0 then
        return
    end

    callback(item)
    if stopState and stopState.done then
        return
    end
    bumpYield()

    for _, childId in pairs(item.childIds or {}) do
        if childId then
            walkTree(childId, visited, callback, stopState)
        end
        if stopState and stopState.done then
            return
        end
        bumpYield()
    end
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

function summarizeTopLevel(value)
    local scalarLines = {}
    local tableLines = {}
    for _, key in ipairs(sortedKeys(value)) do
        local childValue = value[key]
        if type(childValue) == "table" then
            tableLines[#tableLines + 1] = tostring(key) .. "=" .. shallowValue(childValue)
        else
            scalarLines[#scalarLines + 1] = tostring(key) .. "=" .. tostring(childValue)
        end
    end
    return scalarLines, tableLines
end

function collectTopLevelTermData(value, term)
    local hits = {}
    local refs = {}
    local seenRefs = {}
    for _, key in ipairs(sortedKeys(value)) do
        local childValue = value[key]
        local keyText = tostring(key)
        local lowerKey = keyText:lower()
        if lowerKey:find(term, 1, true) then
            hits[#hits + 1] = keyText .. "=" .. shallowValue(childValue)
            if type(childValue) == "table" then
                collectRefsFromNode(childValue, keyText, refs, seenRefs, 0, {})
            end
        elseif type(childValue) == "string" and childValue:lower():find(term, 1, true) then
            hits[#hits + 1] = keyText .. "=" .. childValue
        end
        bumpYield()
    end
    return hits, refs
end

function collectTermHits(value, path, hits, depth, visited, terms)
    if type(value) ~= "table" or depth > 2 then
        return
    end
    if visited[value] then
        return
    end
    visited[value] = true

    for _, key in ipairs(sortedKeys(value)) do
        local childValue = value[key]
        local keyText = tostring(key)
        local childPath = path ~= "" and (path .. "." .. keyText) or keyText
        local lowerPath = childPath:lower()

        if matchesAnyTerm(lowerPath, terms) then
            hits[#hits + 1] = childPath .. "=" .. shallowValue(childValue)
        elseif type(childValue) == "string" and matchesAnyTerm(childValue, terms) then
            hits[#hits + 1] = childPath .. "=" .. childValue
        end

        if type(childValue) == "table" then
            collectTermHits(childValue, childPath, hits, depth + 1, visited, terms)
        end
        bumpYield()
    end

    visited[value] = nil
end

function addItemRef(refs, seenRefs, node, sourcePath)
    if type(node) ~= "table" then
        return
    end

    local refId = tonumber(node.id or node.itemId or 0)
    if not refId or refId <= 0 then
        return
    end

    local quantity = node.quantity or node.qty or node.amount or 0
    local refKey = tostring(refId) .. "|" .. tostring(quantity) .. "|" .. tostring(sourcePath or "")
    if seenRefs[refKey] then
        return
    end
    seenRefs[refKey] = true

    local refItem = getItemYielded(refId)
    refs[#refs + 1] = {
        id = refId,
        name = displayName(refItem),
        quantity = quantity,
        sourcePath = sourcePath or "",
    }
end

function collectRefsFromNode(node, sourcePath, refs, seenRefs, depth, visited)
    if type(node) ~= "table" or depth > 2 then
        return
    end
    if visited[node] then
        return
    end
    visited[node] = true

    addItemRef(refs, seenRefs, node, sourcePath)

    for _, key in ipairs(sortedKeys(node)) do
        local childValue = node[key]
        if type(childValue) == "table" then
            collectRefsFromNode(childValue, sourcePath, refs, seenRefs, depth + 1, visited)
        end
        bumpYield()
    end

    visited[node] = nil
end

function collectRefsForTerm(value, path, refs, depth, visited, term, seenRefs)
    if type(value) ~= "table" or depth > 3 then
        return
    end
    if visited[value] then
        return
    end
    visited[value] = true

    for _, key in ipairs(sortedKeys(value)) do
        local childValue = value[key]
        local keyText = tostring(key)
        local childPath = path ~= "" and (path .. "." .. keyText) or keyText
        local lowerPath = childPath:lower()

        if type(childValue) == "table" then
            if lowerPath:find(term, 1, true) then
                collectRefsFromNode(childValue, childPath, refs, seenRefs, 0, {})
            end
            collectRefsForTerm(childValue, childPath, refs, depth + 1, visited, term, seenRefs)
        end
        bumpYield()
    end

    visited[value] = nil
end

function summarizeRefs(prefix, refs)
    local lines = {}
    for _, ref in ipairs(refs or {}) do
        local quantityText = ""
        if ref.quantity and tonumber(ref.quantity or 0) and tonumber(ref.quantity or 0) > 0 then
            quantityText = " x" .. tostring(ref.quantity)
        end
        local sourceText = ""
        if ref.sourcePath and ref.sourcePath ~= "" then
            sourceText = " @" .. ref.sourcePath
        end
        appendLine(lines, string.format("%s: %s (%s)%s%s", prefix, ref.name, tostring(ref.id), quantityText, sourceText))
        bumpYield()
    end
    return lines
end

function collectRelevantSchematicRefsForItem(item)
    local refs = {}
    local hits = {}
    local seen = {}

    for _, schematicRef in ipairs(item.schematics or {}) do
        local schematicId = tonumber(schematicRef)
        local info = schematicId and relevantSchematics[schematicId] or nil
        if info and not seen[schematicId] then
            seen[schematicId] = true
            refs[#refs + 1] = {
                id = schematicId,
                name = info.name,
                quantity = 0,
                sourcePath = "item.schematics",
            }
            hits[#hits + 1] = string.format("relevant=%s (%s)", info.name, tostring(schematicId))
        end
        bumpYield()
    end

    return hits, refs
end

function mergeRefs(targetRefs, sourceRefs, seenRefs)
    for _, ref in ipairs(sourceRefs or {}) do
        local refKey = tostring(ref.id or "") .. "|" .. tostring(ref.quantity or 0) .. "|" .. tostring(ref.sourcePath or "")
        if not seenRefs[refKey] then
            seenRefs[refKey] = true
            targetRefs[#targetRefs + 1] = ref
        end
        bumpYield()
    end
end

function collectIdListRefs(idList, sourcePath)
    local refs = {}
    local seenRefs = {}
    for index, rawId in ipairs(idList or {}) do
        local refId = tonumber(rawId or 0)
        if refId and refId > 0 then
            local refItem = getItemYielded(refId)
            mergeRefs(refs, {
                {
                    id = refId,
                    name = displayName(refItem),
                    quantity = 0,
                    sourcePath = tostring(sourcePath or "list") .. "." .. tostring(index),
                }
            }, seenRefs)
        end
        bumpYield()
    end
    return refs
end

function collectFlatIdRefs(idList, sourcePath)
    local refs = {}
    local seenIds = {}
    for index, rawId in ipairs(idList or {}) do
        local refId = tonumber(rawId or 0)
        if refId and refId > 0 and not seenIds[refId] then
            seenIds[refId] = true
            refs[#refs + 1] = {
                id = refId,
                name = "",
                quantity = 0,
                sourcePath = tostring(sourcePath or "list") .. "." .. tostring(index),
            }
        end
        bumpYield()
    end
    return refs
end

function classifyProducerBucket(producerRef)
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

function bucketFromOrderedList(orderedBuckets)
    if #orderedBuckets == 0 then
        return "Unknown"
    end
    if #orderedBuckets == 1 then
        return orderedBuckets[1]
    end
    return "Mixed"
end

function getProducerInfo(producerId)
    local cached = producerInfoById[producerId]
    if cached ~= nil then
        return cached
    end

    local producerItem = getItemYielded(producerId)
    cached = {
        id = producerId,
        name = displayName(producerItem),
        tier = producerItem and producerItem.tier or 0,
        classId = producerItem and producerItem.classId or 0,
    }
    cached.bucket = classifyProducerBucket(cached)
    producerInfoById[producerId] = cached
    return cached
end

function buildProductRecipeData(productId, recipes)
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
                local producerInfo = getProducerInfo(producerId)
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
            bumpYield()
        end
    end

    return {
        recipeCount = #recipes,
        producerRefs = producerRefs,
        bucket = bucketFromOrderedList(orderedBuckets),
    }
end

function collectProducerRefs(recipe)
    local recipeData = buildProductRecipeData(0, { recipe })
    return recipeData.producerRefs or {}
end

function getProductRecipeData(productId, knownRecipes)
    local cached = productRecipeDataByItemId[productId]
    if cached ~= nil then
        return cached
    end

    local recipes = knownRecipes or getRecipesYielded(productId)
    cached = buildProductRecipeData(productId, recipes)
    productRecipeDataByItemId[productId] = cached
    return cached
end

function pushDumpLine(lines, text, maxLines)
    if #lines >= maxLines then
        return false
    end
    lines[#lines + 1] = safeText(text)
    return true
end

function dumpLuaValue(path, value, depth, visited, lines, maxDepth, maxLines)
    if #lines >= maxLines then
        return
    end

    local valueType = type(value)
    if valueType ~= "table" then
        pushDumpLine(lines, path .. " = " .. tostring(value), maxLines)
        bumpYield()
        return
    end

    if visited[value] then
        pushDumpLine(lines, path .. " = <visited>", maxLines)
        bumpYield()
        return
    end

    if depth >= maxDepth then
        pushDumpLine(lines, path .. " = " .. shallowValue(value), maxLines)
        bumpYield()
        return
    end

    visited[value] = true
    pushDumpLine(lines, path .. " = {", maxLines)
    for _, key in ipairs(sortedKeys(value)) do
        if #lines >= maxLines then
            break
        end
        local childValue = value[key]
        local childPath = path .. "." .. tostring(key)
        dumpLuaValue(childPath, childValue, depth + 1, visited, lines, maxDepth, maxLines)
        bumpYield()
    end
    if #lines < maxLines then
        pushDumpLine(lines, path .. " }", maxLines)
    end
    visited[value] = nil
end

function printDumpLines(prefix, lines)
    local chunk = {}
    for _, line in ipairs(lines or {}) do
        chunk[#chunk + 1] = line
        if #chunk >= 2 then
            system.print(prefix .. " " .. table.concat(chunk, " || "))
            chunk = {}
            bumpYield()
        end
    end
    if #chunk > 0 then
        system.print(prefix .. " " .. table.concat(chunk, " || "))
        bumpYield()
    end
end

function summarizeIdList(values)
    local ids = {}
    for _, rawValue in ipairs(values or {}) do
        ids[#ids + 1] = tostring(tonumber(rawValue or 0) or rawValue)
        bumpYield()
    end
    if #ids == 0 then
        return "[]"
    end
    return "[" .. table.concat(ids, ", ") .. "]"
end

function appendTokenWithinLimit(tokens, token, limit)
    local nextLength = string.len(table.concat(tokens, ";"))
    if #tokens > 0 then
        nextLength = nextLength + 1
    end
    nextLength = nextLength + string.len(token or "")
    if nextLength > (limit or SCREEN_INPUT_LIMIT) then
        return false
    end
    tokens[#tokens + 1] = token
    return true
end

function dumpFirstRelevantSchematicToChat()
    if dumpedSchematicId ~= nil then
        return
    end
    if firstRelevantSchematicId == nil then
        system.print("[schem] no relevant schematic found")
        dumpedSchematicId = 0
        return
    end

    local item = getItemYielded(firstRelevantSchematicId)
    if not item then
        system.print("[schem] failed to load first relevant schematic")
        dumpedSchematicId = -1
        return
    end

    local info = relevantSchematics[firstRelevantSchematicId] or {}
    local lines = {}
    pushDumpLine(lines, string.format("BEGIN %s (%s)", displayName(item), tostring(item.id)), 80)
    pushDumpLine(lines, string.format("productRefs=%d industryRefs=%d", #(info.productRefs or {}), #(info.industryRefs or {})), 80)

    for _, refLine in ipairs(summarizeRefs("product", info.productRefs or {})) do
        pushDumpLine(lines, refLine, 80)
    end
    for _, refLine in ipairs(summarizeRefs("industry unit", info.industryRefs or {})) do
        pushDumpLine(lines, refLine, 80)
    end
    for _, hit in ipairs(info.productHits or {}) do
        pushDumpLine(lines, "product hit: " .. hit, 80)
    end
    for _, hit in ipairs(info.industryHits or {}) do
        pushDumpLine(lines, "industry hit: " .. hit, 80)
    end

    if #lines < 80 then
        dumpLuaValue("item", item, 0, {}, lines, 3, 80)
    end
    if #lines >= 80 then
        pushDumpLine(lines, "... truncated ...", 81)
    end
    printDumpLines("[schem]", lines)
    dumpedSchematicId = item.id
end

function addSchematicResult(item, industryHits, productHits, industryRefs, productRefs)
    local scalarLines, tableLines = summarizeTopLevel(item)

    local entry = {
        id = item.id,
        name = displayName(item),
        branch = "Schematics",
        itemType = item.type or "",
        tier = item.tier or "",
        size = item.size or "",
        displayClassId = item.displayClassId or 0,
        childCount = #(item.childIds or {}),
        recipeCount = 0,
        matchedRecipeCount = 0,
        matches = {},
        itemScalarLines = scalarLines,
        itemTableLines = tableLines,
        itemIndustryHits = industryHits,
        itemProductHits = productHits,
        itemIndustryRefs = industryRefs,
        itemProductRefs = productRefs,
        sourceSchematics = {},
    }

    scanResults[#scanResults + 1] = entry
    resultByItemId[item.id] = entry
end

function addResolvedProductResult(itemId)
    local sourceSchematics = schematicProductsByItemId[itemId] or {}
    if #sourceSchematics == 0 or resultByItemId[itemId] ~= nil then
        return
    end

    local item = getItemYielded(itemId)
    if not item or item.id == nil or item.id <= 0 then
        return
    end

    local productRecipeData = getProductRecipeData(itemId)
    local productBucket = productRecipeData.bucket or "Unknown"

    local itemIndustryHits = {}
    itemIndustryHits[#itemIndustryHits + 1] = "industryBucket=" .. tostring(productBucket)
    for _, producerRef in ipairs(productRecipeData.producerRefs or {}) do
        itemIndustryHits[#itemIndustryHits + 1] = string.format(
            "recipe.producer=%s (%s) tier=%s",
            tostring(producerRef.name),
            tostring(producerRef.id),
            tostring(producerRef.tier or "")
        )
    end

    local itemSchematicHits = {
        "sourceSchematics.count=" .. tostring(#sourceSchematics),
    }

    local entry = {
        id = item.id,
        name = displayName(item),
        branch = productBucket,
        itemType = item.type or "",
        tier = item.tier or "",
        size = item.size or "",
        displayClassId = item.displayClassId or 0,
        childCount = #(item.childIds or {}),
        recipeCount = productRecipeData.recipeCount or 0,
        matchedRecipeCount = #(productRecipeData.producerRefs or {}),
        matches = {},
        itemScalarLines = {},
        itemTableLines = {},
        itemIndustryHits = itemIndustryHits,
        itemSchematicHits = itemSchematicHits,
        itemIndustryRefs = productRecipeData.producerRefs or {},
        itemProductRefs = {},
        sourceSchematics = sourceSchematics,
    }

    scanResults[#scanResults + 1] = entry
    resultByItemId[item.id] = entry
end

function buildResolvedProductResults()
    local productIds = {}
    for productId in pairs(schematicProductsByItemId) do
        productIds[#productIds + 1] = productId
        bumpYield()
    end

    table.sort(productIds, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local limit = tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) or 0
    local processed = 0
    for _, productId in ipairs(productIds) do
        if limit > 0 and processed >= limit then
            break
        end
        addResolvedProductResult(productId)
        processed = processed + 1
        bumpYield()
    end
end

function isInterestingSchematic(item, productRefs, industryRefs, productHits, industryHits)
    if #productRefs > 0 or #industryRefs > 0 then
        return true
    end
    if #productHits > 0 or #industryHits > 0 then
        return true
    end
    return false
end

function schematicDumpScore(name, productRefs, industryRefs, productHits, industryHits)
    local score = 0
    if #industryRefs > 0 then
        score = score + 100
    end
    if #industryHits > 0 then
        score = score + 50
    end
    if tostring(name or ""):lower():find("fuel", 1, true) then
        score = score + 25
    end
    if #productRefs > 0 then
        score = score + 10
    end
    if #productHits > 0 then
        score = score + 5
    end
    return score
end

function collectRelevantSchematics()
    relevantSchematics = {}
    relevantSchematicList = {}
    schematicProductsByItemId = {}
    productRecipeDataByItemId = {}
    producerInfoById = {}
    remainingRelevantProductIds = {}
    remainingRelevantItemCount = 0
    firstRelevantSchematicId = nil
    local visitedNodeCount = 0
    local matchedSchematicCount = 0
    local uniqueProductCount = 0
    local rootItem = getItemYielded(SCHEMATIC_ROOT_ID)
    local rootChildIds = {}

    if rootItem and type(rootItem.childIds) == "table" then
        rootChildIds = rootItem.childIds
    end

    for childIndex, childId in ipairs(rootChildIds) do
        local item = getItemYielded(childId)
        visitedNodeCount = visitedNodeCount + 1

        if item and item.id ~= nil and item.id > 0 then
            local name = displayName(item)
            if hasRelevantSchematicName(name) then
                matchedSchematicCount = matchedSchematicCount + 1
                local productRefs = collectFlatIdRefs(item.products or {}, "item.products")

                relevantSchematics[item.id] = {
                    id = item.id,
                    name = name,
                    industryHits = {},
                    productHits = {},
                    industryRefs = {},
                    productRefs = productRefs,
                }
                relevantSchematicList[#relevantSchematicList + 1] = relevantSchematics[item.id]

                for _, productRef in ipairs(productRefs) do
                    if schematicProductsByItemId[productRef.id] == nil then
                        schematicProductsByItemId[productRef.id] = {}
                        uniqueProductCount = uniqueProductCount + 1
                    end
                    schematicProductsByItemId[productRef.id][#schematicProductsByItemId[productRef.id] + 1] = {
                        schematicId = item.id,
                        schematicName = name,
                        quantity = productRef.quantity or 0,
                    }
                    bumpYield()
                end

                if firstRelevantSchematicId == nil then
                    firstRelevantSchematicId = item.id
                end
            end
        end
        bumpYield()
    end

    table.sort(relevantSchematicList, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    for productId in pairs(schematicProductsByItemId) do
        remainingRelevantProductIds[productId] = true
        remainingRelevantItemCount = remainingRelevantItemCount + 1
        bumpYield()
    end
end

function summarizeProducts(recipe)
    local lines = {}
    for _, product in ipairs(recipe.products or {}) do
        local item = getItemYielded(product.id)
        local quantity = product.quantity or 0
        appendLine(lines, string.format("product: %s (%s) x%s", displayName(item), tostring(product.id), tostring(quantity)))
    end
    return lines
end

function summarizeIngredients(recipe)
    local lines = {}
    for _, ingredient in ipairs(recipe.ingredients or {}) do
        local item = getItemYielded(ingredient.id)
        local quantity = ingredient.quantity or 0
        local marker = relevantSchematics[ingredient.id] and " [relevant schematic]" or ""
        appendLine(lines, string.format("ingredient: %s (%s) x%s%s", displayName(item), tostring(ingredient.id), tostring(quantity), marker))
    end
    return lines
end

function collectRecipeMatchDetails(recipe, recipeIndex)
    local producerRefs = collectProducerRefs(recipe)
    local industryHits = {}
    for _, producerRef in ipairs(producerRefs) do
        industryHits[#industryHits + 1] = "producer=" .. tostring(producerRef.name) .. " (" .. tostring(producerRef.id) .. ")"
    end

    local schematicMatches = {}
    for _, ingredient in ipairs(recipe.ingredients or {}) do
        if relevantSchematics[ingredient.id] then
            schematicMatches[#schematicMatches + 1] = {
                id = ingredient.id,
                name = relevantSchematics[ingredient.id].name,
                quantity = ingredient.quantity or 0,
            }
        end
    end

    local productMatches = {}
    for _, product in ipairs(recipe.products or {}) do
        local sourceSchematics = schematicProductsByItemId[product.id]
        if sourceSchematics then
            local productItem = getItemYielded(product.id)
            productMatches[#productMatches + 1] = {
                id = product.id,
                name = displayName(productItem),
                quantity = product.quantity or 0,
                schematics = sourceSchematics,
            }
        end
    end

    local hasMatch = #industryHits > 0 or #schematicMatches > 0 or #productMatches > 0
    if not hasMatch then
        return nil
    end

    local scalarLines, tableLines = summarizeTopLevel(recipe)

    return {
        index = recipeIndex,
        industryHits = industryHits,
        producerRefs = producerRefs,
        schematicMatches = schematicMatches,
        productMatches = productMatches,
        scalarLines = scalarLines,
        tableLines = tableLines,
        ingredientLines = summarizeIngredients(recipe),
        productLines = summarizeProducts(recipe),
    }
end

function addMatchingItem(branchLabel, item)
    local sourceSchematics = schematicProductsByItemId[item.id] or {}
    if #sourceSchematics == 0 then
        return
    end

    if remainingRelevantProductIds[item.id] then
        remainingRelevantProductIds[item.id] = nil
        remainingRelevantItemCount = math.max(0, remainingRelevantItemCount - 1)
    end

    local productRecipeData = getProductRecipeData(item.id)
    local recipes = productRecipeData.recipes or {}

    local matches = {}
    for recipeIndex, recipe in ipairs(recipes) do
        local matchDetail = collectRecipeMatchDetails(recipe, recipeIndex)
        if matchDetail then
            matches[#matches + 1] = matchDetail
        end
        bumpYield()
    end

    local itemIndustryHits = {}
    for _, producerRef in ipairs(productRecipeData.producerRefs or {}) do
        itemIndustryHits[#itemIndustryHits + 1] = string.format(
            "recipe.producer=%s (%s) tier=%s",
            tostring(producerRef.name),
            tostring(producerRef.id),
            tostring(producerRef.tier or "")
        )
    end

    local itemSchematicHits = {}
    itemSchematicHits[#itemSchematicHits + 1] = "sourceSchematics.count=" .. tostring(#sourceSchematics)

    local scalarLines, tableLines = summarizeTopLevel(item)

    local entry = {
        id = item.id,
        name = displayName(item),
        branch = branchLabel,
        itemType = item.type or "",
        tier = item.tier or "",
        size = item.size or "",
        displayClassId = item.displayClassId or 0,
        childCount = #(item.childIds or {}),
        recipeCount = #recipes,
        matchedRecipeCount = #matches,
        matches = matches,
        itemScalarLines = scalarLines,
        itemTableLines = tableLines,
        itemIndustryHits = itemIndustryHits,
        itemSchematicHits = itemSchematicHits,
        itemIndustryRefs = productRecipeData.producerRefs or {},
        itemProductRefs = {},
        sourceSchematics = sourceSchematics,
    }

    scanResults[#scanResults + 1] = entry
    resultByItemId[item.id] = entry
end

function scanCandidateBranch(rootId, branchLabel)
    local stopState = { done = remainingRelevantItemCount <= 0 }
    walkTree(rootId, {}, function(item)
        addMatchingItem(branchLabel, item)
        if remainingRelevantItemCount <= 0 then
            stopState.done = true
        end
        bumpYield()
    end, stopState)
end

function renderStatus(message)
    currentView = "status"
    scanSummary = message or scanSummary
    screen.setScriptInput("status;" .. safeText(scanSummary))
end

function getEntrySourceCount(entry)
    local sourceCount = tonumber(entry and entry.sourceCount or 0) or 0
    if sourceCount > 0 then
        return sourceCount
    end
    return #((entry and entry.sourceSchematics) or {})
end

function buildResultListLabel(entry)
    return string.format(
        "%s [%s]",
        clipLabel(entry.name or "Unknown item", 48),
        tostring(entry.branch or "Unknown")
    )
end

function buildResultPageStarts()
    local starts = {}
    local count = #scanResults
    if count <= 0 then
        return { 1 }
    end

    local startIndex = 1
    while startIndex <= count do
        starts[#starts + 1] = startIndex
        startIndex = startIndex + RESULTS_PER_PAGE
    end

    return starts
end

function renderResults(page)
    currentView = "results"
    currentResultsPage = math.max(0, tonumber(page) or 0)

    local count = #scanResults
    local pageStarts = buildResultPageStarts()
    local maxPage = math.max(0, #pageStarts - 1)
    if currentResultsPage > maxPage then
        currentResultsPage = maxPage
    end

    local tokens = {
        "results",
        tostring(currentResultsPage),
        tostring(maxPage + 1),
        tostring(count),
        safeText(scanSummary),
    }

    local startIndex = pageStarts[currentResultsPage + 1] or 1
    local endIndex = count
    if currentResultsPage < maxPage then
        endIndex = (pageStarts[currentResultsPage + 2] or (count + 1)) - 1
    end
    for index = startIndex, endIndex do
        local entry = scanResults[index]
        local label = buildResultListLabel(entry)
        if not appendTokenWithinLimit(tokens, safeText(label) .. "|" .. tostring(entry.id), SCREEN_INPUT_LIMIT) then
            break
        end
    end

    screen.setScriptInput(table.concat(tokens, ";"))
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

function ensureEntryDetailData(entry)
    if not entry or tonumber(entry.recipeCount or 0) <= 0 then
        return
    end
    if #(entry.matches or {}) > 0 and #(entry.itemIndustryRefs or {}) > 0 then
        return
    end

    local recipes = getRecipesYielded(entry.id)
    local productRecipeData = getProductRecipeData(entry.id, recipes)
    entry.recipeCount = #recipes
    entry.itemIndustryRefs = productRecipeData.producerRefs or {}

    local itemIndustryHits = {
        "industryBucket=" .. tostring(productRecipeData.bucket or entry.branch or "Unknown"),
    }
    for _, producerRef in ipairs(productRecipeData.producerRefs or {}) do
        itemIndustryHits[#itemIndustryHits + 1] = string.format(
            "recipe.producer=%s (%s) tier=%s",
            tostring(producerRef.name),
            tostring(producerRef.id),
            tostring(producerRef.tier or "")
        )
    end
    entry.itemIndustryHits = itemIndustryHits

    local matches = {}
    for recipeIndex, recipe in ipairs(recipes) do
        local matchDetail = collectRecipeMatchDetails(recipe, recipeIndex)
        if matchDetail then
            matches[#matches + 1] = matchDetail
        end
        bumpYield()
    end
    entry.matches = matches
    entry.matchedRecipeCount = #matches
end

function buildDetailLines(entry)
    ensureEntryDetailData(entry)

    local lines = {}
    appendLine(lines, string.format("Branch: %s", entry.branch))
    appendLine(lines, string.format("Item ID: %s", tostring(entry.id)))
    appendLine(lines, string.format("Type: %s", tostring(entry.itemType)))
    appendLine(lines, string.format("Tier: %s", tostring(entry.tier)))
    appendLine(lines, string.format("Matched recipes: %d", tonumber(entry.matchedRecipeCount or 0) or 0))
    appendLine(lines, "Producers: " .. joinProducerNames(entry.itemIndustryRefs or {}))

    for _, source in ipairs(entry.sourceSchematics or {}) do
        appendLine(lines, string.format(
            "source schematic: %s (%s) x%s",
            source.schematicName or "Unknown schematic",
            tostring(source.schematicId or ""),
            tostring(source.quantity or 0)
        ))
    end
    if #(entry.sourceSchematics or {}) == 0 and tonumber(entry.sourceCount or 0) > 0 then
        appendLine(lines, string.format("source schematics: %d cached", tonumber(entry.sourceCount or 0) or 0))
    end

    for _, match in ipairs(entry.matches or {}) do
        appendLine(lines, string.format("Recipe %d", match.index))
        appendLine(lines, "  Producers: " .. joinProducerNames(match.producerRefs or {}))
        for _, schematic in ipairs(match.schematicMatches or {}) do
            appendLine(lines, string.format("  schematic %s (%s) x%s", schematic.name, tostring(schematic.id), tostring(schematic.quantity)))
        end
        for _, product in ipairs(match.productMatches or {}) do
            appendLine(lines, string.format("  product match %s (%s) x%s", product.name, tostring(product.id), tostring(product.quantity)))
            for _, source in ipairs(product.schematics or {}) do
                appendLine(lines, string.format(
                    "    via schematic %s (%s) x%s",
                    source.schematicName or "Unknown schematic",
                    tostring(source.schematicId or ""),
                    tostring(source.quantity or 0)
                ))
            end
        end
        for _, line in ipairs(match.ingredientLines or {}) do
            appendLine(lines, "  " .. line)
        end
        for _, line in ipairs(match.productLines or {}) do
            appendLine(lines, "  " .. line)
        end
    end

    return lines
end

function renderDetail(itemId, page)
    local entry = resultByItemId[tonumber(itemId or 0)]
    if not entry then
        renderStatus("Selected item no longer available")
        return
    end

    currentView = "detail"
    selectedItemId = entry.id
    currentDetailPage = math.max(0, tonumber(page) or 0)

    local detailLines = buildDetailLines(entry)
    local count = #detailLines
    local maxPage = 0
    if count > 0 then
        maxPage = math.max(0, math.ceil(count / DETAIL_LINES_PER_PAGE) - 1)
    end
    if currentDetailPage > maxPage then
        currentDetailPage = maxPage
    end

    local tokens = {
        "detail",
        tostring(entry.id),
        tostring(currentDetailPage),
        tostring(DETAIL_LINES_PER_PAGE),
        tostring(count),
        safeText(entry.name),
    }

    local startIndex = currentDetailPage * DETAIL_LINES_PER_PAGE + 1
    local endIndex = math.min(startIndex + DETAIL_LINES_PER_PAGE - 1, count)
    for index = startIndex, endIndex do
        if not appendTokenWithinLimit(tokens, detailLines[index], SCREEN_INPUT_LIMIT) then
            break
        end
    end

    screen.setScriptInput(table.concat(tokens, ";"))
end

function sortScanResults()
    table.sort(scanResults, function(a, b)
        local aKey = a.branch:lower() .. "|" .. a.name:lower()
        local bKey = b.branch:lower() .. "|" .. b.name:lower()
        return aKey < bKey
    end)
end

function buildBucketSummary()
    local counts = {
        ["Honeycomb"] = 0,
        ["Chemical"] = 0,
        ["Glass Furnace"] = 0,
        ["Mixed"] = 0,
        ["Unknown"] = 0,
    }

    for _, entry in ipairs(scanResults or {}) do
        local branch = tostring(entry.branch or "")
        if counts[branch] == nil then
            counts[branch] = 0
        end
        counts[branch] = counts[branch] + 1
        bumpYield()
    end

    local parts = {}
    for _, branch in ipairs({ "Honeycomb", "Chemical", "Glass Furnace" }) do
        parts[#parts + 1] = branch .. "=" .. tostring(counts[branch] or 0)
    end
    if (counts["Mixed"] or 0) > 0 then
        parts[#parts + 1] = "Mixed=" .. tostring(counts["Mixed"])
    end
    if (counts["Unknown"] or 0) > 0 then
        parts[#parts + 1] = "Unknown=" .. tostring(counts["Unknown"])
    end

    return table.concat(parts, " ")
end

function makeCachedMatch(match)
    return {
        index = match.index,
        industryHits = match.industryHits or {},
        schematicMatches = match.schematicMatches or {},
        productMatches = match.productMatches or {},
        ingredientLines = match.ingredientLines or {},
        productLines = match.productLines or {},
    }
end

function makeCachedEntry(entry)
    return {
        id = entry.id,
        name = entry.name,
        branch = entry.branch,
        itemType = entry.itemType,
        tier = entry.tier,
        size = entry.size,
        displayClassId = entry.displayClassId,
        childCount = 0,
        recipeCount = entry.recipeCount,
        matchedRecipeCount = entry.matchedRecipeCount,
        sourceCount = getEntrySourceCount(entry),
        itemIndustryHits = {},
        itemProductHits = {},
        itemSchematicHits = {},
        itemIndustryRefs = {},
        itemProductRefs = {},
        sourceSchematics = {},
        matches = {},
    }
end

function sanitizeCacheField(value)
    local text = tostring(value or "")
    text = text:gsub("[\r\n|]", " ")
    return text
end

function makeCompactCachedLine(entry)
    local fields = {
        tostring(entry.id or 0),
        sanitizeCacheField(entry.name),
        sanitizeCacheField(entry.branch),
        sanitizeCacheField(entry.itemType),
        sanitizeCacheField(entry.tier),
        sanitizeCacheField(entry.size),
        tostring(entry.displayClassId or 0),
        tostring(entry.recipeCount or 0),
        tostring(entry.matchedRecipeCount or 0),
        tostring(getEntrySourceCount(entry)),
    }
    return table.concat(fields, "|")
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

function parseCompactCachedLine(line)
    local fields = splitCacheLine(tostring(line or ""))
    local entryId = tonumber(fields[1] or 0)
    if not entryId or entryId <= 0 then
        return nil
    end

    return {
        id = entryId,
        name = fields[2] or "",
        branch = fields[3] or "Unknown",
        itemType = fields[4] or "",
        tier = fields[5] or "",
        size = fields[6] or "",
        displayClassId = tonumber(fields[7] or 0) or 0,
        childCount = 0,
        recipeCount = tonumber(fields[8] or 0) or 0,
        matchedRecipeCount = tonumber(fields[9] or 0) or 0,
        sourceCount = tonumber(fields[10] or 0) or 0,
        itemIndustryHits = {},
        itemProductHits = {},
        itemSchematicHits = {},
        itemIndustryRefs = {},
        itemProductRefs = {},
        sourceSchematics = {},
        matches = {},
    }
end

function getCacheMetaKey()
    return CACHE_KEY .. ":meta"
end

function getCacheChunkKey(index)
    return CACHE_KEY .. ":chunk:" .. tostring(index)
end

function buildCompactCachePayload(maxChunkLength)
    local chunkLimit = tonumber(maxChunkLength or 12000) or 12000
    local chunks = {}
    local currentChunkLines = {}
    local currentChunkLength = 0

    for _, entry in ipairs(scanResults) do
        local line = makeCompactCachedLine(makeCachedEntry(entry))
        local extraLength = #line
        if currentChunkLength > 0 then
            extraLength = extraLength + 1
        end

        if currentChunkLength > 0 and currentChunkLength + extraLength > chunkLimit then
            chunks[#chunks + 1] = table.concat(currentChunkLines, "\n")
            currentChunkLines = {}
            currentChunkLength = 0
        end

        currentChunkLines[#currentChunkLines + 1] = line
        currentChunkLength = currentChunkLength + #line
        if #currentChunkLines > 1 then
            currentChunkLength = currentChunkLength + 1
        end
        bumpYield()
    end

    if #currentChunkLines > 0 then
        chunks[#chunks + 1] = table.concat(currentChunkLines, "\n")
    end

    return {
        format = "compact_v1",
        version = CACHE_VERSION,
        generatedAt = system.getUtcTime(),
        scanSummary = scanSummary,
        schematicCount = #relevantSchematicList,
        resultCount = #scanResults,
        chunkCount = #chunks,
    }, chunks
end

function restoreCachePayload(payload)
    if type(payload) ~= "table" or tonumber(payload.version or 0) ~= CACHE_VERSION then
        return false
    end

    scanResults = {}
    resultByItemId = {}
    for _, entry in ipairs(payload.results or {}) do
        local cachedEntry = makeCachedEntry(entry)
        scanResults[#scanResults + 1] = cachedEntry
        resultByItemId[tonumber(cachedEntry.id or 0)] = cachedEntry
        bumpYield()
    end

    relevantSchematicList = {}
    relevantSchematics = {}

    scanSummary = tostring(payload.scanSummary or "")
    if scanSummary == "" then
        scanSummary = string.format("schematics=%d products=%d", tonumber(payload.schematicCount or 0) or 0, #scanResults)
    end
    scanSummary = scanSummary .. " [cached]"
    selectedItemId = nil
    currentResultsPage = 0
    currentDetailPage = 0
    return true
end

function saveCacheToDatabank()
    if tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) > 0 then
        return false
    end
    if not hasDatabank() then
        return false
    end

    local meta, chunks = buildCompactCachePayload(12000)
    databank.setStringValue(getCacheMetaKey(), "return " .. serializeValue(meta))
    for index, chunk in ipairs(chunks or {}) do
        databank.setStringValue(getCacheChunkKey(index), chunk)
        bumpYield()
    end
    system.print(string.format("cache saved: chunks=%d results=%d", #chunks, #scanResults))
    return true
end

function loadCacheFromDatabank()
    if tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) > 0 then
        return false
    end
    if not hasDatabank() then
        return false
    end

    local meta = deserializeValue(databank.getStringValue(getCacheMetaKey()))
    if type(meta) == "table" and tostring(meta.format or "") == "compact_v1" and tonumber(meta.version or 0) == CACHE_VERSION then
        scanResults = {}
        resultByItemId = {}
        for index = 1, tonumber(meta.chunkCount or 0) or 0 do
            local chunk = databank.getStringValue(getCacheChunkKey(index))
            for line in tostring(chunk or ""):gmatch("[^\n]+") do
                local entry = parseCompactCachedLine(line)
                if entry then
                    scanResults[#scanResults + 1] = entry
                    resultByItemId[entry.id] = entry
                end
                bumpYield()
            end
        end

        relevantSchematicList = {}
        relevantSchematics = {}
        scanSummary = tostring(meta.scanSummary or "")
        if scanSummary == "" then
            scanSummary = string.format("schematics=%d products=%d", tonumber(meta.schematicCount or 0) or 0, #scanResults)
        end
        scanSummary = scanSummary .. " [cached]"
        selectedItemId = nil
        currentResultsPage = 0
        currentDetailPage = 0
        return true
    end

    local serialized = databank.getStringValue(CACHE_KEY)
    local payload = deserializeValue(serialized)
    if payload == nil then
        return false
    end

    return restoreCachePayload(payload)
end

function _scanCoroutine()
    scanResults = {}
    resultByItemId = {}
    relevantSchematics = {}
    relevantSchematicList = {}
    schematicProductsByItemId = {}
    firstRelevantSchematicId = nil
    dumpedSchematicId = nil
    _yieldCounter = 0

    renderStatus("Scan schematics")
    collectRelevantSchematics()
    if ENABLE_DEBUG_DUMPS then
        renderStatus("Dump first schematic")
        dumpFirstRelevantSchematicToChat()
    end

    if DEBUG_ONLY then
        scanSummary = "debug only"
        system.print(scanSummary)
        renderStatus(scanSummary)
        return
    end

    renderStatus("Resolve products")
    buildResolvedProductResults()

    sortScanResults()

    if tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) > 0 then
        scanSummary = string.format(
            "schematics=%d products=%d testLimit=%d %s",
            #relevantSchematicList,
            #scanResults,
            tonumber(MAX_PRODUCTS_TO_RESOLVE or 0),
            buildBucketSummary()
        )
    else
        scanSummary = string.format(
            "schematics=%d products=%d %s",
            #relevantSchematicList,
            #scanResults,
            buildBucketSummary()
        )
    end
    system.print(scanSummary)
    renderStatus("Save cache")
    saveCacheToDatabank()
    renderResults(0)
end

function startScan(forceRescan)
    local shouldForceRescan = forceRescan == true
    if not shouldForceRescan and loadCacheFromDatabank() then
        renderResults(0)
        return
    end

    if shouldForceRescan then
        renderStatus("Rescan")
    elseif hasDatabank() then
        renderStatus("Scan databank miss")
    else
        renderStatus("Start scan")
    end

    _loadCo = coroutine.create(_scanCoroutine)
    _loadArgs = {}
    unit.setTimer("coTick", 0.05)
end

screen.setScriptInput("ping:" .. loadingCheck)
screen.activate()
unit.setTimer("initScreen", 1)
