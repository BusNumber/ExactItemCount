local addonName, ns = ...

-- The string table: every piece of text this addon displays, keyed symbolically. This
-- file is the base locale -- it defines every key and is what any client without a
-- translation shows. A translation is a sibling file whose first line names its own
-- client language, ns.NewLocale("xxXX"), and which assigns the keys it covers; whatever
-- it leaves out stays English. (CONTRIBUTING.md has the step-by-step, DESIGN.md the
-- reasoning.)
--
-- Rules for values:
--   * Keep every %s / %d placeholder. To reorder them, use the game's positional form
--     (%1$s, %2$d) -- the numbers refer to the English order.
--   * A value is one string on one line; non-ASCII text is plain UTF-8 (no BOM). The
--     \ddd escapes below are just UTF-8 bytes spelled out: \194\183 is the middle dot,
--     \226\128\148 the em dash, \226\128\166 the ellipsis.
--   * Where a count needs more than a singular/plural pair, the game's own plural escape
--     works inside a value: "%d |4match:matches;".
--
-- Deliberately NOT here (see DESIGN.md "Localization"): the "Exact Item Count" name,
-- the /eic command with its sub-command words (`find`, `locale`) and the locale
-- command's own answers, and the punctuation that glues segments together
-- (parentheses, the middle-dot separator, the colon after a label).
--
-- The test suite checks that every key the code reads is defined here, and that every
-- key here is read.
local L = ns.NewLocale("enUS")

-- ---------------------------------------------------------------------------
-- Tooltip section

-- Lead lines, rendered "<label>: <count> (<locations>)".
L["LEAD_TOTAL"]   = "Total items owned"
L["LEAD_AUCTION"] = "On auction"
L["LEAD_CRAFTED"] = "Crafted items"

-- Location-suffix tokens, rendered "(bags 2 · bank 1 · warband 3 · Liara 1)". Each %d
-- is that location's count; keep every token short -- the suffix is one tooltip line.
L["SUFFIX_BAGS"]       = "bags %d"
L["SUFFIX_BANK"]       = "bank %d"
L["SUFFIX_WARBAND"]    = "warband %d"
L["SUFFIX_BANKS"]      = "banks %d"     -- bank + warband bank merged into one token
L["SUFFIX_EQUIPPED"]   = "equipped %d"
L["SUFFIX_MAIL"]       = "mail %d"
L["SUFFIX_YOURS"]      = "yours %d"     -- your own listings, inside "On auction" only
L["SUFFIX_ALT"]        = "%s %d"        -- one other character: name, count
L["SUFFIX_ALTS_TOTAL"] = "alts %d"      -- every other character as one total
L["SUFFIX_ALTS_MORE"]  = "+%d alts %d"  -- the collapsed tail: how many characters, their sum

-- Breakdown-row label for gear with neither a crafting rank nor an upgrade track,
-- rendered "ilvl 645: 2". %d is the item level.
L["ROW_ILVL"] = "ilvl %d"

-- ---------------------------------------------------------------------------
-- Chat output of /eic find. Every line starts "Exact Item Count — "; these are the
-- lowercase continuations of that header.

L["CHAT_USAGE"]      = "/eic opens options \194\183 /eic find <name or item link> searches your counts"
L["CHAT_TOO_SHORT"]  = "type at least %d characters, or shift-click an item link."
L["CHAT_NO_MATCHES"] = 'no matches for "%s" in your scanned items.'
L["CHAT_MATCH_ONE"]  = '%d match for "%s":'    -- result count (always 1 here), the query
L["CHAT_MATCH_MANY"] = '%d matches for "%s":'
L["CHAT_MORE"]       = "\226\128\166and %d more \226\128\148 try a more specific name."
L["CHAT_ON_AUCTION"] = "on auction" -- tail of a result line: "[Item]: 5 (bags 5) — on auction: 3"

-- ---------------------------------------------------------------------------
-- Options panel

L["KEY_SHIFT"] = "Shift"
L["KEY_ALT"]   = "Alt"
L["KEY_CTRL"]  = "Ctrl"

-- Dropdown choices. The %s is the modifier key's name (one of the three above).
L["CHOICE_ALWAYS"]            = "Always show"
L["CHOICE_WHILE_HELD"]        = "Only while %s is held"
L["CHOICE_NEVER"]             = "Never"
L["CHOICE_ALTS_TOPN"]         = "Top N by count, merge the rest"
L["CHOICE_ALTS_ALL"]          = "All characters separately"
L["CHOICE_ALTS_TOTAL"]        = "Only the total across characters"
L["CHOICE_BANKS_SEPARATE"]    = "Always separately"
L["CHOICE_BANKS_UNLESS_HELD"] = "Merged unless %s is held"
L["CHOICE_BANKS_MERGED"]      = "Always merged"

L["HEADER_LOCATIONS"] = "Locations"
L["HEADER_COMPACT"]   = "Compact tooltip"

-- Each setting is a label plus the tooltip shown on hover (_TIP). Tooltips that quote a
-- label, a choice or a suffix token from this file ("On auction", "Top N by count",
-- "banks", "+K alts", "(bags 2 · bank 1)") should quote the translated wording.
L["OPT_BANK"]               = "Bank"
L["OPT_BANK_TIP"]           = "Items in this character's bank (snapshot taken while the bank is open)."
L["OPT_WARBAND"]            = "Warband bank"
L["OPT_WARBAND_TIP"]        = "Items in the account-wide warband bank (snapshot taken while the bank is open)."
L["OPT_EQUIPPED"]           = "Equipped items"
L["OPT_EQUIPPED_TIP"]       = "Items currently equipped on this character (gear plus profession tools and accessories)."
L["OPT_ALT_EQUIPPED"]       = "Include in count for alts"
L["OPT_ALT_EQUIPPED_TIP"]   = "Also count gear worn by your other characters, folded into each one's total. Uncheck to count only their bags and bank."
L["OPT_MAIL"]               = "Mail"
L["OPT_MAIL_TIP"]           = "Items in this character's mailbox (snapshot taken at the mailbox), plus items it has mailed to your other characters that haven't been collected yet."
L["OPT_ALTS"]               = "Other characters"
L["OPT_ALTS_TIP"]           = "Items on every other scanned character, bags and bank combined. Manage individual characters on the Characters page."
L["OPT_AUCTIONS"]           = "On auction"
L["OPT_AUCTIONS_TIP"]       = "Items you have listed on the auction house (snapshot taken while the auction house is open), shown as their own \"On auction\" line. Listings are never added to the owned total."
L["OPT_ALT_AUCTIONS"]       = "Include alts' auctions"
L["OPT_ALT_AUCTIONS_TIP"]   = "Also show items your other characters have listed, by name. Their listings are a snapshot from each character's last auction house visit, so they can be stale. Follows the Other characters setting above."
L["OPT_MODIFIER"]           = "Modifier key"
L["OPT_MODIFIER_TIP"]       = "The key the \"only while held\" options wait for. Note that Shift is also the game's compare-items key, so it flips while comparing gear."
L["OPT_SUFFIX"]             = "Location suffix"
L["OPT_SUFFIX_TIP"]         = "The dimmed per-location split after each count, like (bags 2 \194\183 bank 1)."
L["OPT_ROWS"]               = "Quality & item level rows"
L["OPT_ROWS_TIP"]           = "The per-rank and per-item-level breakdown rows under the total."
L["OPT_RECIPE_PRODUCT"]     = "Crafted item on recipes"
L["OPT_RECIPE_PRODUCT_TIP"] = "For recipes, also show the count of the crafted items the recipe is for."
L["OPT_ALTS_DETAIL"]        = "Other characters detail"
L["OPT_ALTS_DETAIL_TIP"]    = "How other characters appear in the location suffix."
L["OPT_ALTS_EXPAND"]        = "List all while key is held"
L["OPT_ALTS_EXPAND_TIP"]    = "While the modifier key (set above) is held, every character is listed separately in the suffix, whatever the detail mode above."
L["OPT_ALTS_TOPN"]          = "Named characters (top N)"
L["OPT_ALTS_TOPN_TIP"]      = "With \"Top N by count\" above: how many characters are named before the rest merge into one \"+K alts\" entry."
L["OPT_BANK_MERGE"]         = "Bank & warband in the suffix"
L["OPT_BANK_MERGE_TIP"]     = "Show bank and warband bank as separate suffix entries, or as one combined \"banks\" entry."
L["OPT_HIDE_ZERO"]          = "Hide when total is 0"
L["OPT_HIDE_ZERO_TIP"]      = "Skip the tooltip section entirely for items you own none of."

-- Panel footer. %s is the support link, then the addon's version number.
L["FOOTER_DONATE"]  = "Enjoying the addon? Buy me a coffee: %s"
L["FOOTER_VERSION"] = "Version %s"

-- ---------------------------------------------------------------------------
-- Characters page

L["CHAR_TITLE"]   = "Characters" -- the page's heading and its name in the options list
L["CHAR_HINT"]    = "The eye hides a character's items from the counts your other characters see. A character always counts its own bags and bank, and its data stays cached. Deleting removes the stored data; a deleted character is scanned again the next time it logs in with this addon."
L["CHAR_CURRENT"] = "(current)" -- tag after the logged-in character's name

-- One row's scan ages, "bags 2h ago · bank never · ...". Each %s is one of the AGO_
-- strings below, in the order bags, bank, mail, auctions.
L["CHAR_AGES"]   = "bags %s \194\183 bank %s \194\183 mail %s \194\183 auctions %s"
L["AGO_NEVER"]   = "never"
L["AGO_NOW"]     = "just now"
L["AGO_MINUTES"] = "%dm ago"
L["AGO_HOURS"]   = "%dh ago"
L["AGO_DAYS"]    = "%dd ago"

L["CHAR_DELETE_TIP"]   = "Delete this character's cached data"
L["CHAR_HIDDEN_TITLE"] = "Hidden from other characters"
L["CHAR_HIDDEN_TIP"]   = "This character's items are excluded from the counts your other characters see. Click to include them again."
L["CHAR_SHOWN_TITLE"]  = "Shown on other characters"
L["CHAR_SHOWN_TIP"]    = "This character's items count in the tooltips your other characters see. (A character always counts its own bags and bank.) Click to hide."

-- Confirmation prompt for the delete button; %s is the character's Name-Realm. Its
-- buttons use the game's own Delete / Cancel text.
L["POPUP_DELETE_CHAR"] = "Delete stored item counts for %s?"
