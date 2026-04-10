SCHEMATIC_ROOT_ID = 2332967944
CONSUMABLES_ROOT_ID = 1464163325
PARTS_ROOT_ID = 1237953170
DEBUG_SCHEMATIC_ID = 2479827059
DEBUG_ONLY = false
ENABLE_DEBUG_DUMPS = false
SCREEN_INPUT_LIMIT = 900
DEBUG_MARKER = "DBG20260409M"
CACHE_KEY = "hierarchy_scan_cache_v1"
CACHE_VERSION = 1
CACHE_CHUNK_LIMIT = 2500
CACHE_WRITE_FRAME_DELAY = 5
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

        if (
            elementClass:find("industry", 1, true)
            or elementClass:find("furnace", 1, true)
            or elementClass:find("recycler", 1, true)
            or elementClass:find("refiner", 1, true)
        ) and type(slot.getItemId) == "function" then
            linkedIndustryElements[#linkedIndustryElements + 1] = slot
        end
    end
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
remainingRelevantProductIds = {}
remainingRelevantItemCount = 0
firstRelevantSchematicId = nil
dumpedSchematicId = nil
selectedItemId = nil
currentView = "status"
currentResultsPage = 0
currentDetailPage = 0
currentResultsFilterId = ""
scanSummary = "Waiting to scan"
stopRequested = false
linkedIndustryFilters = {}
linkedIndustryFilterByKey = {}

_loadCo = nil
_loadArgs = nil
_yieldCounter = 0

function getIndustryKindCode(value)
    local lowerText = tostring(value or ""):lower()
    if lowerText:find("glass furnace", 1, true) then
        return "gf"
    end
    if lowerText:find("refiner", 1, true) then
        return "rf"
    end
    if lowerText:find("recycler", 1, true) then
        return "rc"
    end
    if lowerText:find("chemical", 1, true) then
        return "ch"
    end
    if lowerText:find("honeycomb", 1, true) then
        return "hc"
    end
    return ""
end

function getIndustryKindLabel(kindCode)
    if kindCode == "gf" then
        return "Glass Furnace"
    end
    if kindCode == "rf" then
        return "Refiner"
    end
    if kindCode == "rc" then
        return "Recycler"
    end
    if kindCode == "ch" then
        return "Chemical"
    end
    if kindCode == "hc" then
        return "Honeycomb"
    end
    return ""
end

function collectProducerFilterKinds(producerRefs)
    local producerFilterKinds = {}
    local seenKinds = {}
    for _, producerRef in ipairs(producerRefs or {}) do
        local kindCode = tostring(producerRef and producerRef.bucket or "")
        if kindCode == "" then
            kindCode = getIndustryKindCode(producerRef and producerRef.name or "")
        else
            kindCode = getIndustryKindCode(kindCode)
        end
        if kindCode ~= "" and not seenKinds[kindCode] then
            producerFilterKinds[#producerFilterKinds + 1] = kindCode
            seenKinds[kindCode] = true
        end
    end
    table.sort(producerFilterKinds)
    return producerFilterKinds
end

function buildProducerFilterKindSet(producerFilterKinds)
    local kindSet = {}
    for _, kindCode in ipairs(producerFilterKinds or {}) do
        if tostring(kindCode or "") ~= "" then
            kindSet[tostring(kindCode)] = true
        end
    end
    return kindSet
end

function buildLinkedIndustryFilters()
    linkedIndustryFilters = {}
    linkedIndustryFilterByKey = {}

    local seenKeys = {}
    for _, slot in ipairs(linkedIndustryElements or {}) do
        local itemId = tonumber(slot and slot.getItemId and slot.getItemId() or 0) or 0
        if itemId > 0 then
            local item = system.getItem(itemId)
            local kindCode = getIndustryKindCode((item and displayName(item) or "") .. " " .. tostring(slot.elementClass or ""))
            if kindCode ~= "" and not seenKeys[kindCode] then
                local entry = {
                    key = kindCode,
                    itemId = itemId,
                    label = getIndustryKindLabel(kindCode),
                    iconPath = item and item.iconPath or "",
                }
                linkedIndustryFilters[#linkedIndustryFilters + 1] = entry
                linkedIndustryFilterByKey[kindCode] = entry
                seenKeys[kindCode] = true
            end
        end
    end

    table.sort(linkedIndustryFilters, function(a, b)
        local aLabel = tostring(a and a.label or "")
        local bLabel = tostring(b and b.label or "")
        if aLabel == bLabel then
            return tostring(a and a.key or "") < tostring(b and b.key or "")
        end
        return aLabel < bLabel
    end)
end

function buildLinkedIndustryFiltersRenderDefs()
    local defs = { "{" }
    for _, def in ipairs(linkedIndustryFilters or {}) do
        defs[#defs + 1] = string.format(
            "{ key = %q, label = %q, iconPath = %q },",
            tostring(def.key or ""),
            safeText(def.label or ""),
            tostring(def.iconPath or "")
        )
    end
    defs[#defs + 1] = "}"
    return table.concat(defs, "\n")
end

buildLinkedIndustryFilters()

function bumpYield()
    _yieldCounter = _yieldCounter + 1
    if _yieldCounter % BATCH == 0 then
        local runningCo, isMain = coroutine.running()
        if runningCo ~= nil and not isMain then
            coroutine.yield()
        end
    end
end

cache = HierarchyCache.new({
    cacheKey            = CACHE_KEY,
    cacheVersion        = CACHE_VERSION,
    chunkLimit          = CACHE_CHUNK_LIMIT,
    writeFrameDelay     = CACHE_WRITE_FRAME_DELAY,
    databank            = databank,
    cooperativeYieldFn  = bumpYield,
    frameYieldFn        = yieldFrame,
})

function getItemYielded(itemId)
    return cache:getItem(itemId)
end

function getRecipesYielded(itemId)
    return cache:getRecipes(itemId)
end

function hasDatabank()
    return cache:hasDatabank()
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

function summarizeTopLevel(value)
    local scalarLines = {}
    local tableLines = {}
    for _, key in ipairs(sortedKeys(value, bumpYield, BATCH)) do
        local childValue = value[key]
        if type(childValue) == "table" then
            tableLines[#tableLines + 1] = tostring(key) .. "=" .. shallowValue(childValue, bumpYield, BATCH)
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
    for _, key in ipairs(sortedKeys(value, bumpYield, BATCH)) do
        local childValue = value[key]
        local keyText = tostring(key)
        local lowerKey = keyText:lower()
        if lowerKey:find(term, 1, true) then
            hits[#hits + 1] = keyText .. "=" .. shallowValue(childValue, bumpYield, BATCH)
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

    for _, key in ipairs(sortedKeys(value, bumpYield, BATCH)) do
        local childValue = value[key]
        local keyText = tostring(key)
        local childPath = path ~= "" and (path .. "." .. keyText) or keyText
        local lowerPath = childPath:lower()

        if matchesAnyTerm(lowerPath, terms) then
            hits[#hits + 1] = childPath .. "=" .. shallowValue(childValue, bumpYield, BATCH)
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

    for _, key in ipairs(sortedKeys(node, bumpYield, BATCH)) do
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

    for _, key in ipairs(sortedKeys(value, bumpYield, BATCH)) do
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

function getProducerInfo(producerId)
    return cache:getProducerInfo(producerId)
end

function buildProductRecipeData(productId, recipes)
    return cache:buildProductRecipeData(productId, recipes)
end

function collectProducerRefs(recipe)
    local recipeData = cache:buildProductRecipeData(0, { recipe })
    return recipeData.producerRefs or {}
end

function getProductRecipeData(productId, knownRecipes)
    return cache:getProductRecipeData(productId, knownRecipes)
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
        pushDumpLine(lines, path .. " = " .. shallowValue(value, bumpYield, BATCH), maxLines)
        bumpYield()
        return
    end

    visited[value] = true
    pushDumpLine(lines, path .. " = {", maxLines)
    for _, key in ipairs(sortedKeys(value, bumpYield, BATCH)) do
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
        producerFilterKinds = collectProducerFilterKinds(industryRefs),
        itemProductRefs = productRefs,
        sourceSchematic = nil,
    }

    scanResults[#scanResults + 1] = entry
    resultByItemId[item.id] = entry
end

function addResolvedProductResult(itemId)
    local sourceSchematic = schematicProductsByItemId[itemId]
    if sourceSchematic == nil or resultByItemId[itemId] ~= nil then
        return
    end

    local item = getItemYielded(itemId)
    if not item or item.id == nil or item.id <= 0 then
        return
    end

    local productRecipeData = getProductRecipeData(itemId)
    local productBucket = productRecipeData.bucket or ""

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
        "sourceSchematic=" .. tostring(sourceSchematic.schematicId or 0),
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
        producerFilterKinds = collectProducerFilterKinds(productRecipeData.producerRefs or {}),
        itemProductRefs = {},
        sourceSchematic = sourceSchematic,
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
    local total = #productIds
    for _, productId in ipairs(productIds) do
        if limit > 0 and processed >= limit then
            break
        end
        addResolvedProductResult(productId)
        processed = processed + 1
        if shouldRenderProgress(processed, total, 25) then
            renderProgress("Resolve products", processed, total)
        end
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
    cache:resetRuntime()
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

    renderProgress("Scan schematics", 0, #rootChildIds)

    for childIndex, childId in ipairs(rootChildIds) do
        local item = getItemYielded(childId)
        visitedNodeCount = visitedNodeCount + 1
        if shouldRenderProgress(childIndex, #rootChildIds, 5) then
            renderProgress("Scan schematics", childIndex, #rootChildIds)
        end

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
                        uniqueProductCount = uniqueProductCount + 1
                    end
                    schematicProductsByItemId[productRef.id] = {
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

    announceWorkPhase("Organize schematic scan data")
    table.sort(relevantSchematicList, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    announceWorkPhase("Index scanned products")
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
        local sourceSchematic = schematicProductsByItemId[product.id]
        if sourceSchematic then
            local productItem = getItemYielded(product.id)
            productMatches[#productMatches + 1] = {
                id = product.id,
                name = displayName(productItem),
                quantity = product.quantity or 0,
                sourceSchematic = sourceSchematic,
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
    local sourceSchematic = schematicProductsByItemId[item.id]
    if sourceSchematic == nil then
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
    itemSchematicHits[#itemSchematicHits + 1] = "sourceSchematic=" .. tostring(sourceSchematic.schematicId or 0)

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
        producerFilterKinds = collectProducerFilterKinds(productRecipeData.producerRefs or {}),
        itemProductRefs = {},
        sourceSchematic = sourceSchematic,
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
    lastOutput = ""
    screen.setScriptInput("status;" .. safeText(scanSummary) .. ";0;0")
end

function announceWorkPhase(message)
    renderStatus(message)
    yieldFrame()
end

function renderIdle(message)
    currentView = "idle"
    scanSummary = message or scanSummary
    lastOutput = ""
    screen.setScriptInput("idle;" .. safeText(scanSummary))
end

function renderProgress(message, current, total)
    currentView = "status"
    scanSummary = message or scanSummary
    lastOutput = ""
    screen.setScriptInput(table.concat({
        "status",
        safeText(scanSummary),
        tostring(tonumber(current or 0) or 0),
        tostring(tonumber(total or 0) or 0),
    }, ";"))
end

function shouldRenderProgress(current, total, interval)
    current = tonumber(current or 0) or 0
    total = tonumber(total or 0) or 0
    interval = math.max(1, tonumber(interval or 1) or 1)
    return current <= 1 or current >= total or current % interval == 0
end

function getEntrySourceCount(entry)
    if entry and entry.sourceSchematic ~= nil then
        return 1
    end
    return 0
end

function buildResultsFilterKey(activeFilterSet)
    local parts = {}
    for kindCode, isActive in pairs(activeFilterSet or {}) do
        if isActive and linkedIndustryFilterByKey[kindCode] ~= nil then
            parts[#parts + 1] = tostring(kindCode)
        end
    end
    table.sort(parts)
    return table.concat(parts, ".")
end

function normalizeResultsFilterKey(filterKey)
    local keyText = tostring(filterKey or "")
    if keyText == "" or keyText == "all" then
        return ""
    end

    local activeFilterSet = {}
    for kindCode in keyText:gmatch("[^.]+") do
        if linkedIndustryFilterByKey[kindCode] ~= nil then
            activeFilterSet[kindCode] = true
        end
    end
    return buildResultsFilterKey(activeFilterSet)
end

function buildResultsFilterKeySet(filterKey)
    local activeFilterSet = {}
    local normalizedKey = normalizeResultsFilterKey(filterKey)
    if normalizedKey == "" then
        return activeFilterSet
    end

    for kindCode in normalizedKey:gmatch("[^.]+") do
        activeFilterSet[kindCode] = true
    end
    return activeFilterSet
end

function ensureEntryProducerFilterKinds(entry)
    if not entry then
        return {}
    end

    if entry.producerFilterKinds == nil then
        entry.producerFilterKinds = collectProducerFilterKinds(entry.itemIndustryRefs or {})
    end
    if #entry.producerFilterKinds == 0 and #(entry.itemIndustryRefs or {}) > 0 then
        entry.producerFilterKinds = collectProducerFilterKinds(entry.itemIndustryRefs or {})
    end
    if #entry.producerFilterKinds == 0 and entry.id ~= nil then
        local productRecipeData = getProductRecipeData(entry.id)
        entry.itemIndustryRefs = productRecipeData.producerRefs or entry.itemIndustryRefs or {}
        entry.producerFilterKinds = collectProducerFilterKinds(entry.itemIndustryRefs or {})
    end
    entry.producerFilterKindSet = buildProducerFilterKindSet(entry.producerFilterKinds)
    return entry.producerFilterKinds
end

function entryMatchesResultsFilter(entry, filterKey)
    local activeFilterSet = buildResultsFilterKeySet(filterKey)
    if next(activeFilterSet) == nil then
        return true
    end

    ensureEntryProducerFilterKinds(entry)
    for kindCode in pairs(activeFilterSet) do
        if entry.producerFilterKindSet[kindCode] == true then
            return true
        end
    end
    return false
end

function getFilteredScanResults()
    currentResultsFilterId = normalizeResultsFilterKey(currentResultsFilterId)
    if currentResultsFilterId == "" then
        return scanResults
    end

    local filtered = {}
    for _, entry in ipairs(scanResults or {}) do
        if entryMatchesResultsFilter(entry, currentResultsFilterId) then
            filtered[#filtered + 1] = entry
        end
        bumpYield()
    end
    return filtered
end

function setResultsFilter(filterKey)
    local normalizedKey = normalizeResultsFilterKey(filterKey)
    if normalizedKey == "" then
        currentResultsFilterId = ""
        currentResultsPage = 0
        return
    end

    local activeFilterSet = buildResultsFilterKeySet(currentResultsFilterId)
    if activeFilterSet[normalizedKey] then
        activeFilterSet[normalizedKey] = nil
    else
        activeFilterSet[normalizedKey] = true
    end
    currentResultsFilterId = buildResultsFilterKey(activeFilterSet)
    currentResultsPage = 0
end

function buildResultListLabel(entry)
    ensureEntryBasics(entry)
    return string.format(
        "%s [%s]",
        clipLabel(entry.name or "Unknown item", 48),
        tostring(entry.branch or "Unknown")
    )
end

function buildResultPageStarts(entries)
    local starts = {}
    local count = #(entries or {})
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
    currentResultsFilterId = normalizeResultsFilterKey(currentResultsFilterId)
    currentResultsPage = math.max(0, tonumber(page) or 0)

    local filteredResults = getFilteredScanResults()
    local count = #filteredResults
    local pageStarts = buildResultPageStarts(filteredResults)
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
        currentResultsFilterId ~= "" and currentResultsFilterId or "all",
    }

    local startIndex = pageStarts[currentResultsPage + 1] or 1
    local endIndex = count
    if currentResultsPage < maxPage then
        endIndex = (pageStarts[currentResultsPage + 2] or (count + 1)) - 1
    end
    for index = startIndex, endIndex do
        local entry = filteredResults[index]
        local label = buildResultListLabel(entry)
        if not appendTokenWithinLimit(tokens, safeText(label) .. "|" .. tostring(entry.id), SCREEN_INPUT_LIMIT) then
            break
        end
    end

    lastOutput = ""
    screen.setScriptInput(table.concat(tokens, ";"))
end

function ensureEntryBasics(entry)
    if not entry or (entry.name ~= nil and entry.name ~= "") then
        return
    end

    local item = getItemYielded(entry.id)
    if not item or item.id == nil or item.id <= 0 then
        entry.name = entry.name or ("Item " .. tostring(entry.id or 0))
        entry.itemType = entry.itemType or ""
        entry.tier = entry.tier or ""
        entry.size = entry.size or ""
        entry.displayClassId = entry.displayClassId or 0
        entry.childCount = entry.childCount or 0
        return
    end

    entry.name = displayName(item)
    entry.itemType = item.type or ""
    entry.tier = item.tier or ""
    entry.size = item.size or ""
    entry.displayClassId = item.displayClassId or 0
    entry.childCount = #(item.childIds or {})
end

function ensureEntryDetailData(entry)
    if not entry then
        return
    end
    ensureEntryBasics(entry)
    if entry.detailLoaded then
        return
    end
    if entry.match ~= nil and #(entry.itemIndustryRefs or {}) > 0 then
        entry.detailLoaded = true
        return
    end

    local recipes = getRecipesYielded(entry.id)
    local productRecipeData = getProductRecipeData(entry.id, recipes)
    entry.recipeCount = #recipes
    entry.itemIndustryRefs = productRecipeData.producerRefs or {}
    entry.producerFilterKinds = collectProducerFilterKinds(entry.itemIndustryRefs or {})
    entry.producerFilterKindSet = buildProducerFilterKindSet(entry.producerFilterKinds)

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

    local match = nil
    for recipeIndex, recipe in ipairs(recipes) do
        local matchDetail = collectRecipeMatchDetails(recipe, recipeIndex)
        if matchDetail then
            match = matchDetail
            break
        end
        bumpYield()
    end
    entry.match = match
    entry.matchedRecipeCount = match ~= nil and 1 or 0
    entry.detailLoaded = true
end

function appendWrappedDetailLine(lines, text, maxLength, continuationIndent)
    local normalizedText = tostring(text or "")
    local lineLimit = math.max(24, tonumber(maxLength or 0) or 72)
    local nextIndent = tostring(continuationIndent or "")

    if normalizedText == "" then
        appendLine(lines, "")
        return
    end

    local currentLine = ""
    local isFirstLine = true
    for word in normalizedText:gmatch("%S+") do
        if currentLine == "" then
            currentLine = (isFirstLine and "" or nextIndent) .. word
        else
            local candidate = currentLine .. " " .. word
            if #candidate <= lineLimit then
                currentLine = candidate
            else
                appendLine(lines, currentLine)
                currentLine = nextIndent .. word
                isFirstLine = false
            end
        end
    end

    if currentLine ~= "" then
        appendLine(lines, currentLine)
    end
end

function buildDetailLines(entry)
    ensureEntryDetailData(entry)

    local lines = {}
    appendLine(lines, string.format("Branch: %s", entry.branch))
    appendLine(lines, string.format("Item ID: %s", tostring(entry.id)))
    appendLine(lines, string.format("Type: %s", tostring(entry.itemType)))
    appendLine(lines, string.format("Tier: %s", tostring(entry.tier)))
    appendWrappedDetailLine(lines, "Producers: " .. joinProducerNames(entry.itemIndustryRefs or {}), 84, "           ")

    local source = entry.sourceSchematic
    if source ~= nil then
        if (source.schematicName == nil or source.schematicName == "") and source.schematicId ~= nil then
            local schematicItem = getItemYielded(source.schematicId)
            source.schematicName = displayName(schematicItem)
        end
        appendWrappedDetailLine(lines, string.format(
            "Schematic: %s (%s) x%s",
            source.schematicName or "Unknown schematic",
            tostring(source.schematicId or ""),
            tostring(source.quantity or 0)
        ), 84, "           ")
    end

    local match = entry.match
    if match ~= nil then
        appendLine(lines, "Recipe")
        for _, schematic in ipairs(match.schematicMatches or {}) do
            appendLine(lines, string.format("  schematic %s (%s) x%s", schematic.name, tostring(schematic.id), tostring(schematic.quantity)))
        end
        for _, product in ipairs(match.productMatches or {}) do
            appendLine(lines, string.format("  product match %s (%s) x%s", product.name, tostring(product.id), tostring(product.quantity)))
            local productSource = product.sourceSchematic
            if productSource ~= nil then
                appendLine(lines, string.format(
                    "    via schematic %s (%s) x%s",
                    productSource.schematicName or "Unknown schematic",
                    tostring(productSource.schematicId or ""),
                    tostring(productSource.quantity or 0)
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
        "lines",
    }

    local startIndex = currentDetailPage * DETAIL_LINES_PER_PAGE + 1
    local endIndex = math.min(startIndex + DETAIL_LINES_PER_PAGE - 1, count)
    for index = startIndex, endIndex do
        if not appendTokenWithinLimit(tokens, detailLines[index], SCREEN_INPUT_LIMIT) then
            break
        end
    end

    lastOutput = ""
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
        ["Refiner"] = 0,
        ["Recycler"] = 0,
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
    for _, branch in ipairs({ "Honeycomb", "Chemical", "Glass Furnace", "Refiner", "Recycler" }) do
        parts[#parts + 1] = branch .. "=" .. tostring(counts[branch] or 0)
    end

    return table.concat(parts, " ")
end

function saveCacheToDatabank()
    if tonumber(MAX_PRODUCTS_TO_RESOLVE or 0) > 0 then
        return false
    end
    if not hasDatabank() then
        return false
    end

    announceWorkPhase("Prepare cache data")
    local meta, chunks = cache:buildCompactCachePayload(scanResults, relevantSchematicList, scanSummary)
    cache:clearExistingCacheData()
    renderProgress("Save cache", 0, #chunks)
    for index, chunk in ipairs(chunks or {}) do
        renderProgress("Save cache", index, #chunks)
        if not cache:writeDatabankStringVerified("chunk " .. tostring(index), cache:getCacheChunkKey(index), chunk) then
            renderStatus("Cache write failed at chunk " .. tostring(index))
            return false
        end
    end
    if not cache:writeDatabankStringVerified("meta", cache:getCacheMetaKey(), cache:buildCacheMetaString(meta)) then
        renderStatus("Cache write failed at meta")
        cache:clearDatabankKeySlow(cache:getCacheMetaKey())
        return false
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

    local result = cache:loadScanResults()
    if result then
        scanResults = result.scanResults
        resultByItemId = result.resultByItemId
        relevantSchematicList = {}
        relevantSchematics = {}
        scanSummary = result.scanSummary
        if scanSummary == "" then
            scanSummary = string.format("schematics=%d products=%d", result.schematicCount or 0, #scanResults)
        end
        scanSummary = scanSummary .. " [cached]"
        selectedItemId = nil
        currentResultsPage = 0
        currentDetailPage = 0
        return true
    end
    return false
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

    renderProgress("Resolve products", 0, 0)
    buildResolvedProductResults()

    announceWorkPhase("Organize resolved products")
    sortScanResults()

    announceWorkPhase("Build result summary")
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
    saveCacheToDatabank()
    renderResults(0)
end

function startScan(forceRescan)
    local shouldForceRescan = forceRescan == true
    stopRequested = false
    if not shouldForceRescan and hasDatabank() then
        renderProgress("Load cache", 0, 1)
    end
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
