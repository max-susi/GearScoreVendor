-- Version 2.0.1 - Fixed GetItemBindType API error
local addonName, ns = ...

------------------------------------------------------------------------
-- SavedVariables‑Handling                                              --
------------------------------------------------------------------------
local defaults = {
    min     = 0,
    max     = 0,
    minimap = { hide = false }, -- Standardmäßig anzeigen, LibDBIcon übernimmt die Position
    presets = {}, -- vordefinierte Level-Presets
    skipWarbandTokens = true, -- Standard: Warband Tokens überspringen
    debugMode = false, -- Debug-Meldungen aktivieren/deaktivieren
}

local db -- erhält nach ADDON_LOADED den Verweis auf SavedVariables

-- Item-Info Cache für Performance
local itemInfoCache = {}
local CACHE_DURATION = 30 -- Cache für 30 Sekunden

------------------------------------------------------------------------
-- Hilfsfunktionen                                                      --
------------------------------------------------------------------------
local function Clamp(val, lower, upper)
    if val < lower then return lower end
    if val > upper then return upper end
    return val
end

-- Debug-Hilfsfunktion
local function DebugPrint(...)
    if db and db.debugMode then
        print(addonName .. ": DEBUG -", ...)
    end
end

-- Schnelle, zuverlässige Item-Level-Abfrage mit strikter Validierung
local function GetItemLevel(bag, slot, hyperlink)
    local loc = ItemLocation and ItemLocation:CreateFromBagAndSlot(bag, slot)
    if loc and loc:IsValid() then
        -- Verschiedene API-Varianten je nach Patchstand testen
        if C_Item.GetCurrentItemLevel then
            local lvl = C_Item.GetCurrentItemLevel(loc)
            if lvl and tonumber(lvl) and lvl > 0 then return lvl end
        end
        if C_Item.GetItemLevel then
            local lvl = C_Item.GetItemLevel(loc)
            if lvl and tonumber(lvl) and lvl > 0 then return lvl end
        end
    end

    -- Fallback über Hyperlink
    if hyperlink then
        if C_Item.GetDetailedItemLevelInfo then
            local lvl = C_Item.GetDetailedItemLevelInfo(hyperlink)
            if lvl and tonumber(lvl) and lvl > 0 then return lvl end
        end
        local lvl = select(4, GetItemInfo(hyperlink))
        if lvl and tonumber(lvl) and lvl > 0 then return lvl end
    end
    
    -- KEIN gültiges ItemLevel gefunden - explizit nil zurückgeben
    return nil
end

-- Tooltip Scanner einmal erstellen und wiederverwenden
local tooltipScanner
local function GetTooltipScanner()
    if not tooltipScanner then
        tooltipScanner = CreateFrame("GameTooltip", "GSVTooltipScanner", nil, "GameTooltipTemplate")
        tooltipScanner:SetOwner(UIParent, "ANCHOR_NONE")
    end
    return tooltipScanner
end

-- Cache-Management
local function GetCachedItemInfo(itemID)
    if not itemID then return nil end
    local cached = itemInfoCache[itemID]
    if cached and (GetTime() - cached.timestamp) < CACHE_DURATION then
        return cached.data
    end
    return nil
end

local function SetCachedItemInfo(itemID, data)
    if not itemID then return end
    itemInfoCache[itemID] = {
        data = data,
        timestamp = GetTime()
    }
end

-- Prüft ob ein Item ein Warband-bound Tier Token ist
local function IsWarbandToken(hyperlink, itemID)
    if not hyperlink and not itemID then return false end
    
    -- Prüfe Cache zuerst
    if itemID then
        local cached = GetCachedItemInfo(itemID)
        if cached and cached.isWarbandToken ~= nil then
            return cached.isWarbandToken
        end
    end
    
    local result = false
    
    -- Tooltip wiederverwenden und scannen für Warband-Binding
    if hyperlink then
        local tooltip = GetTooltipScanner()
        tooltip:ClearLines()
        tooltip:SetHyperlink(hyperlink)
        
        -- Tooltip-Text durchsuchen nach Warband-Binding
        for i = 1, tooltip:NumLines() do
            local line = _G["GSVTooltipScannerTextLeft" .. i]
            if line then
                local text = line:GetText()
                if text then
                    -- Deutsche und englische Warband-Texte
                    if string.find(text, "Binds to Warband") or 
                       string.find(text, "warband%-bound") or
                       string.find(text, "Warband%-gebunden") or
                       string.find(text, "An Kriegstrupp gebunden") then
                        tooltip:Hide()
                        result = true
                        break
                    end
                end
            end
        end
        tooltip:Hide()
    end
    
    -- Cache das Ergebnis
    if itemID then
        local cached = GetCachedItemInfo(itemID) or {}
        cached.isWarbandToken = result
        SetCachedItemInfo(itemID, cached)
    end
    
    return result
end

-- Prüft ob ein Item übersprungen werden soll (für Verkauf)
local function ShouldSkipItem(hyperlink, itemID)
    -- Nur Warband-bound Tokens überspringen wenn die Einstellung aktiviert ist
    if db.skipWarbandTokens then
        return IsWarbandToken(hyperlink, itemID)
    end
    return false
end

-- Findet alle Tier Tokens im Inventar die in der konfigurierten Level-Range liegen
local function FindTierTokens()
    local tokens = {}
    
    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and not info.isLocked then
                -- Prüfe zuerst den Item-Level
                local itemLevel = GetItemLevel(bag, slot, info.hyperlink)
                if itemLevel and itemLevel >= db.min and itemLevel <= db.max then
                    -- Dann prüfe ob es ein Warband-bound Token ist
                    if IsWarbandToken(info.hyperlink, info.itemID) then
                        local itemName, itemLink = GetItemInfo(info.hyperlink)
                        if itemName then
                            DebugPrint(string.format("Warband Token gefunden: %s (iLvl %d)", itemName, itemLevel))
                            table.insert(tokens, {
                                name = itemName,
                                link = itemLink,
                                bag = bag,
                                slot = slot,
                                hyperlink = info.hyperlink,
                                texture = info.iconFileID or select(10, GetItemInfo(info.hyperlink)),
                                itemLevel = itemLevel
                            })
                        end
                    end
                end
            end
        end
    end
    
    return tokens
end

-- Verwendet ein Token sicher (ohne Verkauf im Merchant-Fenster)
local function UseToken(bag, slot)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return end
    
    -- Merchant-Fenster temporär verstecken um Verkauf zu verhindern
    local merchantWasOpen = MerchantFrame and MerchantFrame:IsShown()
    if merchantWasOpen then
        MerchantFrame:Hide()
    end
    
    -- Token verwenden mit kurzer Verzögerung
    C_Timer.After(0.1, function()
        C_Container.UseContainerItem(bag, slot)
        
        -- Merchant-Fenster wieder anzeigen mit längerer Verzögerung
        -- um sicherzustellen dass das Token-UI geschlossen ist
        if merchantWasOpen then
            C_Timer.After(1.5, function()
                -- Prüfe ob kein anderes wichtiges UI offen ist
                if MerchantFrame and (not StaticPopup1 or not StaticPopup1:IsShown()) and 
                   (not ItemRefTooltip or not ItemRefTooltip:IsShown()) then
                    MerchantFrame:Show()
                end
            end)
        end
    end)
end

-- Verkaufsvariablen
local sellQueue = {}
local queueTotal = 0

-- Sequenzielles Verkaufen über eine Warteschlange, um Server-Limits zu respektieren
local function ProcessQueue()
    if #sellQueue == 0 or not MerchantFrame or not MerchantFrame:IsShown() then
        return
    end

    local entry = tremove(sellQueue, 1)
    if entry then
        -- Sicherheitsprüfung: Item nochmal auf Verkaufbarkeit prüfen
        local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
        if info and info.hyperlink and not info.isLocked then
            DebugPrint(string.format("Verkaufe: %s (Bag: %d, Slot: %d)", 
                entry.itemName or "Unknown", entry.bag, entry.slot))
            
            -- Umfassende Preis-Prüfung mit mehreren Methoden
            local currentPrice = info.vendorPrice
            if not currentPrice or currentPrice <= 0 then
                currentPrice = select(11, GetItemInfo(info.itemID or info.hyperlink)) or 0
            end
            if not currentPrice or currentPrice <= 0 then
                local _, _, _, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(info.hyperlink)
                currentPrice = vendorPrice or 0
            end
            
            -- Zusätzliche Prüfungen die Verkauf verhindern können
            local itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType, 
                  itemStackCount, itemEquipLoc, iconFileID, vendorPrice, itemClassID, itemSubClassID = GetItemInfo(info.hyperlink)
            
            -- Prüfe auf verschiedene unverkäufliche Eigenschaften
            local canSell = true
            local skipReason = ""
            
                         if not currentPrice or currentPrice <= 0 then
                canSell = false
                skipReason = "Kein Verkaufspreis"
            elseif not entry.itemLevel or entry.itemLevel <= 0 then
                canSell = false
                skipReason = "Kein ItemLevel"
            elseif itemType == "Quest" or itemSubType == "Quest" then
                canSell = false  
                skipReason = "Quest Item"
            elseif itemType == "Key" or itemSubType == "Key" then
                canSell = false
                skipReason = "Schlüssel"
            elseif itemClassID == 12 then -- Quest items haben oft ClassID 12
                canSell = false
                skipReason = "Quest ClassID"
            elseif info.isBound and info.isBound == true then
                -- Zusätzliche Prüfung auf Binding-Status
                -- Manche gebundene Items können trotzdem verkauft werden
                DebugPrint(string.format("Item ist gebunden: %s", itemName or "Unknown"))
            end
            
            if canSell then
                -- Item auf den Cursor legen (wird beim Verkaufen benötigt)
                C_Container.UseContainerItem(entry.bag, entry.slot)
                DebugPrint(string.format("Verkaufsversuch für: %s (Preis: %sc)", 
                    itemName or "Unknown", currentPrice))
                -- NICHT sofort ClearCursor() aufrufen, da bei Gegenständen
                -- mit Handels-Timer das Bestätigungsfenster (StaticPopup)
                -- eine Aktion auf das Cursor-Item erwartet. ClearCursor würde
                -- das Item verwerfen und der Verkauf schlägt fehl.
            else
                DebugPrint(string.format("Item übersprungen - %s: %s", 
                    skipReason, itemName or "Unknown"))
            end
        else
            DebugPrint(string.format("Item übersprungen (nicht verfügbar): %s", 
                entry.itemName or "Unknown"))
        end
    end

    -- Wenn noch Items in der Queue sind, nach kurzer Verzögerung weitermachen
    if #sellQueue > 0 then
        C_Timer.After(0.15, ProcessQueue) -- 150 ms Verzögerung
    else
        sellingActive = false
        print(string.format("%s: Verkauf abgeschlossen (%d Item(s)).", addonName, queueTotal))
    end
end

-- Verkaufsprozess ohne Token-Prüfung (wird vom Token-GUI oder direkt aufgerufen)
local function StartDirectSell()
    wipe(sellQueue)
    sellingActive = true
    queueTotal = 0
    local skippedTokens = 0

    for bag = 0, NUM_BAG_SLOTS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and not info.isLocked then
                -- ERSTE PRIORITÄT: ItemLevel-Prüfung - ALLES andere wird nur gemacht wenn ItemLevel gültig ist
                local itemLevel = GetItemLevel(bag, slot, info.hyperlink)
                local itemName = GetItemInfo(info.hyperlink) or "Unknown"
                
                if itemLevel and itemLevel > 0 and itemLevel >= db.min and itemLevel <= db.max then
                    -- ZWEITE PRIORITÄT: Nur echte Ausrüstungsgegenstände verkaufen
                    local _, _, _, _, _, itemType, itemSubType, _, itemEquipLoc, _, _, itemClassID, itemSubClassID = GetItemInfo(info.hyperlink)
                    
                    -- Definiere erlaubte Equipment-Slots (nur echte Ausrüstung)
                    local validEquipSlots = {
                        INVTYPE_HEAD = true,        -- Helm
                        INVTYPE_NECK = true,        -- Hals
                        INVTYPE_SHOULDER = true,    -- Schulter
                        INVTYPE_BODY = true,        -- Hemd
                        INVTYPE_CHEST = true,       -- Brust
                        INVTYPE_ROBE = true,        -- Robe
                        INVTYPE_WAIST = true,       -- Gürtel
                        INVTYPE_LEGS = true,        -- Beine
                        INVTYPE_FEET = true,        -- Füße
                        INVTYPE_WRIST = true,       -- Handgelenk
                        INVTYPE_HAND = true,        -- Hände
                        INVTYPE_FINGER = true,      -- Finger
                        INVTYPE_TRINKET = true,     -- Schmuckstück
                        INVTYPE_CLOAK = true,       -- Umhang
                        INVTYPE_WEAPON = true,      -- Einhandwaffe
                        INVTYPE_2HWEAPON = true,    -- Zweihandwaffe
                        INVTYPE_WEAPONMAINHAND = true, -- Haupthand
                        INVTYPE_WEAPONOFFHAND = true,  -- Nebenhand
                        INVTYPE_SHIELD = true,      -- Schild
                        INVTYPE_RANGED = true,      -- Fernkampfwaffe
                        INVTYPE_RANGEDRIGHT = true, -- Fernkampf rechts
                        INVTYPE_HOLDABLE = true,    -- Gehaltener Gegenstand
                        INVTYPE_RELIC = true,       -- Artefakt-Relikte
                    }
                    
                    -- Zusätzliche Prüfung über ItemClass (Waffen = 2, Rüstung = 4, Gems = 3 für manche Relikte)
                    local isValidItemClass = (itemClassID == 2 or itemClassID == 4 or itemClassID == 3) -- Waffen, Rüstung oder Gems
                    local isValidEquipSlot = validEquipSlots[itemEquipLoc]
                    
                    -- Spezielle Prüfung für Artefakt-Relikte (können verschiedene SubTypes haben)
                    local isArtifactRelic = false
                    if itemSubType and (string.find(itemSubType, "Relic") or string.find(itemSubType, "Relikt")) then
                        isArtifactRelic = true
                    end
                    
                    if (not isValidEquipSlot or not isValidItemClass) and not isArtifactRelic then
                        DebugPrint(string.format("Kein Equipment ignoriert: %s (iLvl %d, EquipLoc: %s, ClassID: %s, SubType: %s)", 
                            itemName, itemLevel, tostring(itemEquipLoc), tostring(itemClassID), tostring(itemSubType)))
                    else
                        -- Erweiterte Preis-Prüfung mit mehreren Fallback-Methoden
                        local price = info.vendorPrice
                        if not price or price <= 0 then
                            -- Fallback über GetItemInfo
                            price = select(11, GetItemInfo(info.itemID or info.hyperlink)) or 0
                        end
                        if not price or price <= 0 then
                            -- Zusätzlicher Fallback über Hyperlink
                            local _, _, _, _, _, _, _, _, _, _, vendorPrice = GetItemInfo(info.hyperlink)
                            price = vendorPrice or 0
                        end
                        
                        if price and price > 0 then
                            -- Umfassende Prüfung auf problematische Item-Kategorien
                            local isProblematic = false
                            local problemReason = ""
                            
                            -- Questgegenstände, Schlüssel und andere unverkäufliche Items ausschließen
                            if itemType then
                                if itemType == "Quest" or itemSubType == "Quest" then
                                    isProblematic = true
                                    problemReason = "Quest Item"
                                elseif itemType == "Key" or itemSubType == "Key" then
                                    isProblematic = true
                                    problemReason = "Schlüssel"
                                elseif itemClassID == 12 then -- Quest items
                                    isProblematic = true
                                    problemReason = "Quest ClassID"
                                end
                            end
                            
                            if not isProblematic then
                                -- Prüfe ob es ein Warband Token ist
                                if ShouldSkipItem(info.hyperlink, info.itemID) then
                                    skippedTokens = skippedTokens + 1
                                    DebugPrint(string.format("Warband Token übersprungen: %s (iLvl %d)", 
                                        itemName, itemLevel))
                                else
                                    -- HIER kommen nur Items an die: gültiges ItemLevel im Range haben, anlegbar sind, Verkaufspreis haben, nicht problematisch sind
                                    DebugPrint(string.format("Zur Queue hinzugefügt: %s (iLvl %d, Preis: %sc, EquipLoc: %s)", 
                                        itemName, itemLevel, price, itemEquipLoc))
                                    tinsert(sellQueue, { bag = bag, slot = slot, price = price, itemName = itemName, itemLevel = itemLevel })
                                    queueTotal = queueTotal + 1
                                end
                            else
                                DebugPrint(string.format("Item gefiltert (%s): %s (iLvl %d)", 
                                    problemReason, itemName, itemLevel))
                            end
                        else
                            DebugPrint(string.format("Item ohne Verkaufspreis ignoriert: %s (iLvl %d)", 
                                itemName, itemLevel))
                        end
                    end
                else
                    if not itemLevel or itemLevel <= 0 then
                        DebugPrint(string.format("Item ohne ItemLevel ignoriert: %s", 
                            itemName))
                    else
                        DebugPrint(string.format("Item außerhalb Level-Bereich ignoriert: %s (iLvl %d, Range: %d-%d)", 
                            itemName, itemLevel, db.min, db.max))
                    end
                end
            end
        end
    end

    if skippedTokens > 0 then
        print(string.format("%s: %d Warband Token(s) übersprungen.", addonName, skippedTokens))
    end

    if queueTotal == 0 then
        print(addonName .. ": Keine passenden Items gefunden.")
        return
    end

    print(string.format("%s: Verkaufe %d Item(s)...", addonName, queueTotal))
    ProcessQueue()
end

------------------------------------------------------------------------
-- GUI: Token‑Management‑Frame                                         --
------------------------------------------------------------------------
local function CreateTokenFrame()
    if tokenFrame then return end -- schon erstellt

    -- Berechne benötigte Breite basierend auf Token-Namen
    local minWidth = 550 -- Erhöht für breitere Buttons
    local maxWidth = 800 -- Auch Maximum erhöht
    local requiredWidth = minWidth
    
    local tokens = FindTierTokens()
    for i, token in ipairs(tokens) do
        local itemName = token.name or "Unknown Item"
        local itemLevel = token.itemLevel or 0
        local displayText = string.format("%s (iLvl %d)", itemName, itemLevel)
        local textWidth = displayText:len() * 7 + 230 -- Schätzung + Puffer für 2 breitere Buttons und Icon
        if textWidth > requiredWidth then
            requiredWidth = textWidth
        end
    end
    
    -- Begrenzen auf maxWidth
    if requiredWidth > maxWidth then
        requiredWidth = maxWidth
    end

    tokenFrame = CreateFrame("Frame", "GearScoreVendorTokenFrame", UIParent, "BackdropTemplate")
    tokenFrame:SetSize(requiredWidth, 350)
    tokenFrame:SetPoint("CENTER")
    tokenFrame.frameWidth = requiredWidth -- Speichere Breite für später
    tokenFrame:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile     = true, tileSize = 16, edgeSize = 16,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    tokenFrame:SetBackdropColor(0, 0, 0, 0.9)
    tokenFrame:EnableMouse(true)
    tokenFrame:SetMovable(true)
    tokenFrame:RegisterForDrag("LeftButton")
    tokenFrame:SetScript("OnDragStart", tokenFrame.StartMoving)
    tokenFrame:SetScript("OnDragStop",  tokenFrame.StopMovingOrSizing)
    tokenFrame:SetFrameStrata("DIALOG")

    local title = tokenFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Warband Tokens gefunden!")

    local subtitle1 = tokenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subtitle1:SetPoint("TOP", 0, -32)
    subtitle1:SetText(string.format("Items im Level-Bereich %d-%d", db.min, db.max))

    local subtitle2 = tokenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subtitle2:SetPoint("TOP", 0, -48)
    subtitle2:SetText("Möchten Sie diese Tokens vor dem Verkauf verwenden?")

    -- Skip Warband Tokens Checkbox (zentriert)
    local skipCheckbox = CreateFrame("CheckButton", nil, tokenFrame, "UICheckButtonTemplate")
    skipCheckbox:SetSize(24, 24)
    
    local skipLabel = tokenFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    skipLabel:SetText("Warband Tokens beim Verkauf überspringen")
    skipLabel:SetTextColor(1, 1, 1)
    
    -- Berechne Gesamtbreite für Zentrierung
    local labelWidth = skipLabel:GetStringWidth()
    local totalWidth = 24 + 5 + labelWidth -- Checkbox + Abstand + Text
    
    -- Zentriere die gesamte Checkbox+Label Kombination
    skipCheckbox:SetPoint("TOP", -(totalWidth/2) + 12, -70)
    skipLabel:SetPoint("LEFT", skipCheckbox, "RIGHT", 5, 0)
    skipCheckbox:SetChecked(db.skipWarbandTokens)
    
    -- Close (X) Button
    local closeBtn = CreateFrame("Button", nil, tokenFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -6, -6)

    -- Scroll Frame für Token Liste
    local scrollFrame = CreateFrame("ScrollFrame", "GSVTokenScrollFrame", tokenFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 15, -95)
    scrollFrame:SetPoint("BOTTOMRIGHT", -35, 50)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)

    -- Token Buttons Container
    tokenFrame.tokenButtons = {}

    -- "Alle verwenden" Button
    local useAllBtn = CreateFrame("Button", nil, tokenFrame, "UIPanelButtonTemplate")
    useAllBtn:SetSize(120, 25)
    useAllBtn:SetPoint("BOTTOMLEFT", 15, 15)
    useAllBtn:SetText("Alle verwenden")

    -- "Weiter verkaufen" Button  
    local continueBtn = CreateFrame("Button", nil, tokenFrame, "UIPanelButtonTemplate")
    continueBtn:SetSize(140, 25) -- Einheitliche Höhe
    continueBtn:SetPoint("BOTTOMRIGHT", -15, 15)
    continueBtn:SetText("Weiter verkaufen")

    -- "Abbrechen" Button
    local cancelBtn = CreateFrame("Button", nil, tokenFrame, "UIPanelButtonTemplate")
    cancelBtn:SetSize(100, 25)
    cancelBtn:SetPoint("BOTTOM", 0, 15)
    cancelBtn:SetText("Abbrechen")

    -- Funktion zum Aktualisieren der Token-Liste
    function tokenFrame:UpdateTokenList()
        -- Alte Buttons entfernen und Frame-Referenzen aufräumen
        for _, btn in ipairs(self.tokenButtons) do
            btn:Hide()
            btn:SetParent(nil)
            -- Explizit alle Scripts entfernen um Memory-Leaks zu vermeiden
            btn:SetScript("OnClick", nil)
            btn:SetScript("OnEnter", nil)
            btn:SetScript("OnLeave", nil)
        end
        wipe(self.tokenButtons)

        local tokens = FindTierTokens()
        if #tokens == 0 then
            self:Hide()
            return
        end

        local yOffset = -10
        for i, token in ipairs(tokens) do
            local tokenBtn = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
            local btnWidth = (self.frameWidth or 550) - 60 -- Abzug für Scrollbar und Padding
            tokenBtn:SetSize(btnWidth, 32)
            tokenBtn:SetPoint("TOPLEFT", 10, yOffset)
            tokenBtn:SetBackdrop({
                bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 }
            })
            tokenBtn:SetBackdropColor(0.1, 0.1, 0.2, 0.8)
            tokenBtn:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

            -- Icon
            local icon = tokenBtn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(24, 24)
            icon:SetPoint("LEFT", 4, 0)
            if token.texture then
                icon:SetTexture(token.texture)
            end

            -- Item Name with Level
            local nameText = tokenBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            nameText:SetPoint("RIGHT", tokenBtn, "RIGHT", -185, 0) -- Platz für beide breitere Buttons lassen
            nameText:SetText(string.format("%s (iLvl %d)", token.name, token.itemLevel or 0))
            nameText:SetTextColor(1, 1, 1)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)

            -- Verkaufen Button
            local sellBtn = CreateFrame("Button", nil, tokenBtn, "UIPanelButtonTemplate")
            sellBtn:SetSize(85, 20)
            sellBtn:SetPoint("RIGHT", -8, 0)
            sellBtn:SetText("Verkaufen")

            sellBtn:SetScript("OnClick", function()
                print(string.format("%s: %s verkauft.", addonName, token.name))
                -- Item direkt verkaufen (moderne API)
                C_Container.UseContainerItem(token.bag, token.slot)
                C_Timer.After(0.5, function()
                    tokenFrame:UpdateTokenList()
                end)
            end)

            -- Use Button
            local useBtn = CreateFrame("Button", nil, tokenBtn, "UIPanelButtonTemplate")
            useBtn:SetSize(85, 20)
            useBtn:SetPoint("RIGHT", sellBtn, "LEFT", -5, 0)
            useBtn:SetText("Verwenden")

            useBtn:SetScript("OnClick", function()
                print(string.format("%s: %s verwendet.", addonName, token.name))
                UseToken(token.bag, token.slot)
                C_Timer.After(2, function() -- Länger warten für Merchant-Hide/Show Cycle
                    if tokenFrame and tokenFrame:IsShown() then
                        tokenFrame:UpdateTokenList()
                    end
                end)
            end)

            -- Tooltip beim Hover
            tokenBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(token.hyperlink)
                GameTooltip:Show()
            end)

            tokenBtn:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
            end)

            table.insert(self.tokenButtons, tokenBtn)
            yOffset = yOffset - 40
        end

        -- ScrollChild Höhe anpassen
        scrollChild:SetHeight(math.max(1, #tokens * 40 + 20))
    end

    -- Button Scripts
    useAllBtn:SetScript("OnClick", function()
        local tokens = FindTierTokens()
        if #tokens > 0 then
            print(string.format("%s: %d Token(s) werden verwendet...", addonName, #tokens))
            -- Tokens nacheinander mit Verzögerung verwenden
            local index = 1
            local function UseNextToken()
                if index <= #tokens then
                    local token = tokens[index]
                    UseToken(token.bag, token.slot)
                    index = index + 1
                    -- Nächstes Token nach Verzögerung
                    C_Timer.After(0.5, UseNextToken)
                else
                    -- Alle Tokens verwendet, UI aktualisieren
                    C_Timer.After(2, function()
                        if tokenFrame and tokenFrame:IsShown() then
                            tokenFrame:UpdateTokenList()
                        end
                    end)
                end
            end
            UseNextToken()
        end
    end)

    continueBtn:SetScript("OnClick", function()
        tokenFrame:Hide()
        StartDirectSell() -- Verkaufsprozess starten
    end)
    
    -- Button-Text dynamisch anpassen basierend auf Checkbox-Status
    local function UpdateContinueButtonText()
        if db.skipWarbandTokens then
            continueBtn:SetText("Weiter verkaufen")
        else
            continueBtn:SetText("Alles verkaufen")
        end
    end
    
    -- Initial setzen
    UpdateContinueButtonText()
    
    -- Checkbox-Handler erweitern um Button-Text zu aktualisieren
    skipCheckbox:SetScript("OnClick", function(self)
        db.skipWarbandTokens = self:GetChecked()
        local status = db.skipWarbandTokens and "aktiviert" or "deaktiviert"
        print(string.format("%s: Warband Token Skip %s.", addonName, status))
        UpdateContinueButtonText()
    end)

    cancelBtn:SetScript("OnClick", function()
        tokenFrame:Hide()
    end)

    tokenFrame:SetScript("OnShow", function(self)
        self:UpdateTokenList()
    end)

    tinsert(UISpecialFrames, tokenFrame:GetName()) -- Esc schließt
    tokenFrame:Hide()
end

local function SellItems()
    if not MerchantFrame or not MerchantFrame:IsShown() then
        print(addonName .. ": Du musst ein Händlerfenster geöffnet haben, um Items zu verkaufen.")
        return
    end

    -- Prüfe zuerst, ob Tier Tokens vorhanden sind
    local tokens = FindTierTokens()
    DebugPrint(string.format("Gefundene Tokens: %d", #tokens))
    
    if #tokens > 0 then
        CreateTokenFrame()
        tokenFrame:Show()
        return -- Token-GUI wird den Verkaufsprozess ggf. fortsetzen
    end

    -- Kein Token-GUI nötig, direkt verkaufen
    StartDirectSell()
end



------------------------------------------------------------------------
-- GUI: Options‑Frame                                                   --
------------------------------------------------------------------------
local optionsFrame
local merchantButton
local tokenFrame

local function CreateOptionsFrame()
    if optionsFrame then return end

    -- Hauptframe
    optionsFrame = CreateFrame("Frame", "GearScoreVendorOptions", UIParent, "BackdropTemplate")
    optionsFrame:SetSize(380, 320)
    optionsFrame:SetPoint("CENTER")
    optionsFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    optionsFrame:SetBackdropColor(0, 0, 0, 0.9)
    optionsFrame:EnableMouse(true)
    optionsFrame:SetMovable(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
    optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
    optionsFrame:SetClampedToScreen(true)

    -- Titel
    local title = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("GearScoreVendor")

    -- Close Button
    local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Vor-Deklarationen
    local minEdit, maxEdit, nameEdit

    -- Min Item Level
    local minLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    minLabel:SetPoint("TOPLEFT", 30, -50)
    minLabel:SetText("Min Item Level:")

    minEdit = CreateFrame("EditBox", nil, optionsFrame, "InputBoxTemplate")
    minEdit:SetSize(60, 20)
    minEdit:SetPoint("LEFT", minLabel, "RIGHT", 10, 0)
    minEdit:SetAutoFocus(false)
    minEdit:SetNumeric(true)

    -- Max Item Level
    local maxLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    maxLabel:SetPoint("TOPLEFT", minLabel, "BOTTOMLEFT", 0, -15)
    maxLabel:SetText("Max Item Level:")

    maxEdit = CreateFrame("EditBox", nil, optionsFrame, "InputBoxTemplate")
    maxEdit:SetSize(60, 20)
    maxEdit:SetPoint("LEFT", maxLabel, "RIGHT", 10, 0)
    maxEdit:SetAutoFocus(false)
    maxEdit:SetNumeric(true)

    -- Preset Dropdown
    local presetLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    presetLabel:SetPoint("TOPLEFT", maxLabel, "BOTTOMLEFT", 0, -25)
    presetLabel:SetText("Preset:")

    local presetDrop = CreateFrame("Frame", "GSVPresetDropDown", optionsFrame, "UIDropDownMenuTemplate")
    presetDrop:SetPoint("LEFT", presetLabel, "RIGHT", -15, -2)
    UIDropDownMenu_SetWidth(presetDrop, 150)

    -- Preset Name
    local nameLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", presetLabel, "BOTTOMLEFT", 0, -30)
    nameLabel:SetText("Preset Name:")

    nameEdit = CreateFrame("EditBox", nil, optionsFrame, "InputBoxTemplate")
    nameEdit:SetSize(150, 20)
    nameEdit:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    nameEdit:SetAutoFocus(false)

    -- Skip Warband Tokens Checkbox
    local skipTokensCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    skipTokensCheck:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", -5, -35)
    skipTokensCheck.text = skipTokensCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    skipTokensCheck.text:SetPoint("LEFT", skipTokensCheck, "RIGHT", 0, 0)
    skipTokensCheck.text:SetText("Warband Tokens überspringen")
    skipTokensCheck:SetChecked(db.skipWarbandTokens)

    -- Debug Mode Checkbox
    local debugCheck = CreateFrame("CheckButton", nil, optionsFrame, "UICheckButtonTemplate")
    debugCheck:SetPoint("TOPLEFT", skipTokensCheck, "BOTTOMLEFT", 0, -5)
    debugCheck.text = debugCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    debugCheck.text:SetPoint("LEFT", debugCheck, "RIGHT", 0, 0)
    debugCheck.text:SetText("Debug-Modus")
    debugCheck:SetChecked(db.debugMode)

    -- Speichern Button
    local applyBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    applyBtn:SetSize(80, 22)
    applyBtn:SetPoint("BOTTOMRIGHT", -20, 20)
    applyBtn:SetText("Speichern")

    -- Preset speichern Button
    local presetBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    presetBtn:SetSize(110, 22)
    presetBtn:SetPoint("BOTTOMLEFT", 20, 20)
    presetBtn:SetText("Preset speichern")

    -- Preset löschen Button
    local deleteBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
    deleteBtn:SetSize(90, 22)
    deleteBtn:SetPoint("BOTTOM", 0, 20)
    deleteBtn:SetText("Preset löschen")

    -- UpdatePresetDropdown Funktion
    function optionsFrame:UpdatePresetDropdown()
        UIDropDownMenu_Initialize(presetDrop, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            
            -- "Kein Preset" Option
            info.text = "Kein Preset"
            info.func = function()
                nameEdit:SetText("")
                UIDropDownMenu_SetText(presetDrop, "Kein Preset")
            end
            UIDropDownMenu_AddButton(info)
            
            -- Presets
            for name, preset in pairs(db.presets or {}) do
                info = UIDropDownMenu_CreateInfo()
                info.text = string.format("%s (%d-%d)", name, preset.min, preset.max)
                info.func = function()
                    db.min = preset.min
                    db.max = preset.max
                    minEdit:SetText(db.min)
                    maxEdit:SetText(db.max)
                    nameEdit:SetText(name)
                    UIDropDownMenu_SetText(presetDrop, name)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)

        -- Auswahl setzen falls aktuell
        local foundPreset = false
        for name, preset in pairs(db.presets or {}) do
            if db.min == preset.min and db.max == preset.max then
                UIDropDownMenu_SetText(presetDrop, name)
                foundPreset = true
                break
            end
        end
        
        if not foundPreset then
            UIDropDownMenu_SetText(presetDrop, "Kein Preset")
        end
    end

    -- Event Handlers
    applyBtn:SetScript("OnClick", function()
        local newMin = tonumber(minEdit:GetText()) or 0
        local newMax = tonumber(maxEdit:GetText()) or 0
        db.min = Clamp(newMin, 0, 10000)
        db.max = Clamp(newMax, 0, 10000)
        print(string.format("%s: Verkaufe Items mit Item Level %d–%d.", addonName, db.min, db.max))
        if MerchantFrame and MerchantFrame:IsShown() then
            SellItems()
        end
        optionsFrame:Hide()
    end)

    presetBtn:SetScript("OnClick", function()
        local name = nameEdit:GetText():gsub("^%s+",""):gsub("%s+$","")
        if name == "" then
            print(addonName .. ": Bitte einen Preset-Namen eingeben.")
            return
        end
        db.presets = db.presets or {}
        db.presets[name] = { min = db.min, max = db.max }
        print(string.format("%s: Preset '%s' (%d-%d) gespeichert.", addonName, name, db.min, db.max))
        optionsFrame:UpdatePresetDropdown()
    end)

    deleteBtn:SetScript("OnClick", function()
        local name = nameEdit:GetText():gsub("^%s+",""):gsub("%s+$","")
        if name == "" then
            print(addonName .. ": Bitte ein Preset zum Löschen wählen.")
            return
        end
        if db.presets and db.presets[name] then
            db.presets[name] = nil
            print(string.format("%s: Preset '%s' gelöscht.", addonName, name))
            nameEdit:SetText("")
            optionsFrame:UpdatePresetDropdown()
        else
            print(string.format("%s: Preset '%s' nicht gefunden.", addonName, name))
        end
    end)

    skipTokensCheck:SetScript("OnClick", function(self)
        db.skipWarbandTokens = self:GetChecked()
    end)

    debugCheck:SetScript("OnClick", function(self)
        db.debugMode = self:GetChecked()
    end)

    -- OnShow Handler
    optionsFrame:SetScript("OnShow", function()
        minEdit:SetText(db.min)
        maxEdit:SetText(db.max)
        nameEdit:SetText("")
        skipTokensCheck:SetChecked(db.skipWarbandTokens)
        debugCheck:SetChecked(db.debugMode)
        minEdit:ClearFocus()
        maxEdit:ClearFocus()
        optionsFrame:UpdatePresetDropdown()
    end)

    tinsert(UISpecialFrames, optionsFrame:GetName())
    optionsFrame:Hide()
end

local function CreateMerchantButton()
    if merchantButton then return end -- schon erstellt

    merchantButton = CreateFrame("Button", "GearScoreVendorMerchantButton", MerchantFrame, "UIPanelButtonTemplate")
    merchantButton:SetSize(90, 18)
    -- Position rechts neben dem "Buyback" Tab, aber unterhalb der Tab-Leiste
    merchantButton:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -10, -60)
    merchantButton:SetText("GSV Verkauf")
    merchantButton:SetFrameStrata("HIGH") -- Höhere Z-Koordinate für bessere Sichtbarkeit
    merchantButton:SetFrameLevel(100) -- Noch höhere Priorität
    merchantButton:SetScript("OnClick", SellItems)
    
    -- Tooltip hinzufügen für bessere Benutzerfreundlichkeit
    merchantButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("GearScoreVendor", 1, 1, 1)
        GameTooltip:AddLine(string.format("Verkauft Items mit Item-Level %d-%d", db.min, db.max), nil, nil, nil, true)
        GameTooltip:AddLine("Warband Tokens werden übersprungen", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    
    merchantButton:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
end



------------------------------------------------------------------------
-- GUI: Minimap‑Button (mit LibDBIcon)                                 --
------------------------------------------------------------------------
local LDB, LDBIcon

------------------------------------------------------------------------
-- Slash‑Commands                                                       --
------------------------------------------------------------------------
local function PrintUsage()
    print("|cffffff78/gsv min <zahl>|r  – Setzt das minimale Item-Level.")
    print("|cffffff78/gsv max <zahl>|r  – Setzt das maximale Item-Level.")
    print("|cffffff78/gsv show|r        – Zeigt die aktuellen Werte an.")
    print("|cffffff78/gsv preset <name> <min> <max>|r – Erstellt/überschreibt ein Preset.")
    print("|cffffff78/gsv use <name>|r       – Wendet ein Preset an.")
    print("|cffffff78/gsv list|r             – Listet alle Presets.")
    print("|cffffff78/gsv sell|r        – Startet den Verkauf im Händlerfenster.")
    print("|cffffff78/gsv tokens|r      – Zeigt Token-Management GUI.")
    print("|cffffff78/gsv debug|r       – Schaltet Debug-Meldungen ein/aus.")
    print("|cffffff78/gsv icon|r        – Zeigt/versteckt das Minimap-Symbol.")
end

local function SlashHandler(msg)
    -- Robusteres Parsen von Befehlen
    local cmd, val = strsplit(" ", msg:lower(), 2)
    cmd = cmd or ""

    if cmd == "" or cmd == "gui" or cmd == "options" then
        CreateOptionsFrame()
        optionsFrame:SetShown(not optionsFrame:IsShown())
    elseif cmd == "min" then
        local num = tonumber(val)
        if num then
            db.min = Clamp(num, 0, 10000)
            print(string.format("%s: Minimales Item-Level auf %d gesetzt.", addonName, db.min))
        else
            PrintUsage()
        end
    elseif cmd == "max" then
        local num = tonumber(val)
        if num then
            db.max = Clamp(num, 0, 10000)
            print(string.format("%s: Maximales Item-Level auf %d gesetzt.", addonName, db.max))
        else
            PrintUsage()
        end
    elseif cmd == "show" then
        print(string.format("%s: Verkauft Items mit Item-Level von %d bis %d.", addonName, db.min, db.max))
    elseif cmd == "preset" then
        local _, name, min, max = strsplit(" ", msg:lower(), 4)
        if name and min and max then
            local numMin = tonumber(min)
            local numMax = tonumber(max)
            if numMin and numMax then
                db.presets = db.presets or {}
                db.presets[name] = { min = Clamp(numMin, 0, 10000), max = Clamp(numMax, 0, 10000) }
                print(string.format("%s: Preset '%s' mit Item-Level %d-%d gespeichert.", addonName, name, db.presets[name].min, db.presets[name].max))
            else
                PrintUsage()
            end
        else
            PrintUsage()
        end
    elseif cmd == "use" then
        local _, name = strsplit(" ", msg:lower(), 2)
        if name then
            if db.presets and db.presets[name] then
                db.min = db.presets[name].min
                db.max = db.presets[name].max
                print(string.format("%s: Preset '%s' (%d-%d) angewendet.", addonName, name, db.min, db.max))
                SellItems()
            else
                print(string.format("%s: Preset '%s' nicht gefunden.", addonName, name))
            end
        else
            PrintUsage()
        end
    elseif cmd == "list" then
        if db.presets and next(db.presets) then
            print(string.format("%s: Alle gespeicherten Presets:", addonName))
            for name, preset in pairs(db.presets) do
                print(string.format("  - %s (%d-%d)", name, preset.min, preset.max))
            end
        else
            print(string.format("%s: Keine gespeicherten Presets gefunden.", addonName))
        end
    elseif cmd == "sell" then
        SellItems()
    elseif cmd == "tokens" then
        CreateTokenFrame()
        local tokens = FindTierTokens()
        if #tokens > 0 then
            tokenFrame:Show()
        else
            print(addonName .. ": Keine Warband Tokens im Inventar gefunden.")
        end
    elseif cmd == "delete" then
        local _, name = strsplit(" ", msg, 2)
        if name and db.presets and db.presets[name] then
            db.presets[name] = nil
            print(string.format("%s: Preset '%s' gelöscht.", addonName, name))
        else
            print(string.format("%s: Preset '%s' nicht gefunden.", addonName, name or ""))
        end
    elseif cmd == "debug" then
        db.debugMode = not db.debugMode
        local status = db.debugMode and "aktiviert" or "deaktiviert"
        print(string.format("%s: Debug-Modus %s.", addonName, status))
    elseif cmd == "icon" then
        if LDBIcon then
            db.minimap.hide = not db.minimap.hide
            if db.minimap.hide then
                LDBIcon:Hide("GearScoreVendor")
                print(addonName .. ": Minimap-Symbol versteckt.")
            else
                LDBIcon:Show("GearScoreVendor")
                print(addonName .. ": Minimap-Symbol angezeigt.")
            end
        else
            print(addonName .. ": Minimap-Button nicht gefunden.")
        end
    else
        PrintUsage()
    end
end

------------------------------------------------------------------------
-- Event‑Frame                                                          --
------------------------------------------------------------------------
local f = CreateFrame("Frame")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            -- SavedVariables laden / initialisieren
            GearScoreVendorDB = GearScoreVendorDB or {}
            db = GearScoreVendorDB
            for k, v in pairs(defaults) do
                if type(v) == "table" then
                    db[k] = db[k] or {}
                    for sk, sv in pairs(v) do
                        if db[k][sk] == nil then db[k][sk] = sv end
                    end
                elseif db[k] == nil then
                    db[k] = v
                end
            end

            -- SlashCmd registrieren
            SLASH_GEARSCOREVENDOR1 = "/gsv"
            SlashCmdList["GEARSCOREVENDOR"] = SlashHandler

            -- LibDataBroker und Minimap-Button initialisieren
            LDB = LibStub("LibDataBroker-1.1"):NewDataObject("GearScoreVendor", {
                type = "launcher",
                icon = "Interface\\AddOns\\GearScoreVendor\\Assets\\icon",
                OnClick = function(_, button)
                    if button == "LeftButton" then
                        CreateOptionsFrame()
                        optionsFrame:SetShown(not optionsFrame:IsShown())
                    elseif button == "RightButton" then
                        -- Rechtsklick zeigt Hilfe
                        PrintUsage()
                    end
                end,
                OnTooltipShow = function(tooltip)
                    tooltip:AddLine("|cffffffffGearScoreVendor")
                    tooltip:AddLine(string.format("Verkauft Items mit Item-Level %d-%d", db.min, db.max))
                    tooltip:AddLine(" ")
                    tooltip:AddLine("|cff00ff00Linksklick:|r Optionen öffnen")
                    tooltip:AddLine("|cff00ff00Rechtsklick:|r Hilfe anzeigen")
                end,
            })
            
            LDBIcon = LibStub("LibDBIcon-1.0")
            LDBIcon:Register("GearScoreVendor", LDB, db.minimap)

        end

    elseif event == "MERCHANT_SHOW" then
        CreateMerchantButton()
        if merchantButton then merchantButton:Show() end

    elseif event == "MERCHANT_CLOSED" then
        if merchantButton then
            merchantButton:Hide()
        end
    end
end)

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")

-- Globale Flag für den Verkaufsvorgang (muss für den Hook verfügbar sein)
sellingActive = false

-- Automatisch Popups bestätigen, wenn wir verkaufen
hooksecurefunc("StaticPopup_Show", function(which, ...)
    if which == "CONFIRM_MERCHANT_TRADE_TIMER_REMOVAL" and sellingActive then
        C_Timer.After(0, function()
            for i = 1, STATICPOPUP_NUMDIALOGS do
                local frame = _G["StaticPopup"..i]
                if frame and frame:IsShown() and frame.which == which then
                    frame.button1:Click()
                    break
                end
            end
        end)
    end
end)
