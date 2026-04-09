screen = nil
databank = nil
for _, v in pairs(_G) do
    if type(v) == "table" and v.isInClass then
        if v.isInClass("ScreenUnit") then
            screen = v
        elseif databank == nil and v.isInClass("DataBankUnit") then
            databank = v
        end
        if screen ~= nil and databank ~= nil then
            break
        end
    end
end

if screen == nil then
    system.print("Screen needs to be linked to programming board")
    unit.exit()
end

SCHEMATIC_ROOT_ID = 2332967944
CONSUMABLES_ROOT_ID = 1464163325
PARTS_ROOT_ID = 1237953170
DEBUG_SCHEMATIC_ID = 3077761447
DEBUG_ONLY = false
ENABLE_DEBUG_DUMPS = false
SCREEN_INPUT_LIMIT = 900
DEBUG_MARKER = "DBG20260409M"
CACHE_KEY = "hierarchy_scan_cache_v7"
CACHE_VERSION = 7
MAX_PRODUCTS_TO_RESOLVE = 1

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
    local text = tostring(value or "")
    text = text:gsub("[\r\n;|]", " ")
    return text
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

    local ok, value = pcall(loader)
    if not ok then
        system.print("cache exec error: " .. tostring(value))
        return nil
    end
    return value
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

function collectProducerRefs(recipe)
    local refs = {}
    local seenRefs = {}
    for _, producerId in ipairs(recipe.producers or {}) do
        local id = tonumber(producerId or 0)
        if id and id > 0 then
            local producerItem = getItemYielded(id)
            local ref = {
                id = id,
                name = displayName(producerItem),
                quantity = 0,
                sourcePath = "producers",
                tier = producerItem and producerItem.tier or 0,
                classId = producerItem and producerItem.classId or 0,
            }
            mergeRefs(refs, { ref }, seenRefs)
        end
        bumpYield()
    end
    return refs
end

function buildProductRecipeData(productId, recipes)
    recipes = recipes or {}
    local producerRefs = {}
    local seenRefs = {}

    for _, recipe in ipairs(recipes) do
        local recipeProducerRefs = collectProducerRefs(recipe)
        mergeRefs(producerRefs, recipeProducerRefs, seenRefs)
        bumpYield()
    end

    return {
        recipeCount = #recipes,
        producerRefs = producerRefs,
    }
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

function dumpDebugSchematicRecipeToChat(schematicId)
    local item = getItemYielded(schematicId)
    if not item then
        system.print("[" .. DEBUG_MARKER .. "] missing schematic " .. tostring(schematicId))
        return
    end

    local lines = {}
    pushDumpLine(lines, string.format("%s schematic=%s (%s)", DEBUG_MARKER, displayName(item), tostring(item.id)), 24)
    pushDumpLine(lines, string.format("schematic.products.count=%s", tostring(type(item.products) == "table" and #item.products or 0)), 24)

    local recipes = getRecipesYielded(schematicId)
    pushDumpLine(lines, "schematic.recipes.count=" .. tostring(#recipes), 24)

    local productId = nil
    if type(item.products) == "table" then
        productId = tonumber(item.products[1] or 0)
    end
    if productId and productId > 0 then
        local productItem = getItemYielded(productId)
        pushDumpLine(lines, string.format("product.id=%s", tostring(productId)), 24)
        pushDumpLine(lines, string.format("product.name=%s", displayName(productItem)), 24)
        if productItem then
            pushDumpLine(lines, string.format("product.type=%s tier=%s class=%s", tostring(productItem.type or ""), tostring(productItem.tier or ""), tostring(productItem.classId or "")), 24)
            if type(productItem.schematics) == "table" then
                pushDumpLine(lines, "product.schematics.count=" .. tostring(#productItem.schematics), 24)
            end
            if type(productItem.products) == "table" then
                pushDumpLine(lines, "product.products.count=" .. tostring(#productItem.products), 24)
            end
        end

        local productRecipes = getRecipesYielded(productId)
        pushDumpLine(lines, "product.recipes.count=" .. tostring(#productRecipes), 24)
        for recipeIndex, recipe in ipairs(productRecipes) do
            if #lines >= 24 then
                break
            end
            local scalarLines, tableLines = summarizeTopLevel(recipe)
            pushDumpLine(lines, "product.recipe." .. tostring(recipeIndex) .. ".scalars=" .. tostring(#scalarLines), 24)
            for i = 1, math.min(3, #scalarLines) do
                pushDumpLine(lines, "  " .. scalarLines[i], 24)
            end
            for i = 1, math.min(3, #tableLines) do
                pushDumpLine(lines, "  table " .. tableLines[i], 24)
            end
            bumpYield()
        end
    end

    if #lines >= 24 then
        pushDumpLine(lines, "... truncated ...", 25)
    end
    printDumpLines("[dbg]", lines)
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

    local itemIndustryHits = {}
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
        branch = "Products",
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

    system.print(string.format(
        "[%s] schem-scan start root=%s children=%d",
        DEBUG_MARKER,
        tostring(SCHEMATIC_ROOT_ID),
        #rootChildIds
    ))

    for childIndex, childId in ipairs(rootChildIds) do
        local item = getItemYielded(childId)
        visitedNodeCount = visitedNodeCount + 1
        if visitedNodeCount == 1 or visitedNodeCount % 10 == 0 or childIndex == #rootChildIds then
            system.print(string.format(
                "[%s] schem-scan child=%d/%d matched=%d uniqueProducts=%d",
                DEBUG_MARKER,
                childIndex,
                #rootChildIds,
                matchedSchematicCount,
                uniqueProductCount
            ))
        end

        if item and item.id ~= nil and item.id > 0 then
            local name = displayName(item)
            if hasRelevantSchematicName(name) then
                matchedSchematicCount = matchedSchematicCount + 1
                local productRefs = collectFlatIdRefs(item.products or {}, "item.products")
                system.print(string.format(
                    "[%s] schem-match %d name=%s products=%d",
                    DEBUG_MARKER,
                    matchedSchematicCount,
                    name,
                    #productRefs
                ))

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

    system.print(string.format(
        "[%s] schem-scan done nodes=%d matched=%d uniqueProducts=%d",
        DEBUG_MARKER,
        visitedNodeCount,
        matchedSchematicCount,
        uniqueProductCount
    ))
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

function renderResults(page)
    currentView = "results"
    currentResultsPage = math.max(0, tonumber(page) or 0)

    local count = #scanResults
    local maxPage = 0
    if count > 0 then
        maxPage = math.max(0, math.ceil(count / RESULTS_PER_PAGE) - 1)
    end
    if currentResultsPage > maxPage then
        currentResultsPage = maxPage
    end

    local tokens = {
        "results",
        tostring(currentResultsPage),
        tostring(RESULTS_PER_PAGE),
        tostring(count),
        safeText(scanSummary),
    }

    local startIndex = currentResultsPage * RESULTS_PER_PAGE + 1
    local endIndex = math.min(startIndex + RESULTS_PER_PAGE - 1, count)
    for index = startIndex, endIndex do
        local entry = scanResults[index]
        local label = string.format(
            "%s [%s] recipes=%d matched=%d sources=%d",
            entry.name,
            entry.branch,
            entry.recipeCount,
            entry.matchedRecipeCount,
            #(entry.sourceSchematics or {})
        )
        if not appendTokenWithinLimit(tokens, safeText(label) .. "|" .. tostring(entry.id), SCREEN_INPUT_LIMIT) then
            break
        end
    end

    screen.setScriptInput(table.concat(tokens, ";"))
end

function buildDetailLines(entry)
    local lines = {}
    appendLine(lines, string.format("Branch: %s", entry.branch))
    appendLine(lines, string.format("Item ID: %s", tostring(entry.id)))
    appendLine(lines, string.format("Type: %s", tostring(entry.itemType)))
    appendLine(lines, string.format("Tier: %s", tostring(entry.tier)))
    appendLine(lines, string.format("Size: %s", tostring(entry.size)))
    appendLine(lines, string.format("displayClassId: %s", tostring(entry.displayClassId)))
    appendLine(lines, string.format("childCount: %s", tostring(entry.childCount)))
    appendLine(lines, string.format("recipeCount: %d", entry.recipeCount))
    appendLine(lines, string.format("matchedRecipeCount: %d", entry.matchedRecipeCount))

    for _, line in ipairs(entry.itemScalarLines or {}) do
        appendLine(lines, "item " .. line)
    end
    for _, line in ipairs(entry.itemTableLines or {}) do
        appendLine(lines, "item table " .. line)
    end
    for _, line in ipairs(entry.itemIndustryHits or {}) do
        appendLine(lines, "item industry " .. line)
    end
    for _, line in ipairs(entry.itemProductHits or {}) do
        appendLine(lines, "item product " .. line)
    end
    for _, line in ipairs(entry.itemSchematicHits or {}) do
        appendLine(lines, "item schematic " .. line)
    end
    for _, line in ipairs(summarizeRefs("item industry unit", entry.itemIndustryRefs or {})) do
        appendLine(lines, line)
    end
    for _, line in ipairs(summarizeRefs("item product ref", entry.itemProductRefs or {})) do
        appendLine(lines, line)
    end
    for _, source in ipairs(entry.sourceSchematics or {}) do
        appendLine(lines, string.format(
            "source schematic: %s (%s) x%s",
            source.schematicName or "Unknown schematic",
            tostring(source.schematicId or ""),
            tostring(source.quantity or 0)
        ))
    end

    for _, match in ipairs(entry.matches or {}) do
        appendLine(lines, string.format("Recipe %d", match.index))
        for _, line in ipairs(match.scalarLines or {}) do
            appendLine(lines, "  " .. line)
        end
        for _, line in ipairs(match.tableLines or {}) do
            appendLine(lines, "  table " .. line)
        end
        for _, line in ipairs(match.industryHits or {}) do
            appendLine(lines, "  industry " .. line)
        end
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
    local matches = {}
    for _, match in ipairs(entry.matches or {}) do
        matches[#matches + 1] = makeCachedMatch(match)
        bumpYield()
    end

    return {
        id = entry.id,
        name = entry.name,
        branch = entry.branch,
        itemType = entry.itemType,
        tier = entry.tier,
        size = entry.size,
        displayClassId = entry.displayClassId,
        childCount = entry.childCount,
        recipeCount = entry.recipeCount,
        matchedRecipeCount = entry.matchedRecipeCount,
        itemIndustryHits = entry.itemIndustryHits or {},
        itemProductHits = entry.itemProductHits or {},
        itemSchematicHits = entry.itemSchematicHits or {},
        itemIndustryRefs = entry.itemIndustryRefs or {},
        itemProductRefs = entry.itemProductRefs or {},
        sourceSchematics = entry.sourceSchematics or {},
        matches = matches,
    }
end

function buildCachePayload()
    local results = {}
    for _, entry in ipairs(scanResults) do
        results[#results + 1] = makeCachedEntry(entry)
        bumpYield()
    end

    local schematics = {}
    for _, info in ipairs(relevantSchematicList) do
        schematics[#schematics + 1] = {
            id = info.id,
            name = info.name,
        }
        bumpYield()
    end

    return {
        version = CACHE_VERSION,
        generatedAt = system.getUtcTime(),
        scanSummary = scanSummary,
        results = results,
        schematics = schematics,
    }
end

function restoreCachePayload(payload)
    if type(payload) ~= "table" or tonumber(payload.version or 0) ~= CACHE_VERSION then
        return false
    end

    scanResults = payload.results or {}
    resultByItemId = {}
    for _, entry in ipairs(scanResults) do
        resultByItemId[tonumber(entry.id or 0)] = entry
        bumpYield()
    end

    relevantSchematicList = payload.schematics or {}
    relevantSchematics = {}
    for _, info in ipairs(relevantSchematicList) do
        if info.id then
            relevantSchematics[info.id] = info
        end
        bumpYield()
    end

    scanSummary = tostring(payload.scanSummary or "")
    if scanSummary == "" then
        scanSummary = string.format("schematics=%d products=%d", #relevantSchematicList, #scanResults)
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

    local serialized = "return " .. serializeValue(buildCachePayload())
    if #serialized > 30000 then
        system.print("cache too large: " .. tostring(#serialized) .. " bytes")
        return false
    end

    databank.setStringValue(CACHE_KEY, serialized)
    return true
end

function loadCacheFromDatabank()
    if tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) > 0 then
        return false
    end
    if not hasDatabank() then
        return false
    end

    local serialized = databank.getStringValue(CACHE_KEY)
    local payload = deserializeValue(serialized)
    if payload == nil then
        return false
    end

    return restoreCachePayload(payload)
end

function _scanCoroutine()
    system.print("[" .. DEBUG_MARKER .. "] start debugOnly=" .. tostring(DEBUG_ONLY))
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
        renderStatus("Dump debug schematic")
        dumpDebugSchematicRecipeToChat(DEBUG_SCHEMATIC_ID)
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
            "schematics=%d products=%d testLimit=%d",
            #relevantSchematicList,
            #scanResults,
            tonumber(MAX_PRODUCTS_TO_RESOLVE or 0)
        )
    else
        scanSummary = string.format(
            "schematics=%d products=%d",
            #relevantSchematicList,
            #scanResults
        )
    end
    system.print(scanSummary)
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
