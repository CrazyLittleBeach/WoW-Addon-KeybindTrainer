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

-- Map all standard and multi-action bar slots (1 to 120+) to their internal WoW binding names
local slotToBinding = {}
for i = 1, 12 do slotToBinding[i] = "ACTIONBUTTON"..i end
for i = 1, 12 do slotToBinding[60+i] = "MULTIACTIONBAR1BUTTON"..i end
for i = 1, 12 do slotToBinding[72+i] = "MULTIACTIONBAR2BUTTON"..i end
for i = 1, 12 do slotToBinding[84+i] = "MULTIACTIONBAR3BUTTON"..i end
for i = 1, 12 do slotToBinding[96+i] = "MULTIACTIONBAR4BUTTON"..i end
for i = 1, 12 do slotToBinding[132+i] = "MULTIACTIONBAR5BUTTON"..i end
for i = 1, 12 do slotToBinding[144+i] = "MULTIACTIONBAR6BUTTON"..i end
for i = 1, 12 do slotToBinding[156+i] = "MULTIACTIONBAR7BUTTON"..i end

-- Function to scan action bars and find skills that actually have keybinds
local function RefreshBinds()
    -- Clear the table for a fresh scan (useful if you changed specs/binds)
    activeBinds = {}
    
    -- Loop through every action bar slot mapped above
    for slot, command in pairs(slotToBinding) do
        -- Get information about what is placed in this slot
        local actionType, id = GetActionInfo(slot)
        
        -- If there is something in the slot (a spell, item, or macro)
        if actionType and id then
            -- Check if this specific slot has a keyboard bind assigned to it
            local keys = {GetBindingKey(command)}
            
            -- If it has at least one bind
            if #keys > 0 then
                local name = ""
                
                -- Determine the name based on the action type
                if actionType == "spell" then
                    -- Use the modern C_Spell API to get spell info (required for 11.0+)
                    local spellInfo = C_Spell.GetSpellInfo(id)
                    if spellInfo then name = spellInfo.name end
                elseif actionType == "item" then
                    -- Get item name
                    local itemName = GetItemInfo(id)
                    if itemName then name = itemName end
                elseif actionType == "macro" then
                    -- Get macro name
                    name = GetActionText(slot)
                end
                
                -- If we successfully found a name, save the data to our activeBinds table
                if name and name ~= "" then
                    table.insert(activeBinds, {
                        keys = keys,                      -- The key combination(s)
                        name = name,                      -- The name of the ability
                        icon = GetActionTexture(slot)     -- The icon texture path
                    })
                end
            end
        end
    end
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
    
    -- Update the UI with the new icon and text
    f.icon:SetTexture(bind.icon)
    f.text:SetText(bind.name)
    
    -- Store the correct key combination(s) for the input checker to verify later
    currentBindKeys = bind.keys
end

-- Function to process user input (from keyboard or mouse)
local function CheckInput(inputKey)
    -- If the user presses Escape, close the trainer
    if inputKey == "ESCAPE" then
        f:Hide()
        print("|cFF00FFFF[KeybindTrainer]|r Training stopped.")
        return
    end
    
    -- Ignore pure modifier key presses (e.g., pressing just 'Shift' without another key)
    if inputKey:match("SHIFT") or inputKey:match("CTRL") or inputKey:match("ALT") or inputKey:match("META") then
        return
    end
    
    -- Build the modifier string exactly as WoW expects it (order matters: ALT-CTRL-SHIFT-META)
    local modifier = ""
    if IsAltKeyDown() then modifier = modifier .. "ALT-" end
    if IsControlKeyDown() then modifier = modifier .. "CTRL-" end
    if IsShiftKeyDown() then modifier = modifier .. "SHIFT-" end
    if IsMetaKeyDown() then modifier = modifier .. "META-" end
    
    -- Combine the modifiers with the pressed key (e.g., "SHIFT-R" or "ALT-CTRL-F")
    local pressedBind = modifier .. inputKey
    
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
        -- Instantly move to the next skill
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
    -- If the trainer is already open, close it
    if f:IsShown() then
        f:Hide()
        print("|cFF00FFFF[KeybindTrainer]|r Training stopped.")
    else
        -- Scan the action bars for updated spells/binds
        RefreshBinds()
        
        -- If we found valid binds, start the trainer
        if #activeBinds > 0 then
            -- Reset the duplicate prevention index for a fresh start
            lastBindIndex = -1 
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