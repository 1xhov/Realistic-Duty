local userData = {}

-- Impound / tow configuration
-- Single configured tow yard (impound) with heading
local impoundLocations = {
    { x = 2365.5063, y = 3115.6067, z = 48.3112, h = 12.6129 },
}
local towFee = 150 -- default tow fee (server owners can edit)

-- Active tows tracked by ticket -> info
local activeTows = {}

-- Periodic cleanup of stale tows (best-effort)
Citizen.CreateThread(function()
    while true do
        local now = os.time()
        for ticket, info in pairs(activeTows) do
            if info and info.created and (now - info.created > 60 * 60 * 24) then
                activeTows[ticket] = nil
            end
        end
        Citizen.Wait(60 * 60 * 1000) -- check hourly
    end
end)

-- Track players who are on duty (have LEO perms)
local dutyPlayers = {}
-- Track duty blips by server id
local dutyBlips = {}
-- Track more detailed duty info (since timestamp)
local dutyInfo = {}

-- Use FiveM resource file helpers for robust file operations inside the resource
local function loadUserDataFromResource()
    local resourceName = GetCurrentResourceName()
    local content = nil
    -- LoadResourceFile returns nil if the file doesn't exist
    content = LoadResourceFile(resourceName, 'user_data.json')
    if content and content ~= '' then
        userData = json.decode(content) or {}
        print(('bodycam: loaded user_data.json (%d entries)'):format(#userData))
    else
        userData = {}
        print('bodycam: no existing user_data.json, starting with empty data')
    end
end

-- Save user data to the resource folder using SaveResourceFile
local function saveUserData()
    local resourceName = GetCurrentResourceName()
    local content = json.encode(userData)
    -- SaveResourceFile returns true/false
    local ok = SaveResourceFile(resourceName, 'user_data.json', content, -1)
    if ok then
        print('bodycam: user_data.json saved')
    else
        print('bodycam: failed to save user_data.json')
    end
end

-- Load data on resource start
-- Forward declare postals loader so it can be invoked during onServerResourceStart
local postalsList = {}
local loadPostals

AddEventHandler('onServerResourceStart', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        print(('bodycam: server.lua started for resource %s'):format(resourceName))
        loadUserDataFromResource()
        -- Load postals list if present
        if LoadResourceFile then
            local ok, _ = pcall(function() end)
        end
        -- call loadPostals if defined later
        -- loadPostals is defined above (moved) and will be called here
        if type(loadPostals) == 'function' then
            loadPostals()
        end
        -- Ensure ACEs exist for this resource so add_principal grants work as expected
        local res = GetCurrentResourceName()
        local ok1, _ = pcall(function()
            ExecuteCommand(('add_ace resource.%s bodycam.leo allow'):format(res))
        end)
        local ok2, _ = pcall(function()
            ExecuteCommand(('add_ace resource.%s bodycam.testai allow'):format(res))
        end)
        if ok1 and ok2 then
            print('bodycam: ensured ACEs bodycam.leo and bodycam.testai are registered for resource ' .. res)
        else
            print('bodycam: failed to ensure ACEs on resource start (commands may not be supported)')
        end
    end
end)

-- Helper to send a notify payload to a client
local function sendClientNotify(targetServerId, title, text, ntype, badge)
    ntype = ntype or 'info'
    badge = badge or 'DISPATCH'
    TriggerClientEvent('bodycam:notify', targetServerId, { title = title, text = text, type = ntype, badge = badge })
end


-- Try to charge a player using common frameworks; this is best-effort and will not error
local function tryChargePlayer(serverId, amount)
    if not serverId or not amount or amount <= 0 then return false end
    local ok = false
    -- Fire a generic server event other resources can hook into
    pcall(function()
        TriggerEvent('bodycam:chargePlayer', serverId, amount)
    end)

    -- Try ESX pattern
    pcall(function()
        local esx = nil
        -- attempt to get shared object from ESX
        TriggerEvent('esx:getSharedObject', function(obj) esx = obj end)
        if esx then
            local xPlayer = esx.GetPlayerFromId(serverId)
            if xPlayer and xPlayer.removeMoney then
                xPlayer.removeMoney(amount)
                ok = true
            end
        end
    end)

    -- Try QBCore pattern
    pcall(function()
        local ok2, QBCore = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok2 and QBCore and QBCore.Functions and QBCore.Functions.RemoveMoney then
            QBCore.Functions.RemoveMoney(serverId, 'cash', amount)
            ok = true
        end
    end)

    return ok
end


-- Log a tow action into user data for auditing
local function logTowAction(serverId, data)
    if not serverId then return end
    userData[serverId] = userData[serverId] or {}
    userData[serverId].tows = userData[serverId].tows or {}
    table.insert(userData[serverId].tows, data)
    saveUserData()
end

-- ...attach handler will be defined after aiCalls declaration

-- Handle setting name
RegisterNetEvent('bodycam:setName')
AddEventHandler('bodycam:setName', function(name)
    local src = source
    userData[src] = userData[src] or {}
    userData[src].name = name
    saveUserData()
    TriggerClientEvent('bodycam:updateInfo', src, userData[src])
end)

-- Handle setting callsign
RegisterNetEvent('bodycam:setCallsign')
AddEventHandler('bodycam:setCallsign', function(callsign)
    local src = source
    userData[src] = userData[src] or {}
    userData[src].callsign = callsign
    saveUserData()
    TriggerClientEvent('bodycam:updateInfo', src, userData[src])
end)

-- Handle setting department
RegisterNetEvent('bodycam:setDepartment')
AddEventHandler('bodycam:setDepartment', function(department)
    local src = source
    userData[src] = userData[src] or {}
    userData[src].department = department
    saveUserData()
    TriggerClientEvent('bodycam:updateInfo', src, userData[src])
end)

-- Handle loading user data
RegisterNetEvent('bodycam:loadUserData')
AddEventHandler('bodycam:loadUserData', function()
    local src = source
    if userData[src] then
        TriggerClientEvent('bodycam:updateInfo', src, userData[src])
    end
end)

-- Server event to give weapons (called from client when player confirms)
RegisterNetEvent('bodycam:giveWeapons')
AddEventHandler('bodycam:giveWeapons', function()
    local src = source
    print(('bodycam: giving weapons to player %s'):format(src))
    -- Use server-side player spawn event to give weapons via server trigger
    -- This uses the server to instruct the client to add weapons (since the native GiveWeaponToPed is client-side)
    -- Trigger a client event on the same player to actually give the weapons (trusted from server)
    TriggerClientEvent('bodycam:receiveWeapons', src)
end)

-- Server event to remove weapons (triggered when player clocks off)
RegisterNetEvent('bodycam:removeWeapons')
AddEventHandler('bodycam:removeWeapons', function()
    local src = source
    print(('bodycam: removing weapons for player %s'):format(src))
    TriggerClientEvent('bodycam:removeWeaponsClient', src)
end)


-- Forward LEOPerms grant/revoke so SEM_InteractionMenu or another resource can react
RegisterNetEvent('bodycam:setLEOPerms')
AddEventHandler('bodycam:setLEOPerms', function(enable)
    local src = source
    print(('bodycam: setLEOPerms=%s for player %s'):format(tostring(enable), tostring(src)))
    -- Trigger the expected server event name for other resources to listen to
    -- If SEM_InteractionMenu listens for this server event, it will receive the call
    TriggerEvent('SEM_InteractionMenu:LEOPerms', src, enable)

    -- Grant/revoke ace permissions for bodycam.leo
    local playerId = tonumber(src)
    if playerId then
    local identifier = GetPlayerIdentifier(tostring(playerId), 0)
        if type(identifier) == 'string' and identifier ~= '' then
            if enable then
                -- Grant ace permissions
                ExecuteCommand(('add_principal identifier.%s bodycam.leo'):format(identifier))
                ExecuteCommand(('add_principal identifier.%s bodycam.testai'):format(identifier))
                print(('bodycam: granted ace perms bodycam.leo & bodycam.testai to %s'):format(identifier))
                -- Trigger AI 911 call event
                TriggerEvent('bodycam:ai911Enable', playerId)
                dutyPlayers[playerId] = true
                dutyInfo[playerId] = { since = os.time() }
                -- when enabling, also request client to announce position (client will call announceDuty)
            else
                -- Remove ace permissions
                ExecuteCommand(('remove_principal identifier.%s bodycam.leo'):format(identifier))
                ExecuteCommand(('remove_principal identifier.%s bodycam.testai'):format(identifier))
                print(('bodycam: revoked ace perms bodycam.leo & bodycam.testai from %s'):format(identifier))
                -- Disable AI 911 calls
                TriggerEvent('bodycam:ai911Disable', playerId)
                dutyPlayers[playerId] = nil
                dutyInfo[playerId] = nil
            end
        else
            print(('bodycam: could not find valid identifier for player %s'):format(tostring(playerId)))
        end
    end
end)


-- Provide a list of on-duty units with elapsed time to requesting client
RegisterNetEvent('bodycam:requestOnDuty')
AddEventHandler('bodycam:requestOnDuty', function()
    local src = source
    -- Only allow callers with bodycam.leo permission to request the on-duty list
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to view on-duty officers.', 'error')
        return
    end
    local list = {}
    for pid, info in pairs(dutyInfo) do
        if info and info.since then
            local name = nil
            if userData[pid] and userData[pid].name then
                name = userData[pid].name
            else
                if GetPlayerName(pid) then name = GetPlayerName(pid) end
            end
            local callsign = userData[pid] and userData[pid].callsign or nil
            local elapsed = os.time() - info.since
            table.insert(list, { serverId = pid, name = name, callsign = callsign, since = info.since, elapsed = elapsed })
        end
    end
    TriggerClientEvent('bodycam:receiveOnDutyList', src, list)
end)


-- Server-side spawn validation for vehicles (ACE-protected)
RegisterNetEvent('bodycam:requestSpawnVehicle')
AddEventHandler('bodycam:requestSpawnVehicle', function(modelName)
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to spawn vehicles.', 'error')
        return
    end
    if not modelName or modelName == '' then
        sendClientNotify(src, 'Dispatch', 'Invalid vehicle model.', 'error')
        return
    end
    -- Ask the client to spawn the vehicle (client-side creation) after validation
    TriggerClientEvent('bodycam:leotarget:spawnVehicle', src, { model = modelName })
    sendClientNotify(src, 'Dispatch', 'Vehicle spawn requested.', 'success')
end)


-- Server-side validation wrappers for trunk/leo actions
RegisterNetEvent('bodycam:requestGetArmor')
AddEventHandler('bodycam:requestGetArmor', function()
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to get armor.', 'error')
        return
    end
    TriggerClientEvent('bodycam:leotarget:getArmor', src)
end)

RegisterNetEvent('bodycam:requestPushVehicle')
AddEventHandler('bodycam:requestPushVehicle', function()
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to push vehicles.', 'error')
        return
    end
    TriggerClientEvent('bodycam:leotarget:pushVehicle', src)
end)

RegisterNetEvent('bodycam:requestGrabMedstation')
AddEventHandler('bodycam:requestGrabMedstation', function()
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to grab medstations.', 'error')
        return
    end
    TriggerClientEvent('bodycam:leotarget:grabMedstation', src)
end)


-- Server-side handler to validate a tow request and forward to the requesting client
RegisterNetEvent('bodycam:requestTowVehicle')
AddEventHandler('bodycam:requestTowVehicle', function(targetNetId)
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to tow vehicles.', 'error')
        return
    end
    if not targetNetId then
        sendClientNotify(src, 'Dispatch', 'Invalid target vehicle for tow.', 'error')
        return
    end
    -- Server-authoritative decision: pick an impound/drop-off location and fee, log the tow
    local impound = impoundLocations[math.random(1, #impoundLocations)]
    local fee = towFee

    -- Attempt to charge the player (best-effort). Record whether charging succeeded.
    local charged = tryChargePlayer(src, fee)

    -- Build a tow ticket id for audit
    local ticketId = tostring(os.time()) .. '-' .. tostring(src)
    local log = {
        ticket = ticketId,
        targetNetId = targetNetId,
        by = src,
        when = os.time(),
        impound = impound,
        fee = fee,
        charged = charged,
    }
    -- Persist to user data for the requesting player (audit trail)
    logTowAction(src, log)

    -- Send a spawn request to the requesting client. The client will spawn the tow assets and report back
    activeTows[ticketId] = { ticket = ticketId, by = src, targetNetId = targetNetId, impound = impound, fee = fee, created = os.time(), charged = charged }
    TriggerClientEvent('bodycam:spawnTowVehicleClient', src, { vehicleNetId = targetNetId, drop = impound, fee = fee, ticket = ticketId })
    sendClientNotify(src, 'Dispatch', 'Tow approved. Please spawn tow truck (server will track).', 'success')
end)


-- Client notifies server that it spawned the tow truck and driver; server will record the network ids
RegisterNetEvent('bodycam:serverTowSpawned')
AddEventHandler('bodycam:serverTowSpawned', function(data)
    local src = source
    if not data or not data.ticket then return end
    local ticket = tostring(data.ticket)
    local info = activeTows[ticket]
    if not info then
        sendClientNotify(src, 'Dispatch', 'Unknown tow ticket: ' .. tostring(ticket), 'error')
        return
    end
    -- Only allow the original requester to register the spawned tow
    if info.by ~= src then
        sendClientNotify(src, 'Dispatch', 'You are not authorized to register this tow.', 'error')
        return
    end

    info.towNetId = data.towNetId
    info.driverNetId = data.driverNetId
    info.spawnedAt = os.time()

    -- Broadcast to all clients so they can show the tow in the world or on map if desired
    TriggerClientEvent('bodycam:serverTowRegistered', -1, { ticket = ticket, towNetId = info.towNetId, driverNetId = info.driverNetId, targetNetId = info.targetNetId, impound = info.impound, by = info.by })
    sendClientNotify(src, 'Dispatch', 'Tow registered on server. Dispatch notified.', 'success')
end)


-- Client informs server the tow operation completed at impound
RegisterNetEvent('bodycam:serverTowComplete')
AddEventHandler('bodycam:serverTowComplete', function(data)
    local src = source
    if not data or not data.ticket then return end
    local ticket = tostring(data.ticket)
    local info = activeTows[ticket]
    if not info then
        sendClientNotify(src, 'Dispatch', 'Unknown tow ticket: ' .. tostring(ticket), 'error')
        return
    end
    -- mark complete and keep a final record
    info.completed = os.time()
    info.completedAt = data.dropCoords or info.impound
    -- Optionally persist a record per-player
    logTowAction(info.by, { ticket = ticket, completed = info.completed, completedAt = info.completedAt })
    sendClientNotify(src, 'Dispatch', 'Tow completed and logged (ticket ' .. tostring(ticket) .. ').', 'success')
end)


-- Force remove a player from duty (revokes ACEs and notifies them)
RegisterNetEvent('bodycam:forceRemoveDuty')
AddEventHandler('bodycam:forceRemoveDuty', function(targetServerId)
    local src = source
    -- Only allow callers with bodycam.leo permission to force-remove
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to remove duty.', 'error')
        return
    end
    local tid = tonumber(targetServerId)
    if not tid or not GetPlayerName(tid) then
        sendClientNotify(src, 'Dispatch', 'Target player not found.', 'error')
        return
    end
    -- Revoke ACEs for target identifier
    local identifier = GetPlayerIdentifier(tostring(tid), 0)
    if type(identifier) == 'string' and identifier ~= '' then
        ExecuteCommand(('remove_principal identifier.%s bodycam.leo'):format(identifier))
        ExecuteCommand(('remove_principal identifier.%s bodycam.testai'):format(identifier))
    end
    -- Disable AI 911 for them and clear duty tracking
    TriggerEvent('bodycam:ai911Disable', tid)
    dutyPlayers[tid] = nil
    dutyInfo[tid] = nil
    -- Instruct the target client to remove weapons and notify
    TriggerClientEvent('bodycam:removeWeaponsClient', tid)
    sendClientNotify(tid, 'Dispatch', 'You have been removed from duty by an administrator.', 'error')
    -- Broadcast blip removal to all clients
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid then
            TriggerClientEvent('bodycam:removeDutyBlip', sid, { serverId = tid })
        end
    end
    sendClientNotify(src, 'Dispatch', 'Player removed from duty.', 'success')
end)


-- Send an on-duty message to a specific player; displayed via lib.notify on recipient
RegisterNetEvent('bodycam:sendOnDutyMessage')
AddEventHandler('bodycam:sendOnDutyMessage', function(targetServerId, message)
    local src = source
    if not IsPlayerAceAllowed(src, 'bodycam.leo') then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to send on-duty messages.', 'error')
        return
    end
    local tid = tonumber(targetServerId)
    if not tid or not GetPlayerName(tid) then
        sendClientNotify(src, 'Dispatch', 'Target player not found.', 'error')
        return
    end
    -- Build sender label (callsign or name)
    local senderLabel = 'Dispatch'
    if userData[src] and userData[src].callsign and userData[src].callsign ~= '' then
        senderLabel = userData[src].callsign
    elseif GetPlayerName(src) then
        senderLabel = GetPlayerName(src)
    end
    -- Send to recipient
    TriggerClientEvent('bodycam:incomingOnDutyMessage', tid, { from = senderLabel, message = tostring(message) })
    sendClientNotify(src, 'Dispatch', 'Message sent to ' .. tostring(GetPlayerName(tid) or tid), 'success')
end)


-- Client announces their duty position to have a blip added for them
RegisterNetEvent('bodycam:announceDuty')
AddEventHandler('bodycam:announceDuty', function(data)
    local src = source
    if not data or not data.coords then return end
    -- Broadcast to all clients to add a duty blip for this player
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid then
            TriggerClientEvent('bodycam:addDutyBlip', sid, { serverId = src, coords = data.coords })
        end
    end
    dutyPlayers[src] = true
end)

-- Client announces they're off-duty; remove blip
RegisterNetEvent('bodycam:announceOffDuty')
AddEventHandler('bodycam:announceOffDuty', function()
    local src = source
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid then
            TriggerClientEvent('bodycam:removeDutyBlip', sid, { serverId = src })
        end
    end
    dutyPlayers[src] = nil
end)

-- Cleanup when a player drops
AddEventHandler('playerDropped', function(reason)
    local src = source
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid then
            TriggerClientEvent('bodycam:removeDutyBlip', sid, { serverId = src })
        end
    end
    dutyPlayers[src] = nil
end)


-- Server handler for test AI command - checks ace permission and triggers a request
RegisterNetEvent('bodycam:testAiRequest')
AddEventHandler('bodycam:testAiRequest', function()
    local src = source
    if not src then return end
    local allowed = false
    -- Check ACE permission
    if IsPlayerAceAllowed(src, 'bodycam.testai') then
        allowed = true
    end
    if allowed then
        -- Ask the client to send an immediate AI 911 report (the existing flow will broadcast to duty players)
        TriggerClientEvent('bodycam:ai911Request', src, {})
        sendClientNotify(src, 'Dispatch', 'AI test requested.', 'success')
    else
        sendClientNotify(src, 'Dispatch', 'You lack permission to use /testai.', 'error')
    end
end)


-- AI 911 call system
local ai911Enabled = {}
local ai911Configs = {
    -- Make AI calls at least 10 minutes apart (600s). Randomize between 10 and 15 minutes.
    minDelay = 600,    -- seconds (minimum between calls: 10 minutes)
    maxDelay = 900,    -- seconds (maximum between calls: 15 minutes)
    -- Categorized messages so calls have an associated service type
    services = {
        police = {
            messages = {
                'Reporting suspicious activity nearby',
                'I need assistance, there is a disturbance',
                'Possible robbery in progress',
                'Shots fired, need immediate help',
                'Report of an assault, please respond',
                'Suspicious person with a weapon'
            },
            weight = 60
        },
        ems = {
            messages = {
                'Person unconscious and not breathing',
                'Serious injury, need medical assistance',
                'Car crash with injuries',
                'Overdose, someone is unresponsive',
                'Severe chest pain, possible heart attack'
            },
            weight = 25
        },
        fire = {
            messages = {
                'House on fire, flames visible',
                'Vehicle on fire on the highway',
                'Smoke coming from a commercial building',
                'Wildfire spreading in the area',
                'Kitchen fire with possible entrapment'
            },
            weight = 15
        }
    }
}

local function pickServiceByWeight()
    local total = 0
    for k, v in pairs(ai911Configs.services) do
        total = total + (v.weight or 0)
    end
    if total <= 0 then return 'police' end
    local r = math.random(1, total)
    local acc = 0
    for k, v in pairs(ai911Configs.services) do
        acc = acc + (v.weight or 0)
        if r <= acc then
            return k
        end
    end
    return 'police'
end

-- Helpers for richer scene metadata
local function randomPlate()
    local letters = ''
    for i=1,3 do letters = letters .. string.char(math.random(65,90)) end
    local nums = tostring(math.random(100,999))
    return letters .. nums
end

local vehicleModels = { 'sultan', 'blista', 'cognoscenti', 'adder', 'police', 'police2', 'emperor', 'jadde' }
local suspectDescriptions = { 'male, approx 30s, wearing dark hoodie', 'female, approx 20s, wearing red jacket', 'male, slender, tattoo on neck', 'group of youths, acting suspicious', 'one male with baseball cap' }

local function generateMetaForService(service, message)
    local meta = {}
    if service == 'police' then
        -- base suspects
        local suspects = 0
        local weapons = false
        local injuries = false
        local vehicle = false
        local plate = nil
        local vehicleModel = nil
        local severity = 'low'

        local m = string.lower(message or '')
        if m:find('shots') or m:find('shots fired') or m:find('gun') then
            weapons = true
            injuries = math.random() < 0.6
            suspects = math.random(1,3)
            severity = 'high'
        elseif m:find('robbery') or m:find('robbery in progress') or m:find('robbery') then
            weapons = math.random() < 0.5
            injuries = math.random() < 0.3
            suspects = math.random(1,4)
            severity = 'high'
        elseif m:find('hit and run') or m:find('car crash') then
            vehicle = true
            injuries = true
            plate = randomPlate()
            vehicleModel = vehicleModels[math.random(1,#vehicleModels)]
            suspects = math.random(1,2)
            severity = 'medium'
        elseif m:find('assault') or m:find('disturbance') then
            injuries = math.random() < 0.5
            suspects = math.random(1,3)
            severity = 'medium'
        elseif m:find('suspicious') or m:find('suspicious activity') then
            suspects = math.random(0,2)
            severity = 'low'
        else
            suspects = math.random(0,2)
            severity = 'low'
        end

        -- random chance of vehicle for certain situations
        if not vehicle and math.random() < 0.2 and suspects > 0 then
            vehicle = true
            plate = randomPlate()
            vehicleModel = vehicleModels[math.random(1,#vehicleModels)]
        end

        meta = {
            severity = severity,
            suspects = suspects,
            suspectDescriptions = (suspects > 0) and (function()
                local t = {}
                for i=1,suspects do table.insert(t, suspectDescriptions[math.random(1,#suspectDescriptions)]) end
                return t
            end)() or {},
            vehicle = vehicle,
            vehicleModel = vehicleModel,
            plate = plate,
            weapons = weapons,
            injuries = injuries,
            notes = ''
        }
    elseif service == 'ems' then
        local injuries = true
        local severity = 'medium'
        if (message and string.find(string.lower(message), 'unconscious')) then
            severity = 'high'
        end
        meta = { severity = severity, injuries = injuries, patients = math.random(1,4), notes = '' }
    elseif service == 'fire' then
        local severity = 'medium'
        if (message and string.find(string.lower(message), 'wildfire')) then severity = 'high' end
        meta = { severity = severity, structure = (math.random() < 0.5) and 'building' or 'vehicle', flames = true, notes = '' }
    else
        meta = {}
    end
    return meta
end


-- ALPR (Automatic License Plate Recognition) system
-- Simple server-side lookup that randomly decides if a plate is valid or not.
local alprConfig = {
    validProbability = 0.8, -- probability a plate is considered valid (0.0 - 1.0)
    cacheTtl = 300 -- seconds to cache previous plate lookups
}

local alprCache = {} -- plate -> { result = {...}, ts = os.time() }

local firstNames = { 'John', 'Jane', 'Carlos', 'Maria', 'Alex', 'Sam', 'Taylor', 'Jordan', 'Chris', 'Pat' }
local lastNames = { 'Smith', 'Johnson', 'Garcia', 'Brown', 'Miller', 'Davis', 'Lopez', 'Wilson', 'Martinez', 'Anderson' }

local function randomOwnerName()
    return firstNames[math.random(1,#firstNames)] .. ' ' .. lastNames[math.random(1,#lastNames)]
end

local function sanitizePlate(p)
    if not p then return nil end
    -- Uppercase and remove non-alphanumeric
    local s = tostring(p):upper()
    s = s:gsub('[^A-Z0-9]', '')
    if s == '' then return nil end
    return s
end

-- Possible invalid reasons
local invalidReasons = { 'stolen', 'suspended registration', 'expired registration', 'wanted by police' }

RegisterNetEvent('bodycam:alprScan')
AddEventHandler('bodycam:alprScan', function(plate)
    local src = source
    local p = sanitizePlate(plate)
    if not p then
        sendClientNotify(src, 'ALPR', 'Invalid plate provided. Usage: /alpr <plate>', 'error')
        return
    end

    -- Check cache
    local now = os.time()
    if alprCache[p] and (now - (alprCache[p].ts or 0) < alprConfig.cacheTtl) then
        local res = alprCache[p].result
        TriggerClientEvent('bodycam:alprResult', src, res)
        return
    end

    -- Decide randomly if plate is valid
    local isValid = math.random() <= (alprConfig.validProbability or 0.8)
    local vehicleModel = vehicleModels[math.random(1,#vehicleModels)]
    local owner = randomOwnerName()
    local result = {
        plate = p,
        valid = isValid,
        vehicleModel = vehicleModel,
        owner = owner,
        reason = nil,
        timestamp = now
    }

    if not isValid then
        result.reason = invalidReasons[math.random(1,#invalidReasons)]
        -- For certain reasons, mark vehicle as stolen for higher severity
        if result.reason == 'stolen' then
            result.severity = 'high'
        else
            result.severity = 'medium'
        end
    else
        result.reason = 'clear'
        result.severity = 'low'
    end

    -- Cache result
    alprCache[p] = { result = result, ts = now }

    -- Send result back to the requesting client only
    TriggerClientEvent('bodycam:alprResult', src, result)
    print(('bodycam: ALPR scan by %s for plate %s -> valid=%s reason=%s'):format(tostring(src), p, tostring(isValid), tostring(result.reason)))
end)

-- Load postals list from postals.json
postalsList = {}
loadPostals = function()
    local resourceName = GetCurrentResourceName()
    local content = LoadResourceFile(resourceName, 'postals.json')
    if content and content ~= '' then
        local ok, parsed = pcall(function() return json.decode(content) end)
        if ok and type(parsed) == 'table' then
            postalsList = parsed
            print(('bodycam: loaded %d postals from postals.json'):format(#postalsList))
            return
        end
    end
    print('bodycam: failed to load postals.json or file empty; postalsList empty')
    postalsList = {}
end

local function randBetween(a,b)
    return math.random(a,b)
end

-- Track active AI calls
local aiCalls = {}
local aiCallCounter = 0

local function createAiCall(data)
    aiCallCounter = aiCallCounter + 1
    local callNumber = aiCallCounter
    local call = {
        callNumber = callNumber,
        playerId = data.playerId,
        coords = data.coords,
        message = data.message,
        street = data.street,
        zone = data.zone,
        postal = data.postal,
        callType = data.callType or 'police',
        meta = data.meta or {},
        timestamp = os.time(),
        attached = {}
    }
    aiCalls[callNumber] = call
    return call
end

-- Global random call generator: picks a random connected player and asks them to report (forceRandom)
Citizen.CreateThread(function()
    while true do
        local delay = randBetween(ai911Configs.minDelay, ai911Configs.maxDelay)
        Citizen.Wait(delay * 1000)
        -- Prefer using pre-defined postals to pick real-looking positions
        local function sendRandomCall(entryCoords, postal)
            -- pick a service and message
            local service = pickServiceByWeight()
            local svc = ai911Configs.services[service]
            local message = 'Unknown call'
            if svc and svc.messages and #svc.messages > 0 then
                message = svc.messages[math.random(1, #svc.messages)]
            end
            local players = GetPlayers()
            if players and #players > 0 then
                local idx = math.random(1, #players)
                local target = tonumber(players[idx])
                if target and GetPlayerName(target) then
                    TriggerClientEvent('bodycam:ai911Request', target, { forceCoords = entryCoords, message = message, forceRandom = true, postal = postal, callType = service })
                end
            end
        end

        if postalsList and #postalsList > 0 then
            local pidx = math.random(1, #postalsList)
            local entry = postalsList[pidx]
            local coords = { x = entry.x, y = entry.y, z = entry.z }
            sendRandomCall(coords, entry.postal)
        else
            -- Fallback to broad random coords if no postals are loaded
            local rx = randBetween(-4000, 5000)
            local ry = randBetween(-5000, 7000)
            local rz = 50.0
            local coords = { x = rx + (math.random() - 0.5) * 200.0, y = ry + (math.random() - 0.5) * 200.0, z = rz }
            sendRandomCall(coords, nil)
        end
    end
end)


-- Attach to a call by number (defined after aiCalls exists)
RegisterNetEvent('bodycam:attachToCall')
AddEventHandler('bodycam:attachToCall', function(callNumber)
    local src = source
    if not callNumber then
        sendClientNotify(src, 'Dispatch', 'No call number provided.', 'error')
        return
    end
    local cn = tonumber(callNumber)
    if not cn or not aiCalls[cn] then
        sendClientNotify(src, 'Dispatch', 'Call number not found.', 'error')
        return
    end
    local call = aiCalls[cn]
    -- add player to attachments if not already attached
    for _, v in ipairs(call.attached) do
        if v == src then
            sendClientNotify(src, 'Dispatch', 'Already attached to call #' .. cn, 'info')
            return
        end
    end
    table.insert(call.attached, src)
    sendClientNotify(src, 'Dispatch', 'Attached to call #' .. cn, 'success')
    -- notify the original reporter if still connected
    if call.playerId and GetPlayerName(call.playerId) then
        sendClientNotify(call.playerId, 'Dispatch', ('Officer attached to your call #%d'):format(cn), 'info')
    end
    -- notify other attached officers
    for _, off in ipairs(call.attached) do
        if off ~= src then
            sendClientNotify(off, 'Dispatch', ('Another officer attached to call #%d'):format(cn), 'info')
        end
    end
    -- Tell the attaching client to draw a route to the call location
    if call.coords and call.coords.x and call.coords.y then
        TriggerClientEvent('bodycam:attachRoute', src, { coords = call.coords, callNumber = cn })
    end
end)


-- Officer arrival notification from client
RegisterNetEvent('bodycam:officerArrived')
AddEventHandler('bodycam:officerArrived', function(callNumber)
    local src = source
    local cn = tonumber(callNumber)
    if not cn or not aiCalls[cn] then
        sendClientNotify(src, 'Dispatch', 'Call not found or invalid.', 'error')
        return
    end
    local call = aiCalls[cn]
    -- Notify all attached officers
    for _, off in ipairs(call.attached) do
        sendClientNotify(off, 'Dispatch', ('Officer has arrived on scene for call #%d - please search the area'):format(cn), 'info')
    end
    -- Notify the original reporter if still connected
    if call.playerId and GetPlayerName(call.playerId) then
        sendClientNotify(call.playerId, 'Dispatch', ('Officer has arrived on scene for your call #%d - they will search the area'):format(cn), 'info')
    end
end)

-- Start AI 911 loop for a player
local function startAI911ForPlayer(playerId)
    if ai911Enabled[playerId] then return end
    ai911Enabled[playerId] = true
    Citizen.CreateThread(function()
        print(('bodycam: AI 911 loop started for player %s'):format(tostring(playerId)))
        while ai911Enabled[playerId] do
            local delay = randBetween(ai911Configs.minDelay, ai911Configs.maxDelay) * 1000
            Citizen.Wait(delay)
            if not ai911Enabled[playerId] then break end
            -- Ask client to report position and pick a message (no forced coords)
            TriggerClientEvent('bodycam:ai911Request', playerId, {})
        end
        print(('bodycam: AI 911 loop ended for player %s'):format(tostring(playerId)))
    end)
end

-- Stop AI 911 for a player
local function stopAI911ForPlayer(playerId)
    ai911Enabled[playerId] = false
end

-- Handlers to enable/disable AI 911 (called previously when LEOPerms were toggled)
RegisterNetEvent('bodycam:ai911Enable')
AddEventHandler('bodycam:ai911Enable', function(playerId)
    startAI911ForPlayer(playerId)
end)

RegisterNetEvent('bodycam:ai911Disable')
AddEventHandler('bodycam:ai911Disable', function(playerId)
    stopAI911ForPlayer(playerId)
end)

-- Client reports the AI 911 details back to the server
RegisterNetEvent('bodycam:ai911Report')
AddEventHandler('bodycam:ai911Report', function(data)
    -- data = { playerId = <id>, coords = {x,y,z}, message = '<text>' }
    if not data or not data.playerId then return end
    local playerId = data.playerId
    local coords = data.coords or {}
    local message = data.message or 'Unknown report'
    print(('bodycam: ai911Report from %s -> %s at %.2f, %.2f, %.2f'):format(tostring(playerId), message, coords.x or 0, coords.y or 0, coords.z or 0))

    -- Create a call entry and fire a generic server event other dispatchers can listen to
    -- Use postal provided by the initiating event (if any), otherwise generate a random postal
    local postal = tostring(data.postal or (10000 + math.random(0, 89999)))
    data.postal = postal
    local service = data.callType or pickServiceByWeight()
    local meta = generateMetaForService(service, message)
    local call = createAiCall({ playerId = playerId, coords = coords, message = message, street = data.street, zone = data.zone, postal = postal, callType = service, meta = meta })
    TriggerEvent('bodycam:ai911Call', call)

    -- Broadcast to duty players only
    for pid, _ in pairs(dutyPlayers) do
        local sid = tonumber(pid)
        if sid and GetPlayerName(sid) then
            TriggerClientEvent('bodycam:ai911Incoming', sid, {
                callNumber = call.callNumber,
                playerId = playerId,
                coords = coords,
                message = message,
                street = data.street,
                zone = data.zone,
                postal = postal,
                callType = service,
                meta = meta,
                timestamp = call.timestamp
            })
        end
    end
end)


-- Handle Code 4 (call cleared) requests from clients
RegisterNetEvent('bodycam:code4')
AddEventHandler('bodycam:code4', function(callNumber)
    local src = source
    if not callNumber then
        sendClientNotify(src, 'Dispatch', 'Usage: /code 4 <callNumber>', 'info')
        return
    end
    local cn = tonumber(callNumber)
    if not cn or not aiCalls[cn] then
        sendClientNotify(src, 'Dispatch', 'Call number not found.', 'error')
        return
    end

    -- Allow if caller has bodycam.leo ACE or is attached to the call
    local allowed = false
    if IsPlayerAceAllowed(src, 'bodycam.leo') then allowed = true end
    for _, v in ipairs(aiCalls[cn].attached or {}) do
        if v == src then allowed = true; break end
    end
    if not allowed then
        sendClientNotify(src, 'Dispatch', 'You do not have permission to clear this call.', 'error')
        return
    end

    -- Remove the call from server state
    aiCalls[cn] = nil

    -- Broadcast cleared notification and remove blips for all players
    local notice = ('Call #%d has been cleared by officers. All units are clear and available.'):format(cn)
    for _, pid in ipairs(GetPlayers()) do
        local sid = tonumber(pid)
        if sid then
            TriggerClientEvent('bodycam:callCleared', sid, { callNumber = cn, message = notice })
            sendClientNotify(sid, 'Dispatch', notice, 'success')
        end
    end
end)
