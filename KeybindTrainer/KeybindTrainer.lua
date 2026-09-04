-- Get the addon name and its private namespace table from the WoW engine
local addonName, addon = ...

-- Create the main addon frame (an invisible container that holds our UI)
local f = CreateFrame("Frame", "KeybindTrainerFrame", UIParent, "BackdropTemplate")

-- Stretch the frame to cover the entire screen
f:SetAllPoints(UIParent) 
-- Ensure the frame is drawn on top of all other UI elements (like bags, character sheet)
f:SetFrameStrata("TOOLTIP") 
-- Create a background texture for the entire screen
f.bg = f:CreateTexture(nil, "BACKGROUND")
-- Stretch the background to fill the frame
f.bg:SetAllPoints(true)
-- Set the color to black with 85% opacity (0.85 alpha) to darken the game world
f.bg:SetColorTexture(0, 0, 0, 0.85)

-- Create a texture object to display the spell/macro icon
f.icon = f:CreateTexture(nil, "ARTWORK")
-- Set the icon size to 64x64 pixels
f.icon:SetSize(64, 64)
-- Position the icon slightly above the true center of the screen (Y offset: 165)
f.icon:SetPoint("CENTER", 0, 165) 

-- Create a font string to display the name of the spell/macro
f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
-- Anchor the top of the text to the bottom of the icon, with a 10px gap
f.text:SetPoint("TOP", f.icon, "BOTTOM", 0, -10)
-- Set a default placeholder text
f.text:SetText("Press a bind")

-- Create a smaller gray font string to show the keybind as a reminder
f.bindText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
-- Anchor it just below the spell name
f.bindText:SetPoint("TOP", f.text, "BOTTOM", 0, -50)
-- Gray so it reads as a hint, not the main prompt
f.bindText:SetTextColor(0.2, 0.2, 0.2)
f.bindText:SetText("")

-- Hide the frame by default when the game loads
f:Hide()

-- Allow the frame to listen to keyboard events
f:EnableKeyboard(true)
-- Allow the frame to listen to mouse events
f:EnableMouse(true)
-- VERY IMPORTANT: Stop keyboard inputs from reaching the actual game while the frame is open.
-- This prevents you from actually casting spells or blowing cooldowns while training.
f:SetPropagateKeyboardInput(false) 

-- Table to store all valid abilities found on the action bars
local activeBinds = {}
-- Table to store the specific key combination(s) required for the currently displayed skill
local currentBindKeys = {}
-- Variable to remember the last chosen skill to prevent back-to-back duplicates
local lastBindIndex = -1
-- Per-session stats keyed by bind index: name, bindText, icon, hits, totalTime
local sessionStats = {}
-- GetTime() when the current prompt appeared (start of the reaction counter)
local promptStart = 0
-- GetTime() when the training session started
local sessionStart = 0

-- Results dialog shown after the player stops training (full screen height so the list rarely needs scrolling)
local results = CreateFrame("Frame", "KeybindTrainerResultsFrame", UIParent, "BackdropTemplate")
results:SetWidth(560)
results:SetPoint("TOP", UIParent, "TOP", 0, 0)
results:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
results:SetFrameStrata("DIALOG")
results:SetToplevel(true)
results:EnableMouse(true)
results:SetClampedToScreen(true)
results:Hide()
results:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})

results.title = results:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
results.title:SetPoint("TOP", 0, -18)
results.title:SetText("Training Results")

results.summary = results:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
results.summary:SetPoint("TOP", results.title, "BOTTOM", 0, -6)

local closeX = CreateFrame("Button", nil, results, "UIPanelCloseButton")
closeX:SetPoint("TOPRIGHT", -2, -2)
closeX:SetScript("OnClick", function() results:Hide() end)

-- Column headers aligned with the scroll rows below
local headerY = -68
local headerSpecs = {
    { text = "Ability",  x = 42 },
    { text = "Keybind",  x = 250 },
    { text = "Presses",  x = 370 },
    { text = "Avg Time", x = 450 },
}
for _, spec in ipairs(headerSpecs) do
    local fs = results:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", spec.x, headerY)
    fs:SetText(spec.text)
end

local scroll = CreateFrame("ScrollFrame", "KeybindTrainerResultsScroll", results, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 16, -88)
scroll:SetPoint("BOTTOMRIGHT", -36, 48)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(490, 1)
scroll:SetScrollChild(content)

scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
    local new = self:GetVerticalScroll() - (delta * 24)
    new = math.max(0, math.min(self:GetVerticalScrollRange(), new))
    self:SetVerticalScroll(new)
end)

local closeBtn = CreateFrame("Button", nil, results, "UIPanelButtonTemplate")
closeBtn:SetSize(100, 22)
closeBtn:SetPoint("BOTTOM", 0, 16)
closeBtn:SetText("Close")
closeBtn:SetScript("OnClick", function() results:Hide() end)

results:SetScript("OnShow", function(self)
    -- Stretch to the current screen height in case resolution or UI scale changed
    self:ClearAllPoints()
    self:SetPoint("TOP", UIParent, "TOP", 0, 0)
    self:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
    self:SetWidth(560)
    self:EnableKeyboard(true)
    self:Raise()
end)
results:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false)
        self:Hide()
    else
        -- Let gameplay keys through while reading the table
        self:SetPropagateKeyboardInput(true)
    end
end)
-- Also close via the default UI ESC handler if this frame is not capturing keys
tinsert(UISpecialFrames, "KeybindTrainerResultsFrame")

local resultRows = {}
local ROW_HEIGHT = 22

-- Each extra bar has a fixed slot range. Bar 1 pages/swaps (stances, stealth), so its
-- slot is read from the live button when possible. Binding names are what GetBindingKey uses.
-- Slot IDs: https://warcraft.wiki.gg/wiki/Action_slot
local actionBars = {
    { binding = "ACTIONBUTTON",           button = "ActionButton",              slotStart = nil }, -- Bar 1 (dynamic)
    { binding = "MULTIACTIONBAR1BUTTON",  button = "MultiBarBottomLeftButton",  slotStart = 61 },  -- Bar 2
    { binding = "MULTIACTIONBAR2BUTTON",  button = "MultiBarBottomRightButton", slotStart = 49 },  -- Bar 3
    { binding = "MULTIACTIONBAR3BUTTON",  button = "MultiBarRightButton",       slotStart = 25 },  -- Bar 4
    { binding = "MULTIACTIONBAR4BUTTON",  button = "MultiBarLeftButton",        slotStart = 37 },  -- Bar 5
    { binding = "MULTIACTIONBAR5BUTTON",  button = "MultiBar5Button",           slotStart = 145 }, -- Bar 6
    { binding = "MULTIACTIONBAR6BUTTON",  button = "MultiBar6Button",           slotStart = 157 }, -- Bar 7
    { binding = "MULTIACTIONBAR7BUTTON",  button = "MultiBar7Button",           slotStart = 169 }, -- Bar 8
}

-- Standalone modifier keys (ignore these; wait for the actual key of the combo)
local modifierKeys = {
    LSHIFT = true, RSHIFT = true, SHIFT = true,
    LCTRL = true, RCTRL = true, LCONTROL = true, RCONTROL = true, CTRL = true, CONTROL = true,
    LALT = true, RALT = true, ALT = true,
    LMETA = true, RMETA = true, META = true,
}

-- Resolve the action slot currently shown on main-bar button i (page, stance, stealth, etc.)
local function GetActionButtonSlot(index)
    local button = _G["ActionButton"..index]
    if button then
        local action = button.action
        if (type(action) ~= "number" or action < 1) and button.GetAttribute then
            action = button:GetAttribute("action")
        end
        if type(action) == "number" and action > 0 then
            return action
        end
    end
    -- Fallback if the default button frame is missing
    local page = GetActionBarPage() or 1
    local bonus = GetBonusBarOffset() or 0
    local numPages = NUM_ACTIONBAR_PAGES or 6
    if bonus > 0 then
        return (numPages + bonus - 1) * 12 + index
    end
    return (page - 1) * 12 + index
end

-- Collect every key bound to a command, including Alt/Ctrl/Shift combos (e.g. "ALT-1", "CTRL-SHIFT-Q")
local function CollectKeys(command, clickCommand)
    local keys, seen = {}, {}
    local function add(...)
        for i = 1, select("#", ...) do
            local key = select(i, ...)
            if type(key) == "string" and key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(keys, key)
            end
        end
    end
    add(GetBindingKey(command))
    -- Some bar addons bind via CLICK instead of ACTIONBUTTON / MULTIACTIONBAR*
    if clickCommand then
        add(GetBindingKey(clickCommand))
    end
    return keys
end

-- Best-effort name for whatever is on the slot so macros/items are not silently skipped
local function GetSlotName(slot, actionType, id)
    if actionType == "spell" then
        local spellInfo = C_Spell.GetSpellInfo(id)
        if spellInfo and spellInfo.name and spellInfo.name ~= "" then return spellInfo.name end
        if C_Spell.GetSpellName then
            local spellName = C_Spell.GetSpellName(id)
            if spellName and spellName ~= "" then return spellName end
        end
    elseif actionType == "item" then
        local itemName
        if C_Item and C_Item.GetItemNameByID then
            itemName = C_Item.GetItemNameByID(id)
        end
        if not itemName then itemName = GetItemInfo(id) end
        if itemName and itemName ~= "" then return itemName end
    elseif actionType == "macro" then
        local macroName = GetActionText(slot)
        if (not macroName or macroName == "") and type(id) == "number" then
            macroName = GetMacroInfo(id)
        end
        if macroName and macroName ~= "" then return macroName end
        return "Macro"
    elseif actionType == "flyout" and GetFlyoutInfo then
        local flyoutName = GetFlyoutInfo(id)
        if flyoutName and flyoutName ~= "" then return flyoutName end
    elseif actionType == "equipmentset" and type(id) == "string" and id ~= "" then
        return id
    elseif actionType == "companion" or actionType == "summonmount" or actionType == "summonpet" then
        local spellInfo = C_Spell.GetSpellInfo(id)
        if spellInfo and spellInfo.name and spellInfo.name ~= "" then return spellInfo.name end
    end
    local overlay = GetActionText(slot)
    if overlay and overlay ~= "" then return overlay end
    return actionType or "Action"
end

-- Function to scan action bars and find skills that actually have keybinds
local function RefreshBinds()
    -- Clear the table for a fresh scan (useful if you changed specs/binds)
    activeBinds = {}
    
    for _, bar in ipairs(actionBars) do
        for i = 1, 12 do
            local slot
            if bar.slotStart then
                -- Extra bars use a fixed slot range
                slot = bar.slotStart + i - 1
                local button = _G[bar.button..i]
                if button then
                    local action = button.action
                    if type(action) == "number" and action > 0 then
                        slot = action
                    end
                end
            else
                -- Main bar follows the currently visible page / bonus bar
                slot = GetActionButtonSlot(i)
            end
            
            -- Skip empty slots
            if slot and HasAction(slot) then
                local command = bar.binding..i
                local keys = CollectKeys(command, "CLICK "..bar.button..i..":LeftButton")
                
                -- Include every bind WoW stored for this button (plain keys and Alt/Ctrl/Shift combos)
                if #keys > 0 then
                    local actionType, id = GetActionInfo(slot)
                    table.insert(activeBinds, {
                        keys = keys,
                        name = GetSlotName(slot, actionType, id),
                        icon = GetActionTexture(slot)
                    })
                end
            end
        end
    end
end

-- Convert engine key names (e.g. "SHIFT-Q", "BUTTON4") into readable bind text
local function FormatKeys(keys)
    local texts = {}
    for _, key in ipairs(keys) do
        -- GetBindingText localizes and pretty-prints the bind (Shift-Q, Mouse Button 4, etc.)
        local display = GetBindingText(key)
        if not display or display == "" then
            display = key
        end
        table.insert(texts, display)
    end
    -- A slot can have more than one bind; show all of them
    return table.concat(texts, "  /  ")
end

local function FormatDuration(seconds)
    seconds = math.max(0, seconds or 0)
    local m = math.floor(seconds / 60)
    local s = math.floor((seconds % 60) + 0.5)
    if s >= 60 then
        m = m + 1
        s = 0
    end
    if m > 0 then
        return string.format("%dm %ds", m, s)
    end
    return string.format("%ds", s)
end

local function AcquireResultRow(i)
    local row = resultRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, content)
    row:SetSize(490, ROW_HEIGHT)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(true)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetSize(190, ROW_HEIGHT)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.bind = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.bind:SetPoint("LEFT", 234, 0)
    row.bind:SetSize(120, ROW_HEIGHT)
    row.bind:SetJustifyH("LEFT")
    row.bind:SetWordWrap(false)
    row.hits = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.hits:SetPoint("LEFT", 354, 0)
    row.hits:SetSize(60, ROW_HEIGHT)
    row.hits:SetJustifyH("CENTER")
    row.avg = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.avg:SetPoint("LEFT", 434, 0)
    row.avg:SetSize(56, ROW_HEIGHT)
    row.avg:SetJustifyH("LEFT")
    resultRows[i] = row
    return row
end

local function ShowResults()
    local list = {}
    local totalHits = 0
    for _, s in pairs(sessionStats) do
        table.insert(list, s)
        totalHits = totalHits + s.hits
    end
    -- Slowest average first (the binds that need more practice); unanswered prompts at the bottom
    table.sort(list, function(a, b)
        if (a.hits == 0) ~= (b.hits == 0) then
            return a.hits > 0
        end
        local avgA = a.hits > 0 and (a.totalTime / a.hits) or 0
        local avgB = b.hits > 0 and (b.totalTime / b.hits) or 0
        if avgA ~= avgB then return avgA > avgB end
        return a.name < b.name
    end)

    results.summary:SetText(string.format("Duration: %s   |   Presses: %d   |   Abilities: %d",
        FormatDuration(GetTime() - sessionStart), totalHits, #list))

    for i, s in ipairs(list) do
        local row = AcquireResultRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:Show()
        if i % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.05)
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
        end
        row.icon:SetTexture(s.icon)
        row.name:SetText(s.name)
        row.bind:SetText(s.bindText)
        row.hits:SetText(s.hits)
        if s.hits > 0 then
            row.avg:SetText(string.format("%.2fs", s.totalTime / s.hits))
        else
            row.avg:SetText("—")
        end
    end
    for i = #list + 1, #resultRows do
        resultRows[i]:Hide()
    end
    content:SetHeight(math.max(1, #list * ROW_HEIGHT))
    scroll:SetVerticalScroll(0)
    results:Show()
end

local function StopTraining()
    if not f:IsShown() then return end
    f:Hide()
    print("|cFF00FFFF[KeybindTrainer]|r Training stopped.")
    ShowResults()
end

local function RecordHit()
    local s = sessionStats[lastBindIndex]
    if not s then return end
    s.hits = s.hits + 1
    s.totalTime = s.totalTime + (GetTime() - promptStart)
end

-- Function to pick and display the next random skill
local function NextBind()
    -- If no binds were found during the scan, stop and warn the user
    if #activeBinds == 0 then
        f:Hide()
        print("|cFF00FFFF[KeybindTrainer]|r No assigned keybinds found on action bars!")
        return
    end
    
    local rand
    -- If we have more than one bind available
    if #activeBinds > 1 then
        -- Keep rolling a random number until it is different from the last one
        repeat
            rand = math.random(1, #activeBinds)
        until rand ~= lastBindIndex
    else
        -- If there's only one bind, just use it
        rand = 1
    end
    
    -- Save this roll so we don't pick it again next time
    lastBindIndex = rand
    
    -- Retrieve the selected skill's data
    local bind = activeBinds[rand]
    
    -- Start (or reset) this ability's stats and reaction counter
    if not sessionStats[rand] then
        sessionStats[rand] = {
            name = bind.name,
            bindText = FormatKeys(bind.keys),
            icon = bind.icon,
            hits = 0,
            totalTime = 0,
        }
    end
    promptStart = GetTime()
    
    -- Update the UI with the new icon, spell name, and gray keybind hint
    f.icon:SetTexture(bind.icon)
    f.text:SetText(bind.name)
    f.bindText:SetText(FormatKeys(bind.keys))
    
    -- Store the correct key combination(s) for the input checker to verify later
    currentBindKeys = bind.keys
end

-- Function to process user input (from keyboard or mouse)
local function CheckInput(inputKey)
    -- If the user presses Escape, close the trainer and show the results table
    if inputKey == "ESCAPE" then
        StopTraining()
        return
    end
    
    -- Ignore pressing only a modifier; wait for the rest of the combo (e.g. Alt then 1)
    if modifierKeys[inputKey] then
        return
    end
    
    -- If the engine already sent a full combo (e.g. "ALT-1"), use it as-is
    local pressedBind = inputKey
    if not inputKey:find("-", 1, true) then
        -- Build the modifier string exactly as GetBindingKey stores it (ALT-CTRL-SHIFT-META)
        local modifier = ""
        if IsAltKeyDown() then modifier = modifier .. "ALT-" end
        if IsControlKeyDown() then modifier = modifier .. "CTRL-" end
        if IsShiftKeyDown() then modifier = modifier .. "SHIFT-" end
        if IsMetaKeyDown() then modifier = modifier .. "META-" end
        pressedBind = modifier .. inputKey
    end
    
    -- Flag to track if the user pressed the right combination
    local match = false
    
    -- Loop through all valid keys for the current spell (some slots have multiple binds)
    for _, validKey in ipairs(currentBindKeys) do
        -- If the user's input matches a valid bind for this slot
        if pressedBind == validKey then
            match = true
            break
        end
    end
    
    -- If the user pressed the correct key
    if match then
        RecordHit()
        NextBind()
    else
        -- If the user made a mistake, flash the background red
        f.bg:SetColorTexture(0.5, 0, 0, 0.85)
        
        -- Start a timer to revert the background color back to black after 0.05 seconds
        C_Timer.After(0.05, function() f.bg:SetColorTexture(0, 0, 0, 0.85) end)
    end
end

-- Set an event listener for keyboard presses
-- Triggers immediately when a key is pressed DOWN (fastest response time)
f:SetScript("OnKeyDown", function(self, key)
    CheckInput(key)
end)

-- Dictionary to translate internal engine mouse button names to WoW Keybind names
local btnMap = {
    LeftButton = "BUTTON1", RightButton = "BUTTON2", MiddleButton = "BUTTON3",
    Button4 = "BUTTON4", Button5 = "BUTTON5"
}

-- Set an event listener for mouse clicks
f:SetScript("OnMouseDown", function(self, button)
    -- If the clicked button is in our dictionary, pass it to the input checker
    if btnMap[button] then CheckInput(btnMap[button]) end
end)

-- Register slash commands to open/close the trainer
SLASH_KEYBINDTRAINER1 = "/kbt"
SLASH_KEYBINDTRAINER2 = "/keybindtrainer"
SlashCmdList["KEYBINDTRAINER"] = function()
    -- Results window is open: treat /kbt as close
    if results:IsShown() then
        results:Hide()
        return
    end
    -- If the trainer is already open, stop and show results
    if f:IsShown() then
        StopTraining()
    else
        -- Scan the action bars for updated spells/binds
        RefreshBinds()
        
        -- If we found valid binds, start the trainer
        if #activeBinds > 0 then
            -- Reset the duplicate prevention index and session stats for a fresh start
            lastBindIndex = -1
            sessionStats = {}
            sessionStart = GetTime()
            -- Show the UI
            f:Show()
            -- Load the first random skill
            NextBind()
            print("|cFF00FFFF[KeybindTrainer]|r Training started! Press Escape to exit.")
        else
            -- If no binds were found, alert the user
            print("|cFF00FFFF[KeybindTrainer]|r Please place skills on your action bars and assign keybinds first.")
        end
    end
end