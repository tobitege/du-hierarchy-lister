# DU Hierarchy Lister

This is a Dual Universe programming board script that builds a browseable list of products for five industry families:

- Honeycomb
- Chemical
- Glass Furnace
- Refiner
- Recycler

It is meant to answer a simple question:

"Which products belong to these industry groups on this server?"

It does that by scanning relevant schematic copies, collecting the products they unlock, checking which industry machines can produce those products, and then showing the result on a linked screen.

## License and Credits

MIT Licensed. Based on original script by @Leniver with further enhancements made (coroutines) by markosolo.

## Installation

Required are a programming board and a screen, highly suggest a databank, too, to cache data.
Deploy all 3 elements, link screen, databank AND core to the board.
Copy the content of the .json file to clipboard. Right-click the board, Advanced -> "Paste..."
If you work from the extracted `.lua` files instead, put [library_onStart.lua](/d:/github/du-hierarchy-lister/library_onStart.lua) into `library/onStart()` before `unit/onStart()`.

## What It Does

On startup, the board:

1. If a valid databank cache exists, it loads the cached results first.
2. Otherwise it inspects the direct children of the main schematic root in the DU item database.
3. Keeps only schematic copies that look relevant (by name) for:
   - `Pure`
   - `Product`
   - `Fuel`
4. Collects all product item IDs from those schematics.
5. For each product, asks DU which industry machines can make it.
6. Sorts the product into one of these buckets:
   - `Honeycomb`
   - `Chemical`
   - `Glass Furnace`
   - `Refiner`
   - `Recycler`
7. Stores a compact cache in the linked databank, if one is available.
8. Shows the list on the linked screen.

During longer scans, the screen may briefly show intermediate status messages such as organizing scanned data, indexing products, building the result summary, or preparing cache data. Those messages indicate that the script is still working between the main scan phases.

## Why It Scans

The script does not rely on a hardcoded item list.

That matters because custom servers may add, remove, or change items and schematics. The script scans live game data, so it can adapt to the server you are actually on.

## Cache Support

If a databank is linked, the script stores the scan result there.

That means:

- the first run can be slow
- later runs are much faster
- the `Rescan` button forces a fresh scan and refreshes the cache

Cache behaviour is managed by the `HierarchyCache` class in `library_onStart.lua`. The default cache key prefix and version are configured in `unit_onStart.lua` and passed to the class constructor:

- Cache key prefix: `hierarchy_scan_cache_v1`
- Cache version: `7`

The key prefix is used to store a meta record (`<prefix>:meta`) and one or more data chunks (`<prefix>:chunk:N`). If the version in the meta record does not match the configured version, the cache is treated as a miss and a fresh scan is performed.

If you wipe the databank, the script simply rebuilds the cache on the next run.

## What You Need To Link

Link these to the programming board:

- a screen
- a core
- optionally a databank for caching

The script can also detect linked industry devices for these five kinds:

- Honeycomb
- Chemical
- Glass Furnace
- Refiner
- Recycler

The main scan does not depend on those links for product discovery.

## Screen Controls

From the screen, you can:

- browse result pages with `Prev` and `Next`
- click an item to open its detail page
- use `Back` to return to the same result page you came from
- use `Rescan` to rebuild the data

## What The List Shows

Each row shows:

- the product name
- the detected industry bucket in brackets

Example:

- `Nitron Fuel [Chemical]`
- `Stained pattern brick 4 [Honeycomb]`

## What The Detail Page Shows

The detail page focuses on practical information:

- branch
- item ID
- type
- tier
- producer machines
- source schematic
- recipe ingredient/product lines

The goal is to make it easier to verify why a product was placed in a certain industry bucket.

## Known Limits

- The first live scan can still take a while.
- Cached entries are compact on purpose, so some detail data is rebuilt when you open an item.
- The script only targets the current five industry families listed above.
- The script expects products to resolve to one of the five supported industry families above.

## Files

Main script files:

- [library_onStart.lua](/d:/github/du-hierarchy-lister/library_onStart.lua)
- [unit_onStart.lua](/d:/github/du-hierarchy-lister/unit_onStart.lua)
- [unit_onTimer_initScreen.lua](/d:/github/du-hierarchy-lister/unit_onTimer_initScreen.lua)
- [unit_onTimer_coTick.lua](/d:/github/du-hierarchy-lister/unit_onTimer_coTick.lua)
- [system_onUpdate.lua](/d:/github/du-hierarchy-lister/system_onUpdate.lua)

Original source JSON:

- [markosolo_HiearchyLister-fixed.json](/d:/github/du-hierarchy-lister/markosolo_HiearchyLister-fixed.json)
