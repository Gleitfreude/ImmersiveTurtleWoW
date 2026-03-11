-- Create a frame for initialization and event handling
local FadeUI = CreateFrame("Frame")
FadeUI.name = "FadeUI"
FadeUI.version = "1.1"

-- Configuration
local fadeOutAlpha = 0.0       -- Complete fadeout
local fadeInAlpha = 1           -- Full visibility
local fadeSpeed = 0.5           -- Speed of the fade animation (seconds)
local inCombatFade = true       -- Set to true to enable combat fading
local uiVisible = true          -- Track if FULL UI is toggled visible
local minimapVisible = true     -- Track if minimap is visible
local UIFrames = {}             -- All UI frames (used by ToggleFullUI)
local CombatFrames = {}         -- Subset: shown during combat-only mode
local minimapAutoHideTime = 5.0 -- Time in seconds before minimap auto-hides
local combatFadeDelay = 10.0    -- Time in seconds before UI fades after combat

-- Mode tracking for partial UI states
local combatUIActive = false    -- true when combat-only UI is displayed
local merchantOpen = false      -- true when vendor window is open
local merchantOpenedBags = {}   -- tracks which bags we auto-opened for vendor
local dialogAutoHid = false     -- true when we auto-hid UI on dialog open
local dialogWasFullUI = false   -- whether full UI was visible when dialog opened

-- Just the marker elements that need hiding
local MarkerElements = {
    "Minimap",                  -- The actual minimap with player marker
    "MiniMapPOIFrame"           -- Quest markers
}

-- Other minimap elements that should fade
local MinimapFadeFrames = {
    "MinimapCluster",
    "MinimapBackdrop",
    "MiniMapTracking",
    "MiniMapBattlefieldFrame",
    "MinimapZoomIn",
    "MinimapZoomOut",
    "MinimapNorthTag",
    "MinimapBorder",
    "MinimapBorderTop",
    "MiniMapWorldMapButton",
    "MiniMapMailFrame",
    "GameTimeFrame"
}

-- Track visibility of minimap marker elements
local markerElementsVisible = {}
local targetFrameAlpha = fadeOutAlpha
local buffFrameAlpha = fadeOutAlpha

-- Timers
local minimapTimer = nil
local combatEndTimer = nil
local buffUpdateTimer = nil

-- Recommended keybind info (for documentation only)
local TOGGLE_ALL_UI_KEY = "R"
local TOGGLE_MINIMAP_KEY = "T"

-- Register events
FadeUI:RegisterEvent("PLAYER_LOGIN")
FadeUI:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Combat start
FadeUI:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Combat end
FadeUI:RegisterEvent("PLAYER_TARGET_CHANGED")  -- Target changed
FadeUI:RegisterEvent("UNIT_AURA")              -- Buff changes
FadeUI:RegisterEvent("MERCHANT_SHOW")          -- Vendor window opened
FadeUI:RegisterEvent("MERCHANT_CLOSED")        -- Vendor window closed
FadeUI:RegisterEvent("GOSSIP_SHOW")            -- NPC dialog opened
FadeUI:RegisterEvent("GOSSIP_CLOSED")          -- NPC dialog closed
FadeUI:RegisterEvent("QUEST_GREETING")         -- Quest greeting dialog
FadeUI:RegisterEvent("QUEST_DETAIL")           -- Quest detail view
FadeUI:RegisterEvent("QUEST_PROGRESS")         -- Quest turn-in view
FadeUI:RegisterEvent("QUEST_COMPLETE")         -- Quest reward view
FadeUI:RegisterEvent("QUEST_FINISHED")         -- Quest frame closed
FadeUI:RegisterEvent("PLAYER_ENTERING_WORLD")  -- For bag repositioning
FadeUI:RegisterEvent("UNIT_PET")               -- Pet summoned/dismissed

-- ============================================================
-- Helper: is the current target hostile?
-- ============================================================
local function IsTargetHostile()
    if not UnitExists("target") then return false end
    local reaction = UnitReaction("target", "player")
    -- Reaction 1-3 = hostile (red/orange). Reaction 4 = neutral (yellow, vendors, quest givers).
    -- We only want truly hostile targets to trigger combat UI.
    return reaction ~= nil and reaction <= 3
end

-- ============================================================
-- Helper: toggle minimap marker elements
-- ============================================================
function FadeUI:ToggleMinimapMarkers(show)
    for _, frameName in ipairs(MarkerElements) do
        local frame = getglobal(frameName)
        if frame then
            if show then
                if markerElementsVisible[frameName] ~= false then
                    frame:Show()
                end
            else
                markerElementsVisible[frameName] = frame:IsVisible()
                frame:Hide()
            end
        end
    end
end

-- ============================================================
-- Helper: set alpha on frame and all children recursively
-- ============================================================
function FadeUI:SetFrameAndChildrenAlpha(frame, alpha)
    if not frame then return end
    frame:SetAlpha(alpha)
    local regions = {frame:GetRegions()}
    for i = 1, table.getn(regions) do
        local region = regions[i]
        if region and region.SetAlpha then
            region:SetAlpha(alpha)
        end
    end
    local children = {frame:GetChildren()}
    for i = 1, table.getn(children) do
        local child = children[i]
        if child then
            self:SetFrameAndChildrenAlpha(child, alpha)
        end
    end
end

-- ============================================================
-- Update buff frames to match current alpha state
-- ============================================================
function FadeUI:UpdateBuffFrames()
    if BuffFrame then
        self:SetFrameAndChildrenAlpha(BuffFrame, buffFrameAlpha)
    end
    for i = 1, 32 do
        local buffName = "BuffButton" .. i
        local buff = getglobal(buffName)
        if buff then
            buff:SetAlpha(buffFrameAlpha)
            local patterns = {"Icon", "Border", "Duration", "Count", "Cooldown", "Flash"}
            for _, pattern in ipairs(patterns) do
                local component = getglobal(buffName .. pattern)
                if component then component:SetAlpha(buffFrameAlpha) end
            end
        end
    end
    for i = 1, 16 do
        local debuffName = "DebuffButton" .. i
        local debuff = getglobal(debuffName)
        if debuff then
            debuff:SetAlpha(buffFrameAlpha)
            local patterns = {"Icon", "Border", "Duration", "Count", "Cooldown"}
            for _, pattern in ipairs(patterns) do
                local component = getglobal(debuffName .. pattern)
                if component then component:SetAlpha(buffFrameAlpha) end
            end
        end
    end
    for i = 1, 3 do
        local enchantName = "TempEnchant" .. i
        local enchant = getglobal(enchantName)
        if enchant then
            enchant:SetAlpha(buffFrameAlpha)
            local patterns = {"Icon", "Border", "Duration", "Count"}
            for _, pattern in ipairs(patterns) do
                local component = getglobal(enchantName .. pattern)
                if component then component:SetAlpha(buffFrameAlpha) end
            end
        end
    end
    if ConsolidatedBuffs then
        self:SetFrameAndChildrenAlpha(ConsolidatedBuffs, buffFrameAlpha)
    end
end

-- ============================================================
-- Start a periodic timer to keep buff frames in sync
-- ============================================================
function FadeUI:StartBuffUpdateTimer()
    if buffUpdateTimer then
        buffUpdateTimer:SetScript("OnUpdate", nil)
        buffUpdateTimer = nil
    end
    buffUpdateTimer = CreateFrame("Frame")
    buffUpdateTimer.elapsed = 0
    buffUpdateTimer.interval = 0.5
    buffUpdateTimer:SetScript("OnUpdate", function()
        local elapsed = this.elapsed + arg1
        this.elapsed = elapsed
        if elapsed >= this.interval then
            this.elapsed = 0
            FadeUI:UpdateBuffFrames()
        end
    end)
end

-- ============================================================
-- Find and fade DragonUI action bar background frames.
-- BUG FIX: Removed "Turtle-Dragonflight" from the generic
-- texture search so ContainerFrame item slots (which have
-- Dragonflight bag background textures) are never faded here.
-- Also added explicit ContainerFrame exclusion guard.
-- ============================================================
function FadeUI:FindAndFadeActionBarFrames(targetAlpha)
    -- First pass: children of MainMenuBar with HDActionBar texture
    local children = {MainMenuBar:GetChildren()}
    for i = 1, table.getn(children) do
        local child = children[i]
        if child then
            local regions = {child:GetRegions()}
            for j = 1, table.getn(regions) do
                local region = regions[j]
                if region and region:GetObjectType() == "Texture" then
                    local texture = region:GetTexture()
                    if texture and type(texture) == "string" and string.find(texture, "HDActionBar") then
                        self:FadeFrame(child, targetAlpha)
                        self:FadeFrame(region, targetAlpha)
                    end
                end
            end
        end
    end

    -- Second pass: recursive texture search limited to action bar textures only.
    -- IMPORTANT: ContainerFrame* and KeyRingFrame* are explicitly skipped to
    -- prevent bag contents from being faded when the UI is hidden.
    local function findTextureInContainer(parent, recursive)
        if not parent then return end
        if not parent.GetName then return end

        -- Skip bag window frames so their contents are never touched
        local parentName = parent:GetName()
        if parentName then
            if string.find(parentName, "^ContainerFrame") then return end
            if string.find(parentName, "^KeyRingFrame") then return end
        end

        local regions = {parent:GetRegions()}
        for i = 1, table.getn(regions) do
            local region = regions[i]
            if region and region:GetObjectType() == "Texture" then
                local texture = region:GetTexture()
                -- Only match actual action bar textures (not generic Dragonflight paths)
                if texture and type(texture) == "string" and (
                    string.find(texture, "HDActionBar") or
                    string.find(texture, "MainActionBar")) then
                    self:FadeFrame(region, targetAlpha)
                    self:FadeFrame(parent, targetAlpha)
                end
            end
        end
        if recursive then
            local kids = {parent:GetChildren()}
            for i = 1, table.getn(kids) do
                findTextureInContainer(kids[i], true)
            end
        end
    end

    for _, parent in pairs({MainMenuBar, UIParent, WorldFrame}) do
        findTextureInContainer(parent, true)
    end

    -- Third pass: named DragonUI action bar frames
    local dragonUIActionBarFrames = {
        "ReducedActionBar", "tDFReducedActionBar",
        "DragonUI_ActionBar", "ActionBarLeftFrame", "ActionBarRightFrame"
    }
    for _, frameName in ipairs(dragonUIActionBarFrames) do
        local frame = getglobal(frameName)
        if frame then
            self:FadeFrame(frame, targetAlpha)
            local regions = {frame:GetRegions()}
            for i = 1, table.getn(regions) do
                local region = regions[i]
                if region and region.SetAlpha then
                    self:FadeFrame(region, targetAlpha)
                end
            end
        end
    end
end

-- ============================================================
-- Add DragonUI-specific frames to UIFrames.
-- BUG FIX: searchForTextures now skips ContainerFrame* and
-- KeyRingFrame* so bag item slots (which carry a Dragonflight
-- background texture) are never added to UIFrames and never
-- faded when the main UI is hidden.
-- ============================================================
function FadeUI:AddDragonUISupport()
    local foundElements = {}

    -- 1a. DragonFlight custom castbar (replaces CastingBarFrame entirely).
    -- Excluded from searchForTextures so its children don't get into UIFrames
    -- individually (which would keep them at alpha=0 after ShowCombatUI restores parent).
    local dfCastbar = getglobal("tDFImprovedCastbar")
    if dfCastbar then
        table.insert(UIFrames, dfCastbar)
    end

    -- 1. Bag ICON buttons (not the container windows – those stay untouched).
    -- ContainerFrame1PortraitButton is the big bag graphic inside the backpack window.
    -- It lives inside ContainerFrame1, which is no longer in UIFrames, so we must NOT
    -- fade it separately or the backpack graphic will be invisible when bags open.
    local bagElements = {
        "tDFbagMain", "tDFbag1", "tDFbag2", "tDFbag3", "tDFbag4",
        "tDFbagKeys", "tDFbagArrow", "tDFbagFreeSlots"
    }
    for _, frameName in ipairs(bagElements) do
        local frame = getglobal(frameName)
        if frame then
            table.insert(UIFrames, frame)
            table.insert(foundElements, "Bag: " .. frameName)
            local regions = {frame:GetRegions()}
            for i = 1, table.getn(regions) do
                local region = regions[i]
                if region and region.SetAlpha then
                    table.insert(UIFrames, region)
                end
            end
            if frame.text then table.insert(UIFrames, frame.text) end
        end
    end

    -- 2. DragonUI Minimap Elements
    -- Only add the PARENT frames, never their regions.
    -- FadeAllUI fades the parent alpha which cascades to all children/regions.
    -- Adding regions separately caused borderTexture to stay at alpha=0 after
    -- ShowMinimap (which only restores parent alpha), leaving Minimap black corners visible.
    for _, frameName in ipairs({"MyCustomMinimap", "MyActualMinimap", "BorderFrameForZoneText"}) do
        local frame = getglobal(frameName)
        if frame then
            table.insert(UIFrames, frame)
            table.insert(foundElements, "Minimap: " .. frameName)
        end
    end

    -- NOTE: We do NOT add individual child textures of MyCustomMinimap (the
    -- background texture or borderTexture) to UIFrames. The parent frame's alpha
    -- cascades to all children, so fading MyCustomMinimap is sufficient.
    -- Adding child textures separately causes them to get their own alpha=0 from
    -- FadeFrame; when the parent is later restored instantly via ShowMinimap the
    -- children are still mid-animation at 0 → black corners on the map.

    -- 3. DragonUI XP Bar
    local xpBar = getglobal("tDFxpbar")
    if xpBar then
        table.insert(UIFrames, xpBar)
        table.insert(foundElements, "XP Bar: tDFxpbar")
        for _, sub in ipairs({"status","restedbar","text","leftFrame","rightFrame","leftTexture","rightTexture"}) do
            if xpBar[sub] then table.insert(UIFrames, xpBar[sub]) end
        end
        local regions = {xpBar:GetRegions()}
        for i = 1, table.getn(regions) do
            local region = regions[i]
            if region and region.SetAlpha then table.insert(UIFrames, region) end
        end
    end

    -- 4. Force-hide original Blizzard XP bar
    if MainMenuExpBar then
        MainMenuExpBar:SetAlpha(0)
        MainMenuExpBar:Hide()
    end

    -- 5. Generic Dragonflight texture scan.
    -- CRITICAL: ContainerFrame* and KeyRingFrame* are explicitly skipped.
    -- tBagIcons.lua adds a Dragonflight-path texture to every bag item slot,
    -- which would otherwise cause the bag contents to be added to UIFrames
    -- and faded invisible whenever the UI is hidden.
    -- Unit frames are also skipped: their DragonFlight sub-textures (border
    -- graphics, health/mana bars) must NOT be added to UIFrames individually
    -- or they stay at alpha=0 when ShowCombatUI brings the parent back.
    local function searchForTextures(parent, depth)
        if not parent or depth > 3 then return end

        local parentName = parent:GetName()
        if parentName then
            if string.find(parentName, "^ContainerFrame") then return end
            if string.find(parentName, "^KeyRingFrame") then return end
            if string.find(parentName, "^PlayerFrame") then return end
            if string.find(parentName, "^TargetFrame") then return end
            if string.find(parentName, "^PartyMemberFrame") then return end
            if string.find(parentName, "^PetFrame") then return end
            if string.find(parentName, "^CastingBarFrame") then return end
            if string.find(parentName, "^BonusActionBar") then return end
            if string.find(parentName, "^tDFImprovedCastbar") then return end
            if string.find(parentName, "^tDFbag") then return end
            if string.find(parentName, "^MyCustomMinimap") then return end
            if string.find(parentName, "^MyActualMinimap") then return end
            if string.find(parentName, "^MirrorTimerFrame") then return end
        end

        local regions = {parent:GetRegions()}
        for i = 1, table.getn(regions) do
            local region = regions[i]
            if region and region.GetTexture and region:GetTexture() then
                local texture = region:GetTexture()
                if type(texture) == "string" and (
                    string.find(texture, "Turtle%-Dragonflight") or
                    string.find(texture, "tDF") or
                    string.find(texture, "DragonUI")) then
                    table.insert(UIFrames, region)
                    table.insert(UIFrames, parent)
                end
            end
        end

        local kids = {parent:GetChildren()}
        for i = 1, table.getn(kids) do
            if depth < 2 or table.getn(kids) < 10 then
                searchForTextures(kids[i], depth + 1)
            end
        end
    end

    searchForTextures(UIParent, 0)

    if table.getn(foundElements) > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("FadeUI: Found " .. table.getn(foundElements) .. " DragonUI elements")
    end

    if getglobal("MBB_MinimapButtonFrame") then
        table.insert(UIFrames, getglobal("MBB_MinimapButtonFrame"))
    end
    if GameTimeFrame then
        table.insert(UIFrames, GameTimeFrame)
    end
end

-- ============================================================
-- Minimap show/hide helpers (unchanged from v1.0)
-- ============================================================
function FadeUI:HideMinimap()
    for _, frameName in ipairs(MarkerElements) do
        local frame = getglobal(frameName)
        if frame then markerElementsVisible[frameName] = frame:IsVisible() end
    end
    for _, frameName in ipairs(MarkerElements) do
        local frame = getglobal(frameName)
        if frame then frame:Hide() end
    end
    if Minimap and Minimap.Hide then Minimap:Hide() end
    for _, frameName in ipairs(MinimapFadeFrames) do
        local frame = getglobal(frameName)
        if frame then self:FadeFrame(frame, fadeOutAlpha) end
    end
    if getglobal("MyCustomMinimap") then
        getglobal("MyCustomMinimap"):SetAlpha(fadeOutAlpha)
    end
    if getglobal("MyActualMinimap") then
        getglobal("MyActualMinimap"):SetAlpha(fadeOutAlpha)
    end
    if getglobal("BorderFrameForZoneText") then
        local bzf = getglobal("BorderFrameForZoneText")
        self:FadeFrame(bzf, fadeOutAlpha)
        bzf:Hide()
    end
    if GameTimeFrame then self:FadeFrame(GameTimeFrame, fadeOutAlpha); GameTimeFrame:Hide() end
    local chatButtons = {"ChatFrameMenuButton","ChatFrameUpButton","ChatFrameDownButton","ChatFrameBottomButton"}
    for _, n in ipairs(chatButtons) do
        local b = getglobal(n)
        if b then self:FadeFrame(b, fadeOutAlpha) end
    end
end

function FadeUI:ShowMinimap()
    for _, frameName in ipairs(MarkerElements) do
        local frame = getglobal(frameName)
        if frame and markerElementsVisible[frameName] ~= false then frame:Show() end
    end
    if Minimap and Minimap.Show then Minimap:Show() end
    for _, frameName in ipairs(MinimapFadeFrames) do
        local frame = getglobal(frameName)
        if frame then self:FadeFrame(frame, fadeInAlpha) end
    end
    if getglobal("MyCustomMinimap") then
        getglobal("MyCustomMinimap"):SetAlpha(fadeInAlpha)
    end
    if getglobal("MyActualMinimap") then
        getglobal("MyActualMinimap"):SetAlpha(fadeInAlpha)
    end
    if getglobal("BorderFrameForZoneText") then
        local bzf = getglobal("BorderFrameForZoneText")
        bzf:Show()
        self:FadeFrame(bzf, fadeInAlpha)
    end
    if GameTimeFrame then self:FadeFrame(GameTimeFrame, fadeInAlpha); GameTimeFrame:Show() end
    local chatButtons = {"ChatFrameMenuButton","ChatFrameUpButton","ChatFrameDownButton","ChatFrameBottomButton"}
    for _, n in ipairs(chatButtons) do
        local b = getglobal(n)
        if b then self:FadeFrame(b, uiVisible and fadeInAlpha or fadeOutAlpha) end
    end
end

-- ============================================================
-- Collect ALL UI frames (for ToggleFullUI)
-- ============================================================
function FadeUI:CollectUIFrames()
    -- Action bar
    table.insert(UIFrames, MainMenuBar)
    table.insert(UIFrames, CharacterMicroButton)
    table.insert(UIFrames, SpellbookMicroButton)
    table.insert(UIFrames, TalentMicroButton)
    table.insert(UIFrames, QuestLogMicroButton)
    table.insert(UIFrames, SocialsMicroButton)
    table.insert(UIFrames, WorldMapMicroButton)
    table.insert(UIFrames, MainMenuMicroButton)
    table.insert(UIFrames, HelpMicroButton)
    table.insert(UIFrames, MultiBarBottomLeft)
    table.insert(UIFrames, MultiBarBottomRight)
    table.insert(UIFrames, MultiBarRight)
    table.insert(UIFrames, MultiBarLeft)
    table.insert(UIFrames, MainMenuBarLeftEndCap)
    table.insert(UIFrames, MainMenuBarRightEndCap)

    -- Player / party frames
    table.insert(UIFrames, PlayerFrame)
    table.insert(UIFrames, PartyMemberFrame1)
    table.insert(UIFrames, PartyMemberFrame2)
    table.insert(UIFrames, PartyMemberFrame3)
    table.insert(UIFrames, PartyMemberFrame4)

    -- Misc
    table.insert(UIFrames, CastingBarFrame)

    -- Breath / fatigue bar: keep fully visible and pinned to the top of the screen.
    -- MirrorTimerFrame is excluded from searchForTextures so it never enters UIFrames.
    -- The watcher polls every 0.1s: when visible, cancel any FadeFrame animation,
    -- force alpha=1, and keep it anchored near the top of the screen.
    local mirrorNames = {"MirrorTimerFrame", "MirrorTimerFrame1", "MirrorTimerFrame2", "MirrorTimerFrame3"}
    local function anchorMirrorTimer(f)
        if f:GetParent() ~= UIParent then
            f:SetParent(UIParent)
        end
        if f.fading then
            f.fading:SetScript("OnUpdate", nil)
            f.fading = nil
        end
        f:SetAlpha(1)
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, -60)
    end
    -- Hook OnShow so it snaps to the top the moment it appears
    for _, n in ipairs(mirrorNames) do
        local f = getglobal(n)
        if f then
            f:SetScript("OnShow", function() anchorMirrorTimer(this) end)
        end
    end
    local breathWatcher = CreateFrame("Frame")
    breathWatcher.elapsed = 0
    breathWatcher:SetScript("OnUpdate", function()
        this.elapsed = this.elapsed + arg1
        if this.elapsed < 0.1 then return end
        this.elapsed = 0
        for _, n in ipairs(mirrorNames) do
            local f = getglobal(n)
            if f and f:IsVisible() then
                anchorMirrorTimer(f)
            end
        end
    end)

    -- Chat
    table.insert(UIFrames, ChatFrame1)
    table.insert(UIFrames, ChatFrame2)
    table.insert(UIFrames, ChatFrame3)
    table.insert(UIFrames, ChatFrame4)
    table.insert(UIFrames, ChatFrame5)
    table.insert(UIFrames, ChatFrame6)
    table.insert(UIFrames, ChatFrame7)

    -- Quest tracker
    if QuestWatchFrame then
        table.insert(UIFrames, QuestWatchFrame)
        for i = 1, 15 do
            local line = getglobal("QuestWatchLine"..i)
            if line then table.insert(UIFrames, line) end
        end
    end

    -- Cast bar text
    table.insert(UIFrames, CastingBarText)
    CastingBarText:SetParent(CastingBarFrame)

    -- Rep bar text
    table.insert(UIFrames, ReputationWatchStatusBar.Text)
    table.insert(UIFrames, ReputationWatchStatusBar.OverlayFrame)

    -- Chat tabs
    for i = 1, 7 do
        local tab = getglobal("ChatFrame"..i.."Tab")
        if tab then table.insert(UIFrames, tab) end
    end

    -- Chat buttons
    if ChatFrameMenuButton  then table.insert(UIFrames, ChatFrameMenuButton) end
    if ChatFrameUpButton    then table.insert(UIFrames, ChatFrameUpButton) end
    if ChatFrameDownButton  then table.insert(UIFrames, ChatFrameDownButton) end
    if ChatFrameBottomButton then table.insert(UIFrames, ChatFrameBottomButton) end

    -- Minimap
    self.Minimap = MinimapCluster
    for _, frameName in ipairs(MinimapFadeFrames) do
        local frame = getglobal(frameName)
        if frame then table.insert(UIFrames, frame) end
    end
    for _, frameName in ipairs(MarkerElements) do
        local frame = getglobal(frameName)
        if frame then markerElementsVisible[frameName] = frame:IsVisible() end
    end

    -- DragonUI elements
    self:AddDragonUISupport()

    -- Buff timer
    self:StartBuffUpdateTimer()
    self:UpdateBuffFrames()

    -- Keep original XP bar hidden
    if MainMenuExpBar then
        MainMenuExpBar:SetAlpha(0)
        MainMenuExpBar:Hide()
    end
end

-- ============================================================
-- Collect COMBAT-ONLY frames (subset of UIFrames shown during
-- combat or when a hostile target is selected).
-- Chat, minimap, bags, and micro-menu are intentionally absent.
-- ============================================================
function FadeUI:CollectCombatFrames()
    -- Action bars
    table.insert(CombatFrames, MainMenuBar)
    table.insert(CombatFrames, MultiBarBottomLeft)
    table.insert(CombatFrames, MultiBarBottomRight)
    table.insert(CombatFrames, MultiBarRight)
    table.insert(CombatFrames, MultiBarLeft)
    table.insert(CombatFrames, MainMenuBarLeftEndCap)
    table.insert(CombatFrames, MainMenuBarRightEndCap)

    -- Player and party
    table.insert(CombatFrames, PlayerFrame)
    table.insert(CombatFrames, PartyMemberFrame1)
    table.insert(CombatFrames, PartyMemberFrame2)
    table.insert(CombatFrames, PartyMemberFrame3)
    table.insert(CombatFrames, PartyMemberFrame4)

    -- Cast bar: DragonFlight replaces CastingBarFrame with tDFImprovedCastbar.
    -- Add both so whichever is active gets shown.
    table.insert(CombatFrames, CastingBarFrame)
    if getglobal("tDFImprovedCastbar") then
        table.insert(CombatFrames, getglobal("tDFImprovedCastbar"))
    end

    -- Pet / stance bars (optional, only if they exist)
    if PetFrame         then table.insert(CombatFrames, PetFrame) end
    if PetActionBarFrame then table.insert(CombatFrames, PetActionBarFrame) end
    if ShapeshiftBarFrame then table.insert(CombatFrames, ShapeshiftBarFrame) end
    if BonusActionBarFrame then table.insert(CombatFrames, BonusActionBarFrame) end
end

-- ============================================================
-- Fade a single frame with smooth animation
-- ============================================================
function FadeUI:FadeFrame(frame, targetAlpha)
    if not frame then return end

    -- Keep original XP bar permanently hidden
    if frame == MainMenuExpBar then
        frame:SetAlpha(0)
        frame:Hide()
        return
    end

    -- Cancel any running animation on this frame
    if frame.fading then
        frame.fading:SetScript("OnUpdate", nil)
        frame.fading = nil
    end

    -- Track special frame alphas
    if frame == TargetFrame then
        targetFrameAlpha = targetAlpha
    elseif frame == BuffFrame then
        buffFrameAlpha = targetAlpha
        self:UpdateBuffFrames()
    end

    local currentAlpha = frame:GetAlpha()
    frame.fading = CreateFrame("Frame")
    frame.fading.elapsed = 0
    frame.fading.duration = fadeSpeed
    frame.fading.startAlpha = currentAlpha
    frame.fading.targetAlpha = targetAlpha

    frame.fading:SetScript("OnUpdate", function()
        local elapsed = this.elapsed + arg1
        this.elapsed = elapsed
        if elapsed >= this.duration then
            frame:SetAlpha(this.targetAlpha)
            this:SetScript("OnUpdate", nil)
            frame.fading = nil
            return
        end
        local progress = elapsed / this.duration
        local newAlpha = this.startAlpha + (this.targetAlpha - this.startAlpha) * progress
        frame:SetAlpha(newAlpha)
    end)
end

-- ============================================================
-- Show ONLY combat-relevant frames.
-- Called when entering combat or clicking a hostile target.
-- Chat, minimap, bags, and micro-menu remain hidden.
-- ============================================================
function FadeUI:ShowCombatUI()
    combatUIActive = true

    -- Cancel any pending fade-out timer
    if combatEndTimer then
        combatEndTimer:SetScript("OnUpdate", nil)
        combatEndTimer = nil
    end

    for _, frame in pairs(CombatFrames) do
        if frame then self:FadeFrame(frame, fadeInAlpha) end
    end

    self:FindAndFadeActionBarFrames(fadeInAlpha)

    -- Target frame: show if we have a target, hide otherwise
    if TargetFrame then
        self:FadeFrame(TargetFrame, UnitExists("target") and fadeInAlpha or fadeOutAlpha)
    end

    -- Buffs / debuffs
    buffFrameAlpha = fadeInAlpha
    self:UpdateBuffFrames()

    -- XP bar stays hidden
    if MainMenuExpBar then
        MainMenuExpBar:SetAlpha(0)
        MainMenuExpBar:Hide()
    end

    -- Bag icons must stay hidden during combat
    local bagNames = {"tDFbagMain","tDFbag1","tDFbag2","tDFbag3","tDFbag4","tDFbagKeys","tDFbagArrow","tDFbagFreeSlots"}
    for _, n in ipairs(bagNames) do
        local f = getglobal(n)
        if f then self:FadeFrame(f, fadeOutAlpha) end
    end
end

-- ============================================================
-- Hide combat frames, returning to fully-faded state.
-- Called after the post-combat delay timer fires.
-- ============================================================
function FadeUI:HideCombatUI()
    combatUIActive = false

    for _, frame in pairs(CombatFrames) do
        if frame then self:FadeFrame(frame, fadeOutAlpha) end
    end

    self:FindAndFadeActionBarFrames(fadeOutAlpha)

    if TargetFrame then self:FadeFrame(TargetFrame, fadeOutAlpha) end

    buffFrameAlpha = fadeOutAlpha
    self:UpdateBuffFrames()
end

-- ============================================================
-- Fade ALL UI elements (used by ToggleFullUI keybind)
-- ============================================================
function FadeUI:FadeAllUI(targetAlpha)
    -- Always reset partial-UI tracking when a full fade runs
    combatUIActive = false

    for _, frame in pairs(UIFrames) do
        if frame then self:FadeFrame(frame, targetAlpha) end
    end

    self:FindAndFadeActionBarFrames(targetAlpha)

    if targetAlpha == fadeInAlpha then
        self:ShowMinimap()
    else
        self:HideMinimap()
    end

    -- Keep original XP bar hidden
    if MainMenuExpBar then
        MainMenuExpBar:SetAlpha(0)
        MainMenuExpBar:Hide()
    end

    -- Target frame
    if not UnitExists("target") or targetAlpha == fadeInAlpha then
        if TargetFrame then self:FadeFrame(TargetFrame, targetAlpha) end
    end

    buffFrameAlpha = targetAlpha
    self:UpdateBuffFrames()

    uiVisible = (targetAlpha == fadeInAlpha)
    minimapVisible = (targetAlpha == fadeInAlpha)

    if targetAlpha == fadeInAlpha then
        if minimapTimer then
            minimapTimer:SetScript("OnUpdate", nil)
            minimapTimer = nil
        end
        if combatEndTimer then
            combatEndTimer:SetScript("OnUpdate", nil)
            combatEndTimer = nil
        end
    end

    self:UpdateTargetFrame()
end

-- ============================================================
-- Fade just the minimap (minimap toggle keybind)
-- ============================================================
function FadeUI:FadeMinimap(targetAlpha)
    minimapVisible = (targetAlpha == fadeInAlpha)

    if targetAlpha == fadeInAlpha then
        -- Reveal content BEFORE animating so it's present as frames fade in.
        -- (MyCustomMinimap alpha is already 0 from the last HideMinimap/FadeMinimap call,
        --  so FadeFrame below will animate cleanly from 0 → 1.)
        if Minimap and Minimap.Show then Minimap:Show() end
        for _, frameName in ipairs(MarkerElements) do
            local f = getglobal(frameName)
            if f then f:Show() end
        end
        if GameTimeFrame then GameTimeFrame:Show() end
        if getglobal("BorderFrameForZoneText") then getglobal("BorderFrameForZoneText"):Show() end
        for _, frameName in ipairs(MinimapFadeFrames) do
            local f = getglobal(frameName)
            if f then self:FadeFrame(f, fadeInAlpha) end
        end
    end

    -- Animate DragonFlight minimap parent frames (alpha cascades to child textures).
    -- Do NOT set alpha directly here — that was killing the animation.
    local dragonMinimapFrames = {"MyCustomMinimap", "MyActualMinimap", "BorderFrameForZoneText"}
    for _, frameName in ipairs(dragonMinimapFrames) do
        local frame = getglobal(frameName)
        if frame then self:FadeFrame(frame, targetAlpha) end
    end

    if GameTimeFrame then self:FadeFrame(GameTimeFrame, targetAlpha) end

    local chatButtons = {"ChatFrameMenuButton","ChatFrameUpButton","ChatFrameDownButton","ChatFrameBottomButton"}
    for _, n in ipairs(chatButtons) do
        local b = getglobal(n)
        if b then self:FadeFrame(b, uiVisible and targetAlpha or fadeOutAlpha) end
    end

    if targetAlpha == fadeOutAlpha then
        -- Hide content AFTER the fade-out animation finishes.
        for _, frameName in ipairs(MinimapFadeFrames) do
            local f = getglobal(frameName)
            if f then self:FadeFrame(f, fadeOutAlpha) end
        end
        local doneTimer = CreateFrame("Frame")
        doneTimer.elapsed = 0
        doneTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed >= fadeSpeed + 0.05 then
                if Minimap and Minimap.Hide then Minimap:Hide() end
                for _, frameName in ipairs(MarkerElements) do
                    local f = getglobal(frameName)
                    if f then f:Hide() end
                end
                if GameTimeFrame then GameTimeFrame:Hide() end
                this:SetScript("OnUpdate", nil)
            end
        end)
    end

    if targetAlpha == fadeInAlpha then
        if minimapTimer then
            minimapTimer:SetScript("OnUpdate", nil)
            minimapTimer = nil
        end
        minimapTimer = CreateFrame("Frame")
        minimapTimer.elapsed = 0
        minimapTimer:SetScript("OnUpdate", function()
            local elapsed = this.elapsed + arg1
            this.elapsed = elapsed
            if elapsed >= minimapAutoHideTime then
                FadeUI:FadeMinimap(fadeOutAlpha)
                this:SetScript("OnUpdate", nil)
                minimapTimer = nil
            end
        end)
    end
end

-- ============================================================
-- Update target frame visibility.
-- Now also triggers ShowCombatUI when a hostile target is
-- clicked and the main UI is in faded mode.
-- ============================================================
function FadeUI:UpdateTargetFrame()
    local hasTarget = UnitExists("target")

    if uiVisible then
        -- Full UI is visible: just show/hide target frame normally
        if TargetFrame then
            self:FadeFrame(TargetFrame, hasTarget and fadeInAlpha or fadeOutAlpha)
        end
        return
    end

    -- UI is faded: check target hostility
    if hasTarget and IsTargetHostile() then
        -- Hostile target → show combat UI (action bars, player frame, etc.)
        if not combatUIActive then
            self:ShowCombatUI()
        else
            -- Already in combat mode, just ensure target frame is visible
            if TargetFrame then self:FadeFrame(TargetFrame, fadeInAlpha) end
        end
    elseif hasTarget then
        -- Friendly / neutral target
        if TargetFrame then
            self:FadeFrame(TargetFrame, combatUIActive and fadeInAlpha or fadeOutAlpha)
        end
    else
        -- No target
        if TargetFrame then self:FadeFrame(TargetFrame, fadeOutAlpha) end
        -- If combat UI was shown and player is no longer in combat, start fade
        if combatUIActive and not UnitAffectingCombat("player") then
            self:StartCombatEndTimer()
        end
    end
end

-- ============================================================
-- Toggle full UI (keybind)
-- ============================================================
function FadeUI:ToggleUI()
    if uiVisible then
        self:FadeAllUI(fadeOutAlpha)
    else
        self:FadeAllUI(fadeInAlpha)
    end
end

-- ============================================================
-- Toggle minimap only (keybind)
-- ============================================================
function FadeUI:ToggleMinimap()
    if minimapVisible then
        self:FadeMinimap(fadeOutAlpha)
    else
        self:FadeMinimap(fadeInAlpha)
    end
end

-- ============================================================
-- Post-combat fade timer.
-- After the delay fires HideCombatUI() (faded mode) or
-- FadeAllUI(fadeOutAlpha) (full-UI mode), depending on state.
-- ============================================================
function FadeUI:StartCombatEndTimer()
    if combatEndTimer then
        combatEndTimer:SetScript("OnUpdate", nil)
        combatEndTimer = nil
    end
    combatEndTimer = CreateFrame("Frame")
    combatEndTimer.elapsed = 0
    combatEndTimer:SetScript("OnUpdate", function()
        local elapsed = this.elapsed + arg1
        this.elapsed = elapsed
        if elapsed >= combatFadeDelay then
            if uiVisible then
                -- Full UI was shown during combat – auto-hide it
                FadeUI:FadeAllUI(fadeOutAlpha)
            elseif combatUIActive then
                -- Combat-only UI was shown – hide just those frames
                FadeUI:HideCombatUI()
            end
            this:SetScript("OnUpdate", nil)
            combatEndTimer = nil
        end
    end)
end

-- ============================================================
-- Open bags for vendor interaction and track which we opened
-- ============================================================
function FadeUI:OpenBagsForMerchant()
    merchantOpenedBags = {}
    for i = 0, 4 do
        -- Only open bags that actually have slots
        if GetContainerNumSlots(i) > 0 then
            local cf = getglobal("ContainerFrame" .. (i + 1))
            if cf and not cf:IsVisible() then
                ToggleBag(i)
                merchantOpenedBags[i] = true
            end
        end
    end
end

-- ============================================================
-- Close only the bags we opened for the merchant
-- ============================================================
function FadeUI:CloseMerchantBags()
    for bagIndex, wasOpenedByUs in pairs(merchantOpenedBags) do
        if wasOpenedByUs then
            local cf = getglobal("ContainerFrame" .. (bagIndex + 1))
            if cf and cf:IsVisible() then
                ToggleBag(bagIndex)
            end
        end
    end
    merchantOpenedBags = {}
end

-- ============================================================
-- Reposition GameTooltip to bottom-right when hovering bag items
-- ============================================================
local function SetupBagTooltipAnchor()
    local origOnShow = GameTooltip:GetScript("OnShow")
    GameTooltip:SetScript("OnShow", function()
        if origOnShow then origOnShow() end
        local owner = this.GetOwner and this:GetOwner()  -- GetOwner absent in WoW 1.12 vanilla
        if owner then
            local ownerName = owner:GetName() or ""
            if string.find(ownerName, "^ContainerFrame%d+Item%d+") then
                this:ClearAllPoints()
                this:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -50, 55)
            end
        end
    end)
end

-- ============================================================
-- Event handler
-- ============================================================
FadeUI:SetScript("OnEvent", function()

    if event == "PLAYER_LOGIN" then
        this:CollectUIFrames()
        this:CollectCombatFrames()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99"..this.name.."|r v"..this.version.." loaded.")
        DEFAULT_CHAT_FRAME:AddMessage("Combat UI auto-shows on enemy target or combat entry.")
        DEFAULT_CHAT_FRAME:AddMessage("Press B/Shift-B to open bags (only bags appear).")
        DEFAULT_CHAT_FRAME:AddMessage("Bags auto-open at vendor. ToggleFullUI key: show/hide everything.")
        if MainMenuExpBar then
            MainMenuExpBar:SetAlpha(0)
            MainMenuExpBar:Hide()
        end
        SetupBagTooltipAnchor()

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Reposition DragonUI bag buttons to the bottom-right corner.
        -- Dragonflight places tDFbagMain at y=40 from the bottom edge, which
        -- looks too high. We move it down to y=5 after a short delay so our
        -- SetPoint runs after Dragonflight's own positioning.
        local reposTimer = CreateFrame("Frame")
        reposTimer.elapsed = 0
        reposTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 0.5 then
                if tDFbagMain then
                    tDFbagMain:ClearAllPoints()
                    tDFbagMain:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -5, 5)
                end

                -- Move player DEBUFF icons (curses, poisons, etc.) to just below the minimap.
                -- Regular buffs stay in their default position.
                -- Hook BuffFrame_Update so the position sticks after every aura change.
                local origBuffFrame_Update = BuffFrame_Update
                BuffFrame_Update = function()
                    if origBuffFrame_Update then origBuffFrame_Update() end
                    if DebuffButton1 and MinimapCluster then
                        DebuffButton1:ClearAllPoints()
                        DebuffButton1:SetPoint("TOPRIGHT", MinimapCluster, "BOTTOMRIGHT", 0, -5)
                    end
                end
                if DebuffButton1 and MinimapCluster then
                    DebuffButton1:ClearAllPoints()
                    DebuffButton1:SetPoint("TOPRIGHT", MinimapCluster, "BOTTOMRIGHT", 0, -5)
                end

                -- Position pet frame to the right of the player frame.
                if PetFrame and PlayerFrame then
                    PetFrame:ClearAllPoints()
                    PetFrame:SetPoint("TOPLEFT", PlayerFrame, "TOPRIGHT", 5, -20)
                end

                this:SetScript("OnUpdate", nil)
            end
        end)

    elseif event == "UNIT_PET" and arg1 == "player" then
        -- Pet was summoned or dismissed. The game repositions PetFrame to its
        -- default location (below PlayerFrame) and also pushes MainMenuBar upward
        -- to make room for PetActionBarFrame. Use a short delay so the game
        -- finishes its own repositioning before we override it.
        local petTimer = CreateFrame("Frame")
        petTimer.elapsed = 0
        petTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 0.1 then
                -- Keep pet frame to the right of player frame
                if PetFrame and PlayerFrame then
                    PetFrame:ClearAllPoints()
                    PetFrame:SetPoint("TOPLEFT", PlayerFrame, "TOPRIGHT", 5, -20)
                end
                -- The game pushes MainMenuBar up when pet bar appears.
                -- DragonFlight keeps it at y=13 (no XP bar), so restore that.
                if MainMenuBar then
                    MainMenuBar:ClearAllPoints()
                    MainMenuBar:SetPoint("BOTTOM", WorldFrame, "BOTTOM", 0, 15)
                end
                this:SetScript("OnUpdate", nil)
            end
        end)

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat
        if inCombatFade then
            -- Cancel any pending post-combat fade
            if combatEndTimer then
                combatEndTimer:SetScript("OnUpdate", nil)
                combatEndTimer = nil
            end
            if uiVisible then
                -- Full UI is on: keep it on, do nothing extra
            else
                -- UI is faded: show combat-only elements
                this:ShowCombatUI()
            end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat: start the delayed fade-out only when in faded mode.
        -- If the full UI is visible (uiVisible=true), don't start the timer –
        -- otherwise HideCombatUI/FadeAllUI would run and make action bars
        -- unclickable even though the player has explicitly shown the full UI.
        if inCombatFade and not uiVisible then
            this:StartCombatEndTimer()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        this:UpdateTargetFrame()

    elseif event == "UNIT_AURA" and arg1 == "player" then
        this:UpdateBuffFrames()

    elseif event == "GOSSIP_SHOW" or event == "QUEST_GREETING"
        or event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        -- NPC dialog opened: fade out if full UI or combat UI is currently showing.
        if uiVisible or combatUIActive then
            dialogAutoHid = true
            dialogWasFullUI = uiVisible
            -- Cancel any pending combat-end timer so it doesn't interfere mid-dialog.
            if combatEndTimer then
                combatEndTimer:SetScript("OnUpdate", nil)
                combatEndTimer = nil
            end
            this:FadeAllUI(fadeOutAlpha)
        end

    elseif event == "GOSSIP_CLOSED" or event == "QUEST_FINISHED" then
        -- NPC dialog closed: restore to the state we were in before.
        if dialogAutoHid then
            dialogAutoHid = false
            if dialogWasFullUI then
                -- Full UI was on before dialog — bring it back.
                this:FadeAllUI(fadeInAlpha)
            end
            -- If it was combat-only mode, leave faded; combat events will re-show
            -- action bars if still in combat or targeting a hostile.
            dialogWasFullUI = false
        end

    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true
        -- Fade out UI for immersion, same as NPC dialog
        if uiVisible or combatUIActive then
            dialogAutoHid = true
            dialogWasFullUI = uiVisible
            if combatEndTimer then
                combatEndTimer:SetScript("OnUpdate", nil)
                combatEndTimer = nil
            end
            this:FadeAllUI(fadeOutAlpha)
        end
        -- Auto-open bags so the player can trade
        this:OpenBagsForMerchant()

    elseif event == "MERCHANT_CLOSED" then
        -- Close bags we opened, then restore UI state
        if merchantOpen then
            this:CloseMerchantBags()
        end
        merchantOpen = false
        if dialogAutoHid then
            dialogAutoHid = false
            if dialogWasFullUI then
                this:FadeAllUI(fadeInAlpha)
            end
            dialogWasFullUI = false
        end

    end
end)

-- ============================================================
-- Reposition open ContainerFrames to stack above the bag icons
-- in the bottom-right corner.  Called whenever any bag opens
-- or closes so the stack is always tidy.
-- ============================================================
local function RepositionContainerFrames()
    local xOffset = -45   -- shifted left by the width of the bag icon bar (40 px) + 5 px margin
    local yOffset = 50    -- start just above the bag icon bar (icons span y=5..45)
    local spacing = 5     -- gap between consecutive bag windows

    -- ContainerFrame1 = backpack (closest to icons), 2-5 above it
    for i = 1, 5 do
        local cf = getglobal("ContainerFrame" .. i)
        if cf and cf:IsVisible() then
            cf:ClearAllPoints()
            cf:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", xOffset, yOffset)
            yOffset = yOffset + cf:GetHeight() + spacing
        end
    end
end

-- Lightweight watcher: checks every 0.15 s whether any ContainerFrame
-- changed visibility, and repositions the stack when it does.
local bagWindowWatcher = CreateFrame("Frame")
bagWindowWatcher.elapsed  = 0
bagWindowWatcher.interval = 0.15
bagWindowWatcher.lastState = ""
bagWindowWatcher:SetScript("OnUpdate", function()
    local elapsed = this.elapsed + arg1
    this.elapsed = elapsed
    if elapsed < this.interval then return end
    this.elapsed = 0

    local state = ""
    for i = 1, 5 do
        local cf = getglobal("ContainerFrame" .. i)
        state = state .. (cf and cf:IsVisible() and "1" or "0")
    end
    if state ~= this.lastState then
        this.lastState = state
        RepositionContainerFrames()
    end
end)

-- ============================================================
-- Reposition GameTooltip to sit just above the bag icons when
-- hovering over items inside the open bag windows.
-- ============================================================
local function SetupBagTooltipAnchor()
    local origOnShow = GameTooltip:GetScript("OnShow")
    GameTooltip:SetScript("OnShow", function()
        if origOnShow then origOnShow() end
        local owner = this.GetOwner and this:GetOwner()  -- GetOwner absent in WoW 1.12 vanilla
        if owner then
            local ownerName = owner:GetName() or ""
            -- ContainerFrameNItemM  →  item slot inside a bag window
            if string.find(ownerName, "^ContainerFrame%d+Item%d+") then
                this:ClearAllPoints()
                this:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -50, 55)
            end
        end
    end)
end

-- ============================================================
-- Keybinding display strings (shown in the WoW keybinding menu)
-- ============================================================
BINDING_HEADER_IMMERSIVE_UI   = "Immersive UI"
BINDING_NAME_TOGGLE_FULL_UI   = "Toggle UI Fade"
BINDING_NAME_TOGGLE_MINIMAP_ONLY = "Toggle Minimap"

-- Global wrappers called by bindings.xml
function ImmersiveUI_ToggleFullUI()
    FadeUI:ToggleUI()
end

function ImmersiveUI_ToggleMinimap()
    FadeUI:ToggleMinimap()
end

-- ============================================================
-- Slash commands
-- ============================================================
SLASH_FADEUI1 = "/fadeui"
SlashCmdList["FADEUI"] = function(msg)
    if msg == "toggle" or msg == "" then
        FadeUI:ToggleUI()
    elseif msg == "minimap" then
        FadeUI:ToggleMinimap()
    else
        DEFAULT_CHAT_FRAME:AddMessage("FadeUI commands:")
        DEFAULT_CHAT_FRAME:AddMessage("/fadeui or /fadeui toggle - Toggle all UI elements")
        DEFAULT_CHAT_FRAME:AddMessage("/fadeui minimap - Toggle minimap (auto-hides after "..minimapAutoHideTime.."s)")
    end
end
