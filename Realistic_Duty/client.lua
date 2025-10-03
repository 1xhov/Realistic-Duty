local bodycamActive = false

-- Debug: indicate client script loaded and which resource it belongs to
print(('bodycam: client.lua loaded for resource %s'):format(GetCurrentResourceName()))

-- safe lookup for ox_lib (lib) to avoid linter "undefined global" warnings
local _lib = rawget(_G, 'lib') or nil

-- Config: when lib.alertDialog is not available, auto-confirm the dialog
-- Set to true to automatically accept receive-weapons when the lib isn't installed
-- Set to false to keep the previous behavior (notify and do not auto-confirm)
local AUTO_CONFIRM_IF_NO_LIB = true

-- Unified notification helper: prefers NUI police-style notify, falls back to lib.notify or chat
local function BodycamNotify(opts)
    -- opts: { title = '', text = '', type = 'info'|'success'|'error', meta = '', ttl = 6000, badge = 'DISPATCH' }
    opts = opts or {}
    local title = opts.title or 'Notice'
    local text = opts.text or ''
    local ntype = opts.type or 'info'
    local meta = opts.meta
    local ttl = opts.ttl or 6000
    local badge = opts.badge or 'DISPATCH'

    -- Try NUI first
    local ok, _ = pcall(function()
        SendNUIMessage({ type = 'bv-notify', payload = { title = title, text = text, type = ntype, meta = meta, ttl = ttl, badge = badge } })
    end)
    if ok then return end

    -- Then try lib.notify
    if _lib and _lib.notify then
        pcall(function() _lib.notify({ title = title, description = text, type = ntype }) end)
        return
    end

    -- Fallback to chat
    local prefix = '^3[Dispatch]'
    if ntype == 'error' then prefix = '^1[Dispatch]' elseif ntype == 'success' then prefix = '^2[Dispatch]' end
    TriggerEvent('chat:addMessage', { args = { prefix, text or title } })
end

-- Helper to ask the player if they want weapons. Tries lib.alertDialog and falls
-- back to a chat notification + the AUTO_CONFIRM_IF_NO_LIB setting.
local function askReceiveWeapons()
    -- Simplified: do not use lib.alertDialog. Notify user and return configured fallback.
    BodycamNotify({ title = 'Duty', text = ('Receive weapons prompt: auto-confirm %s.'):format(AUTO_CONFIRM_IF_NO_LIB and 'ENABLED' or 'DISABLED'), type = 'info', badge = 'LEO' })
    return AUTO_CONFIRM_IF_NO_LIB
end

-- Command to toggle body cam on and off
RegisterCommand('togglebodycam', function()
    bodycamActive = not bodycamActive
    SendNUIMessage({
        type = 'toggleBodycam',
        active = bodycamActive
    })
end, false)

-- Utility: give weapons to player
local function giveDutyWeapons()
    local ped = PlayerPedId()
    local function give(weapon)
        GiveWeaponToPed(ped, GetHashKey(weapon), 250, false, true)
    end
    give('weapon_combatpistol')
    give('weapon_stungun')
    give('weapon_carbinerifle')
    give('weapon_flashlight')
    give('weapon_flare')
end

local function removeDutyWeapons()
    local ped = PlayerPedId()
    local weapons = { 'weapon_combatpistol', 'weapon_stungun', 'weapon_carbinerifle', 'weapon_flashlight', 'weapon_flare' }
    for _, w in ipairs(weapons) do
        RemoveWeaponFromPed(ped, GetHashKey(w))
    end
end

-- Create ox_target duty zones
local dutyZonesCreated = false
local function createDutyTargets()
    if dutyZonesCreated then
        print('bodycam: duty zones already created, skipping duplicate creation')
        return true
    end
    if not exports or not exports.ox_target then
        print('bodycam: ox_target export not found - duty targets not created (will retry if waiting loop is used)')
        return false
    end

    local addFn = exports.ox_target.addBoxZone or exports.ox_target.AddBoxZone
    if not addFn then
        print('bodycam: ox_target present but addBoxZone export not found')
        return false
    end

    local targets = {
        { name = 'duty_zone_1', x = 1045.7338, y = 2719.9058, z = 39.7250, heading = 97.7383 },
        { name = 'duty_zone_2', x = 1834.0294, y = 3674.2346, z = 34.0799, heading = 201.7589 },
        { name = 'duty_zone_3', x = -448.8622, y = 6004.0845, z = 31.3888, heading = 298.6487 }
    }

    for _, t in ipairs(targets) do
        local zoneData = {
            name = t.name,
            coords = vector3(t.x, t.y, t.z),
            length = 1.2,
            width = 1.2,
            heading = t.heading,
            minZ = t.z - 1.0,
            maxZ = t.z + 1.0,
            options = {
                {
                    name = 'bodycam_clock_on',
                    label = 'Clock On Duty',
                    icon = 'fas fa-user-check',
                    event = 'bodycam:zoneClockOn'
                },
                {
                    name = 'bodycam_clock_off',
                    label = 'Clock Off Duty',
                    icon = 'fas fa-user-slash',
                    event = 'bodycam:zoneClockOff'
                }
            },
            distance = 2.5
        }

        local tried = {}
        local function tryVariant(fn)
            local ok, e = pcall(fn)
            table.insert(tried, { ok = ok, err = e })
            return ok
        end

        local triedOk = false
        local successVariant = nil

        -- Try name+table first (this worked in your logs)
        if tryVariant(function() addFn(zoneData.name, zoneData) end) then
            triedOk = true
            successVariant = 'B (name+table)'
        end

        -- Then try table-only
        if not triedOk then
            if tryVariant(function() addFn(zoneData) end) then
                triedOk = true
                successVariant = 'A (table-only)'
            end
        end

        -- Finally try positional
        if not triedOk then
            if tryVariant(function()
                addFn(zoneData.name, zoneData.coords, zoneData.length, zoneData.width, { heading = zoneData.heading, minZ = zoneData.minZ, maxZ = zoneData.maxZ }, { options = zoneData.options, distance = zoneData.distance })
            end) then
                triedOk = true
                successVariant = 'C (positional)'
            end
        end

        if not triedOk then
            local msgs = {}
            for i, r in ipairs(tried) do
                table.insert(msgs, ('variant %d: ok=%s err=%s'):format(i, tostring(r.ok), tostring(r.err)))
            end
            print('bodycam: addBoxZone failed for ' .. t.name .. ' - ' .. table.concat(msgs, ' | '))
        else
            print(('bodycam: addBoxZone used variant %s for %s'):format(tostring(successVariant), zoneData.name))
            print(('bodycam: created duty target %s at %.4f, %.4f, %.4f'):format(t.name, t.x, t.y, t.z))
        end
    end
    dutyZonesCreated = true
    return true
end

-- Event handler for zone interaction (avoids passing functions into exports)
RegisterNetEvent('bodycam:zoneClockOn')
AddEventHandler('bodycam:zoneClockOn', function()
    bodycamActive = true
    local payload = { type = 'toggleBodycam', active = true }
    print('bodycam: zoneClockOn invoked, sending NUI message: ' .. json.encode(payload))
    SendNUIMessage(payload)

    -- Ask the player using the library if available, otherwise use the
    -- fallback helper which respects AUTO_CONFIRM_IF_NO_LIB.
    local accepted = askReceiveWeapons()

    if accepted then
        TriggerServerEvent('bodycam:giveWeapons')
        -- Grant LEO interaction menu permissions on clock on
        TriggerServerEvent('bodycam:setLEOPerms', true)
        -- Announce duty position so others can see on-duty blip
        local ppos = GetEntityCoords(PlayerPedId())
        TriggerServerEvent('bodycam:announceDuty', { coords = { x = ppos.x, y = ppos.y, z = ppos.z } })
    end
end)

-- Clock Off handler
RegisterNetEvent('bodycam:zoneClockOff')
AddEventHandler('bodycam:zoneClockOff', function()
    bodycamActive = false
    SendNUIMessage({ type = 'toggleBodycam', active = false })
    -- Ask server to remove weapons (server will trigger client event to actually remove)
    TriggerServerEvent('bodycam:removeWeapons')
    -- Revoke LEO interaction menu permissions on clock off
    TriggerServerEvent('bodycam:setLEOPerms', false)
    -- Announce off-duty so blips are removed
    TriggerServerEvent('bodycam:announceOffDuty')
    BodycamNotify({ title = 'Duty', text = 'You have clocked off. Weapons removed.', type = 'success', badge = 'LEO' })
end)

-- Manual runtime test command to create targets and report result
RegisterCommand('createdutytargets', function()
    -- Diagnostic: print exports presence
    if exports then
        print('bodycam: exports table exists')
        if exports.ox_target then
            print('bodycam: exports.ox_target exists')
            if exports.ox_target.addBoxZone then
                print('bodycam: exports.ox_target.addBoxZone available')
            else
                print('bodycam: exports.ox_target.addBoxZone NOT available')
            end
        else
            print('bodycam: exports.ox_target NOT found')
        end
    else
        print('bodycam: exports table is nil')
    end

    local ok = createDutyTargets()
    if ok then
        BodycamNotify({ title = 'Bodycam', text = 'Duty targets created (or already present).', type = 'success' })
    else
        BodycamNotify({ title = 'Bodycam', text = 'Failed to create duty targets. Check F8 console for details.', type = 'error' })
    end
end, false)

-- Developer commands to test NUI directly
RegisterCommand('openbodycam', function()
    print('bodycam: openbodycam called - sending NUI show and setting focus')
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'toggleBodycam', active = true })
end, false)

RegisterCommand('closebodycam', function()
    print('bodycam: closebodycam called - hiding NUI and clearing focus')
    SendNUIMessage({ type = 'toggleBodycam', active = false })
    SetNuiFocus(false, false)
end, false)

-- Show the bodycam for a short test period (7s) then hide it
RegisterCommand('testbodycam', function()
    print('bodycam: testbodycam - showing UI for 7s')
    SetNuiFocus(true, true)
    SendNUIMessage({ type = 'toggleBodycam', active = true })
    Citizen.CreateThread(function()
        Citizen.Wait(7000)
        SendNUIMessage({ type = 'toggleBodycam', active = false })
        SetNuiFocus(false, false)
        print('bodycam: testbodycam - hidden UI after test')
    end)
end, false)

-- Handler called by the server to actually give weapons to the player's ped
RegisterNetEvent('bodycam:receiveWeapons')
AddEventHandler('bodycam:receiveWeapons', function()
    giveDutyWeapons()
    -- Notify the player when weapons are actually received.
    -- Use ox_lib notify if available; otherwise fall back to a chat message.
    -- Note: message text corrected to 'be responsible' for clarity.
    -- Send a chat message notifying the player they've received weapons
    BodycamNotify({ title = 'Duty', text = 'I have given you your duty weapons — be responsible', type = 'info', badge = 'LEO' })
end)

RegisterNetEvent('bodycam:removeWeaponsClient')
AddEventHandler('bodycam:removeWeaponsClient', function()
    removeDutyWeapons()
end)

-- Command to change name
RegisterCommand('changename', function(source, args)
    local name = table.concat(args, " ") -- Concatenate all arguments to handle names with spaces
    TriggerServerEvent('bodycam:setName', name)
end, false)

-- Command to change call sign
RegisterCommand('changecallsign', function(source, args)
    local callsign = table.concat(args, " ") -- Concatenate all arguments
    TriggerServerEvent('bodycam:setCallsign', callsign)
end, false)

-- Command to change department
RegisterCommand('changedepartment', function(source, args)
    local department = table.concat(args, " ") -- Concatenate all arguments
    TriggerServerEvent('bodycam:setDepartment', department)
end, false)

-- Command to show usage instructions
RegisterCommand('helpbodycam', function()
    TriggerEvent('chat:addMessage', {
        args = {
            "Usage of bodycam commands:",
            "/togglebodycam - Toggle bodycam UI on or off",
            "/changename [name] - Change the name displayed on the bodycam",
            "/changecallsign [callsign] - Change the call sign displayed on the bodycam",
            "/changedepartment [department] - Change the department displayed on the bodycam",
            "Examples:",
            "/changename John Doe - Sets the name to 'John Doe'",
            "/changecallsign 1234 - Sets the call sign to '1234'",
            "/changedepartment Police Department - Sets the department to 'Police Department'"
        }
    })
end, false)

-- Test AI command to request an immediate AI 911 report (server checks ACE permission)
RegisterCommand('testai', function()
    TriggerServerEvent('bodycam:testAiRequest')
end, false)

-- Load user data on player join
AddEventHandler('onClientMapStart', function()
    TriggerServerEvent('bodycam:loadUserData')
    -- create duty targets when the client map loads
    createDutyTargets()
end)

-- Also create targets when the resource starts (covers manual restarts)
AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        -- Try to create targets immediately; if ox_target isn't ready yet, start a retry thread
        local ok = createDutyTargets()
        if not ok then
            Citizen.CreateThread(function()
                print('bodycam: waiting for ox_target export...')
                local attempts = 0
                while attempts < 10 do
                    attempts = attempts + 1
                    Citizen.Wait(500) -- wait 0.5s between checks
                    if exports and exports.ox_target then
                        local ok2 = createDutyTargets()
                        if ok2 then
                            print('bodycam: duty targets created after waiting')
                            break
                        end
                    end
                end
                if attempts >= 10 then
                    print('bodycam: failed to create duty targets - ox_target not available after retries')
                end
            end)
        end
    end
end)

RegisterNetEvent('bodycam:updateInfo')
AddEventHandler('bodycam:updateInfo', function(data)
    SendNUIMessage({
        type = 'updateInfo',
        name = data.name,
        callsign = data.callsign,
        department = data.department
    })
end)

-- dutyBlips maps serverId -> table { blip = blipHandle, attached = bool, watcher = true/false }
local dutyBlips = {}

local function createEntityBlipForServerId(sid)
    local serverIdNum = tonumber(sid)
    if not serverIdNum then return nil end
    local pid = GetPlayerFromServerId(serverIdNum)
    if not pid or pid == -1 then return nil end
    local ped = GetPlayerPed(pid)
    if not ped or ped == 0 then return nil end
    if not DoesEntityExist(ped) then return nil end
    local blip = AddBlipForEntity(ped)
    if DoesBlipExist(blip) then
        SetBlipSprite(blip, 56)
        SetBlipColour(blip, 3)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Officer On Duty - #' .. tostring(sid))
        EndTextCommandSetBlipName(blip)
        return blip
    end
    return nil
end

RegisterNetEvent('bodycam:addDutyBlip')
AddEventHandler('bodycam:addDutyBlip', function(data)
    if not data or not data.serverId or not data.coords then return end
    local sid = tostring(data.serverId)
    -- Remove existing blip if present
    if dutyBlips[sid] and dutyBlips[sid].blip and DoesBlipExist(dutyBlips[sid].blip) then
        RemoveBlip(dutyBlips[sid].blip)
        dutyBlips[sid] = nil
    end

    -- Try to attach blip to the player's entity (this will automatically follow movement)
    local entBlip = createEntityBlipForServerId(sid)
    if entBlip then
        dutyBlips[sid] = { blip = entBlip, attached = true }
        return
    end

    -- Fallback: create a coord blip and start a watcher to convert to entity blip when available
    local c = data.coords
    local blip = AddBlipForCoord(c.x, c.y, c.z or 0.0)
    if DoesBlipExist(blip) then
        SetBlipSprite(blip, 56)
        SetBlipColour(blip, 3)
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Officer On Duty - #' .. tostring(sid))
        EndTextCommandSetBlipName(blip)
        dutyBlips[sid] = { blip = blip, attached = false }

        -- Start a watcher thread to attempt to convert to an entity-attached blip
        Citizen.CreateThread(function()
            local attempts = 0
            while dutyBlips[sid] and dutyBlips[sid].attached == false and attempts < 60 do
                Citizen.Wait(1000)
                attempts = attempts + 1
                local newEntBlip = createEntityBlipForServerId(sid)
                if newEntBlip then
                    -- Remove coord blip and replace
                    if dutyBlips[sid] and dutyBlips[sid].blip and DoesBlipExist(dutyBlips[sid].blip) then
                        RemoveBlip(dutyBlips[sid].blip)
                    end
                    dutyBlips[sid] = { blip = newEntBlip, attached = true }
                    break
                end
            end
        end)
    end
end)

RegisterNetEvent('bodycam:removeDutyBlip')
AddEventHandler('bodycam:removeDutyBlip', function(data)
    if not data or not data.serverId then return end
    local sid = tostring(data.serverId)
    if dutyBlips[sid] then
        local entry = dutyBlips[sid]
        if entry.blip and DoesBlipExist(entry.blip) then
            RemoveBlip(entry.blip)
        end
        dutyBlips[sid] = nil
    end
end)


-- Respond to AI 911 request from server: send back coords + random message
RegisterNetEvent('bodycam:ai911Request')
AddEventHandler('bodycam:ai911Request', function(data)
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local args = data
    -- If server passed forced coords/message (for randomized global calls), use them
    if args and type(args) == 'table' and args.forceCoords then
        local fc = args.forceCoords
        -- Try to get ground Z for accuracy
        local groundZ = fc.z or 0.0
        local found, gz = GetGroundZFor_3dCoord(fc.x, fc.y, 500.0, false)
        if found then groundZ = gz end
        pos = vector3(fc.x, fc.y, groundZ)
    end

    local messages = {
        'Reporting suspicious activity nearby',
        'I need assistance, there is a disturbance',
        'Possible robbery in progress',
        'Theres a person on a bike on the highway',
        'Hit and run, vehicle fleeing the scene',
        'Could the police come to my house I think that I hear something moving outside',
        'I see a suspicious person',
        'Theres a vehicle that has been around my property',
        'I need the police the baby daddy is trying to break in',
        'There is a vehicle that is driving erratically',
        'There is a person that is following me',
        'I think someone is trying to break into my car',
        'There is a person that is yelling and screaming',
        'My neighbor is being really loud and disruptive',
        'My neighbor is having a party and it is really loud',
        'I want to report suspicious activity in my neighborhood',
        'Theres a man with a gun',
        'I see a vehicle driving without headlights on at night',
        'A person on a bike was hit by a vehicle and they are hurt',
        'I need Fire and EMS',
        'Theres a boat that is stranded in the water',
        'There is a person that is passed out in the street',
        'There is a tree down on the road',
        'I need a supervisor at my location',
        'I am being staked out by a suspicious person',
        'I am being harassed by my ex girlfriend',
        'There is a person that is breaking into cars',
        'There is a person that is breaking into houses',
        'Theres a car accident, people are hurt',
        'I need to get to the hospital',
        'Ems is needed because theres a man down on the sidewalk',
        'Theres a person that is threatening me with a weapon',

    }
    local idx = math.random(1, #messages)
    local msg = messages[idx]
    -- If server provided a message override, use it
    if args and type(args) == 'table' and args.message then
        msg = args.message
    end

    -- Resolve street name and zone (postal-like) for more useful dispatch info
    local streetHash, crossingHash = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
    local streetName = ''
    if streetHash and streetHash ~= 0 then
        streetName = GetStreetNameFromHashKey(streetHash)
    end
    local zoneName = ''
    local zone = GetNameOfZone(pos.x, pos.y, pos.z)
    if zone and zone ~= '' then
        zoneName = GetLabelText(zone)
    end

    local payload = {
        playerId = GetPlayerServerId(PlayerId()),
        coords = { x = pos.x, y = pos.y, z = pos.z },
        message = msg,
        street = streetName,
        zone = zoneName,
        callType = '911'
    }

    -- Use server-provided postal if available (picked from postals.json); otherwise request from NUI
    if args and type(args) == 'table' and args.postal then
        payload.postal = tostring(args.postal)
        TriggerServerEvent('bodycam:ai911Report', payload)
        return
    end

    -- Request postal from NUI (postal.js) so the postal corresponds to the call coords
    local requestId = tostring(math.random(100000,999999))
    local postal = nil
    local received = false

    -- Create a temporary listener for the postal result
    local function onPostalResult(d)
        if not d then return end
        if tostring(d.requestId) == requestId then
            postal = d.postal
            received = true
        end
    end

    -- Register a one-time NUI callback handler (if available)
    if RegisterNUICallback then
        RegisterNUICallback('postalResult', function(d, cb)
            onPostalResult(d)
            if cb then cb('ok') end
        end)
    else
        print('bodycam: RegisterNUICallback not available, skipping postal request')
    end

    -- Send the compute request to NUI
    SendNUIMessage({ type = 'computePostal', coords = payload.coords, requestId = requestId })

    -- Wait up to 2000ms for postal response
    local waitMs = 0
    while not received and waitMs < 2000 do
        Citizen.Wait(100)
        waitMs = waitMs + 100
    end
    if received and postal then
        payload.postal = postal
    else
        -- fallback deterministic postal
        payload.postal = tostring(10000 + math.random(0, 89999))
    end

    TriggerServerEvent('bodycam:ai911Report', payload)
end)


-- Incoming AI 911 calls (for duty players)
RegisterNetEvent('bodycam:ai911Incoming')
AddEventHandler('bodycam:ai911Incoming', function(call)
    if not call then return end
    local location = ''
    if call.street and call.street ~= '' then
        location = call.street
        if call.zone and call.zone ~= '' then
            location = location .. ', ' .. call.zone
        end
    elseif call.zone and call.zone ~= '' then
        location = call.zone
    else
        location = string.format('%.1f, %.1f', call.coords.x or 0, call.coords.y or 0)
    end

    local callNumPart = call.callNumber and ('#' .. tostring(call.callNumber) .. ' ') or ''
    local postalPart = call.postal and (' [' .. tostring(call.postal) .. ']') or ''
    local callType = tostring(call.callType or 'police')
    local svcLabel = ''
    local chatPrefix = '^1[Dispatch]'
    if callType == 'ems' then
        svcLabel = 'EMS'
        chatPrefix = '^3[EMS]'
    elseif callType == 'fire' then
        svcLabel = 'FIRE'
        chatPrefix = '^6[FIRE]'
    else
        svcLabel = 'POLICE'
        chatPrefix = '^2[POLICE]'
    end
    local msg = ("%s CALL %s: %s — %s%s"):format(svcLabel, callNumPart, call.message or 'Unknown', location, postalPart)
    BodycamNotify({ title = svcLabel .. ' CALL', text = msg, type = 'info', meta = (call.postal and ('Postal: ' .. tostring(call.postal)) or nil) })

    -- If meta present, print a concise summary for responders
    if call.meta then
        local meta = call.meta
        local parts = {}
        if meta.severity then table.insert(parts, ('Severity: %s'):format(meta.severity)) end
        if meta.suspects and meta.suspects > 0 then table.insert(parts, ('Suspects: %d'):format(meta.suspects)) end
        if meta.weapons then table.insert(parts, 'Weapons reported') end
        if meta.injuries then table.insert(parts, 'Possible injuries') end
        if meta.vehicle then table.insert(parts, ('Vehicle: %s'):format(meta.vehicleModel or 'unknown')) end
        if meta.plate then table.insert(parts, ('Plate: %s'):format(meta.plate)) end
        if #parts > 0 then
            BodycamNotify({ title = svcLabel .. ' CALL', text = table.concat(parts, ' | '), type = 'info' })
        end
    end

    -- Create a temporary blip for 30 seconds
    if call.coords and call.coords.x and call.coords.y then
        local blip = AddBlipForCoord(call.coords.x, call.coords.y, call.coords.z or 0)
        SetBlipSprite(blip, 437) -- emergency style
        local colour = 1 -- default red
        if callType == 'ems' then
            colour = 2 -- green
        elseif callType == 'fire' then
            colour = 17 -- orange/red-ish
        else
            colour = 3 -- blue for police
        end
        SetBlipColour(blip, colour)
        SetBlipScale(blip, 0.8)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString((svcLabel..' CALL '..(call.callNumber and ('#'..tostring(call.callNumber)) or '')))
        EndTextCommandSetBlipName(blip)
        -- Track this blip so it can be removed by a /code 4 clearance
        if call.callNumber then
            aiCallBlips[call.callNumber] = blip
        end
        Citizen.CreateThread(function()
            Citizen.Wait(30000)
            if DoesBlipExist(blip) then RemoveBlip(blip) end
            if call.callNumber and aiCallBlips and aiCallBlips[call.callNumber] == blip then aiCallBlips[call.callNumber] = nil end
        end)
    end
end)


-- Track temporary blips created for AI calls so they can be removed on code4
aiCallBlips = aiCallBlips or {}

-- Call cleared handler: remove blip and show notice
RegisterNetEvent('bodycam:callCleared')
AddEventHandler('bodycam:callCleared', function(data)
    if not data or not data.callNumber then return end
    local cn = tonumber(data.callNumber)
    if cn and aiCallBlips[cn] then
        local b = aiCallBlips[cn]
        if DoesBlipExist(b) then RemoveBlip(b) end
        aiCallBlips[cn] = nil
    end
    if data.message then
    BodycamNotify({ title = 'Dispatch', text = tostring(data.message), type = 'info' })
    end
end)


-- Draw a route and set waypoint when attaching to a call
RegisterNetEvent('bodycam:attachRoute')
AddEventHandler('bodycam:attachRoute', function(data)
    if not data or not data.coords then return end
    local c = data.coords
    local callNumber = data.callNumber or ''
    -- Set GPS waypoint (this should show on the map)
    SetNewWaypoint(c.x, c.y)

    -- Debug / user feedback
    print(('bodycam: attachRoute received for call %s at %.2f, %.2f, %.2f'):format(tostring(callNumber), tonumber(c.x), tonumber(c.y), tonumber(c.z or 0.0)))
    BodycamNotify({ title = 'Route', text = ('Route set to 911 #%s (%.1f, %.1f)'):format(tostring(callNumber), tonumber(c.x), tonumber(c.y)), type = 'info' })

    -- Create a visible route blip
    local blip = AddBlipForCoord(c.x, c.y, c.z or 0.0)
    if DoesBlipExist(blip) then
        SetBlipSprite(blip, 1)
        SetBlipColour(blip, 3)
        SetBlipScale(blip, 1.0)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Route to 911 #' .. tostring(callNumber))
        EndTextCommandSetBlipName(blip)
        SetBlipAsMissionCreatorBlip(blip, true)
        SetBlipDisplay(blip, 4)
        SetBlipAsShortRange(blip, false)
        SetBlipHighDetail(blip, true)
        SetBlipPriority(blip, 10)

        -- Create a route to the blip
        SetBlipRoute(blip, true)
        SetBlipRouteColour(blip, 5)
        -- Track route blip so it can be cleared by code4
        if callNumber and callNumber ~= '' then
            aiCallBlips[callNumber] = blip
        end
    else
        print('bodycam: failed to create blip for attachRoute')
    end

    -- Auto-remove after 5 minutes
    Citizen.CreateThread(function()
        local ttl = 5 * 60 * 1000
        Citizen.Wait(ttl)
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        if callNumber and aiCallBlips and aiCallBlips[callNumber] == blip then aiCallBlips[callNumber] = nil end
        -- Clear waypoint
        SetNewWaypoint(0, 0)
    end)
    
    -- Notify player and start arrival monitor
    BodycamNotify({ title = 'Route', text = 'Route set to 911 #' .. tostring(callNumber), type = 'info' })

    Citizen.CreateThread(function()
        local arrived = false
        while not arrived do
            Citizen.Wait(1000)
            local ped = PlayerPedId()
            if DoesEntityExist(ped) then
                local ppos = GetEntityCoords(ped)
                local dist = #(ppos - vector3(c.x, c.y, c.z or 0.0))
                -- arrival threshold (meters)
                if dist <= 7.5 then
                    arrived = true
                    -- Notify server that this officer has arrived
                    TriggerServerEvent('bodycam:officerArrived', callNumber)
                    -- Inform the player locally
                    BodycamNotify({ title = 'Dispatch', text = 'You have arrived on scene for 911 #' .. tostring(callNumber) .. '. Please search the area.', type = 'success' })
                end
            end
        end
    end)
end)


-- Command to attach to a call by number
RegisterCommand('attach911', function(source, args)
    local callNumber = args[1]
    if not callNumber then
    BodycamNotify({ title = 'Bodycam', text = 'Usage: /attach911 <callNumber>', type = 'info' })
        return
    end
    TriggerServerEvent('bodycam:attachToCall', callNumber)
end, false)


-- Command to send Code 4 clearance: /code 4 <callNumber>
RegisterCommand('code', function(_, args)
    if not args or #args == 0 then
    BodycamNotify({ title = 'Bodycam', text = 'Usage: /code 4 <callNumber>', type = 'info' })
        return
    end
    local code = tostring(args[1])
    if code ~= '4' then
    BodycamNotify({ title = 'Bodycam', text = 'Unsupported code. Only Code 4 is supported via /code 4 <callNumber>', type = 'info' })
        return
    end
    local callNumber = args[2]
    if not callNumber then
    BodycamNotify({ title = 'Bodycam', text = 'Usage: /code 4 <callNumber>', type = 'info' })
        return
    end
    TriggerServerEvent('bodycam:code4', callNumber)
end, false)

-- Shortcut command /code4 <callNumber>
RegisterCommand('code4', function(_, args)
    local callNumber = args[1]
    if not callNumber then
    BodycamNotify({ title = 'Bodycam', text = 'Usage: /code4 <callNumber>', type = 'info' })
        return
    end
    TriggerServerEvent('bodycam:code4', callNumber)
end, false)


-- ALPR client command: /alpr <plate>
RegisterCommand('alpr', function(_, args)
    local plate = args and args[1]
    if not plate or plate == '' then
    BodycamNotify({ title = 'ALPR', text = 'Usage: /alpr <plate>', type = 'info' })
        return
    end
    TriggerServerEvent('bodycam:alprScan', plate)
    BodycamNotify({ title = 'ALPR', text = ('Scanning plate %s...'):format(tostring(plate)), type = 'info' })
end, false)


-- Receive ALPR result from server
RegisterNetEvent('bodycam:alprResult')
AddEventHandler('bodycam:alprResult', function(res)
    if not res or not res.plate then return end
    local plate = tostring(res.plate)
    local valid = res.valid and true or false
    local owner = res.owner or 'Unknown'
    local model = res.vehicleModel or 'unknown'
    local reason = res.reason or 'N/A'
    local severity = res.severity or 'low'

    if _lib and _lib.notify then
        if valid then
            pcall(function() _lib.notify({ title = ('ALPR: %s (Clear)'):format(plate), description = ('Owner: %s | Vehicle: %s'):format(owner, model), type = 'success' }) end)
        else
            pcall(function() _lib.notify({ title = ('ALPR: %s (Match)'):format(plate), description = ('Reason: %s | Owner: %s | Vehicle: %s'):format(reason, owner, model), type = 'error' }) end)
        end
    else
        if valid then
            BodycamNotify({ title = ('ALPR: %s (Clear)'):format(plate), text = ('Owner: %s | Vehicle: %s'):format(owner, model), type = 'success' })
        else
            BodycamNotify({ title = ('ALPR: %s (Match)'):format(plate), text = ('%s | Owner: %s | Vehicle: %s'):format(reason, owner, model), type = 'error' })
        end
    end
end)


-- Spawn a cop ped that walks to player and gives weapons (called when clocking on)
local function spawnCopGivesWeapons()
    local model = GetHashKey('s_m_y_cop_01')
    RequestModel(model)
    local start = GetEntityCoords(PlayerPedId())
    local spawnPos = vector3(start.x + 2.0, start.y + 2.0, start.z)
    local tries = 0
    while not HasModelLoaded(model) and tries < 50 do
        Citizen.Wait(50)
        tries = tries + 1
    end
    if not HasModelLoaded(model) then return end
    local ped = CreatePed(4, model, spawnPos.x, spawnPos.y, spawnPos.z, 0.0, true, false)
    if not DoesEntityExist(ped) then return end
    SetEntityAsMissionEntity(ped, true, true)
    -- Make the ped walk to the player
    local playerPed = PlayerPedId()
    TaskGoStraightToCoord(ped, start.x, start.y, start.z, 1.0, -1, 0.0, 0.0)
    Citizen.CreateThread(function()
        local arrived = false
        local attempts = 0
        while attempts < 200 do
            Citizen.Wait(100)
            local ppos = GetEntityCoords(ped)
            if #(ppos - start) < 1.5 then
                arrived = true
                break
            end
            attempts = attempts + 1
        end
        if arrived then
            -- play a short animation (hands over)
            -- Tell server to give weapons (trusted server flow)
            TriggerServerEvent('bodycam:giveWeapons')
        end
        -- cleanup
        Citizen.Wait(2000)
        if DoesEntityExist(ped) then
            SetEntityAsMissionEntity(ped, false, true)
            DeletePed(ped)
        end
    end)
end

-- Hook into clock on flow: when zoneClockOn runs and we got accepted, spawn cop
AddEventHandler('bodycam:zoneClockOn', function()
    -- existing handler already handles weapons; spawn a cop to hand them physically
    spawnCopGivesWeapons()
end)


-- Duty blip management (client-side): add/remove blips for on-duty officers
local dutyBlips = {}

RegisterNetEvent('bodycam:addDutyBlip')
AddEventHandler('bodycam:addDutyBlip', function(data)
    if not data or not data.serverId or not data.coords then return end
    local sid = tostring(data.serverId)
    -- Remove existing blip if present
    if dutyBlips[sid] and DoesBlipExist(dutyBlips[sid]) then
        RemoveBlip(dutyBlips[sid])
        dutyBlips[sid] = nil
    end
    local c = data.coords
    local blip = AddBlipForCoord(c.x, c.y, c.z or 0.0)
    if DoesBlipExist(blip) then
        SetBlipSprite(blip, 56) -- police style
        SetBlipColour(blip, 3) -- blue
        SetBlipScale(blip, 0.9)
        SetBlipAsShortRange(blip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Officer On Duty - #' .. tostring(data.serverId))
        EndTextCommandSetBlipName(blip)
        dutyBlips[sid] = blip
    end
end)


-- Human-readable time formatter (seconds -> H:MM:SS or M:SS)
local function formatElapsed(sec)
    if not sec or sec < 0 then return '0s' end
    local hours = math.floor(sec / 3600)
    local minutes = math.floor((sec % 3600) / 60)
    local seconds = sec % 60
    if hours > 0 then
        return string.format('%dh %02dm %02ds', hours, minutes, seconds)
    elseif minutes > 0 then
        return string.format('%dm %02ds', minutes, seconds)
    else
        return string.format('%ds', seconds)
    end
end


-- Receive server-sent on-duty list and open menu or fallback to chat
RegisterNetEvent('bodycam:receiveOnDutyList')
AddEventHandler('bodycam:receiveOnDutyList', function(list)
    if not list then
        BodycamNotify({ title = 'Bodycam', text = 'No on-duty units reported.', type = 'info' })
        return
    end

    -- Build menu entries
    local entries = {}
    for _, v in ipairs(list) do
        local title = ''
        if v.callsign and v.callsign ~= '' then
            title = ('%s (%s)'):format(tostring(v.name or ('Player '..tostring(v.serverId))), tostring(v.callsign))
        else
            title = tostring(v.name or ('Player '..tostring(v.serverId)))
        end
        local subtitle = ('On duty for %s'):format(formatElapsed(tonumber(v.elapsed) or 0))
        table.insert(entries, { title = title, description = subtitle, serverId = v.serverId })
    end

    -- If lib.inputDialog is available, present dropdowns and a message field
    if _lib and _lib.inputDialog then
        -- Prepare choices for the first dropdown
        local unitChoices = {}
        for i, e in ipairs(entries) do
            table.insert(unitChoices, { label = e.title, value = tostring(e.serverId) })
        end
        if #unitChoices == 0 then
            BodycamNotify({ title = 'Bodycam', text = 'No on-duty units available.', type = 'info' })
            return
        end

        -- Action choices
        local actionChoices = {
            { label = 'Remove from Duty', value = 'remove' },
            { label = 'Send Message', value = 'message' }
        }

        -- Build input dialog structure expected by lib.inputDialog
        local dlg = {
            title = 'On-Duty Management',
            align = 'top-right',
            elements = {
                { label = 'Unit', name = 'unit', type = 'select', options = unitChoices },
                { label = 'Action', name = 'action', type = 'select', options = actionChoices },
                { label = 'Message (if Send Message selected)', name = 'message', type = 'input', value = '' }
            }
        }

        -- Show the dialog and handle response
        pcall(function()
            _lib.inputDialog(dlg, function(submitted, data)
                if not submitted or not data then return end
                local target = data.unit
                local action = data.action
                local msg = data.message or ''
                if action == 'remove' then
                    TriggerServerEvent('bodycam:forceRemoveDuty', target)
                elseif action == 'message' then
                    TriggerServerEvent('bodycam:sendOnDutyMessage', target, msg)
                end
            end)
        end)
    else
        -- Fallback: show as notifications
        BodycamNotify({ title = 'Bodycam', text = 'On-Duty Units:', type = 'info' })
        for _, e in ipairs(entries) do
            BodycamNotify({ title = e.title, text = e.description, type = 'info' })
        end
        BodycamNotify({ title = 'Bodycam', text = 'Install a lib supporting inputDialog to get interactive controls.', type = 'info' })
    end
end)


-- Incoming on-duty message: show via lib.notify if available, otherwise chat
RegisterNetEvent('bodycam:incomingOnDutyMessage')
AddEventHandler('bodycam:incomingOnDutyMessage', function(data)
    if not data or not data.message then return end
    local from = data.from or 'Dispatch'
    local msg = tostring(data.message)
    BodycamNotify({ title = ('Message from %s'):format(from), text = msg, type = 'info' })
end)


-- /onduty command: request list from server
RegisterCommand('onduty', function()
    TriggerServerEvent('bodycam:requestOnDuty')
end, false)

RegisterNetEvent('bodycam:removeDutyBlip')
AddEventHandler('bodycam:removeDutyBlip', function(data)
    if not data or not data.serverId then return end
    local sid = tostring(data.serverId)
    if dutyBlips[sid] and DoesBlipExist(dutyBlips[sid]) then
        RemoveBlip(dutyBlips[sid])
    end
    dutyBlips[sid] = nil
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for k, b in pairs(dutyBlips) do
        if DoesBlipExist(b) then
            RemoveBlip(b)
        end
        dutyBlips[k] = nil
    end
end)
