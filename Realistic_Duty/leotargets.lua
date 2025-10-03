-- leotargets.lua
-- Adds ox_target interactions to vehicle trunks: Get Armor, Push Vehicle

local hasOxTarget = false
if exports and exports.ox_target then
    hasOxTarget = true
end

-- Flexible ox_target add helper that tries multiple API shapes
local function tryAddEntityTarget(entity, opts)
    if not hasOxTarget then return false end
    local attempts = {
        function() return exports.ox_target:addEntity({ entity = entity, options = opts }) end,
        function() return exports.ox_target:addEntity(entity, opts) end,
        function() return exports.ox_target:addEntity(opts) end,
        function() return exports.ox_target:addEntity({ options = opts }) end,
    }
    for _, fn in ipairs(attempts) do
        local ok, _ = pcall(fn)
        if ok then return true end
    end
    return false
end

local function safeNotify(text)
    -- Use BodycamNotify if available, otherwise fallback to simple chat message
    if type(_G['BodycamNotify']) == 'function' then
        local fn = _G['BodycamNotify']
        fn({ type = 'inform', title = 'Bodycam', text = text })
    else
        TriggerEvent('chat:addMessage', { args = { '^1Bodycam', text } })
    end
end

-- carried medstation entity (if any)
local carriedMedstation = nil

local function attachMedstationToPlayer(obj)
    if not DoesEntityExist(obj) then return end
    local ped = PlayerPedId()
    local bone = GetPedBoneIndex(ped, 57005) -- right hand
    -- offsets tuned for prop_medstation_03; may be adjusted per-server
    AttachEntityToEntity(obj, ped, bone, 0.08, 0.02, 0.0, 0.0, 0.0, 180.0, false, false, false, false, 2, true)
    carriedMedstation = obj
    safeNotify('You grabbed the medstation. Use the interaction again to drop it.')
end

local function removeCarriedMedstation()
    if not carriedMedstation then return end
    if DoesEntityExist(carriedMedstation) then
        DetachEntity(carriedMedstation, true, true)
        SetEntityAsMissionEntity(carriedMedstation, true, true)
        DeleteObject(carriedMedstation)
    end
    carriedMedstation = nil
    safeNotify('You dropped the medstation.')
end

-- Helpers
local function getClosestVehicleBoneOffset(vehicle)
    -- Attempt to find trunk coords using a few common bones or offsets
    -- Fallback to rear offset from entity origin
    local boneNames = { 'boot', 'boot_l', 'boot_r', 'bootdoor', 'door_dside_r', 'door_dside_r_f' }
    for _, bone in ipairs(boneNames) do
        local boneIndex = GetEntityBoneIndexByName(vehicle, bone)
        if boneIndex and boneIndex ~= -1 then
            local bx, by, bz = table.unpack(GetWorldPositionOfEntityBone(vehicle, boneIndex))
            return vector3(bx, by, bz)
        end
    end
    -- fallback rear offset
    local offset = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -3.0, 0.0)
    return offset
end

local function isPlayerNearCoords(coords, maxDist)
    local px, py, pz = table.unpack(GetEntityCoords(PlayerPedId()))
    return #(vector3(px, py, pz) - coords) <= (maxDist or 2.5)
end

-- Armor giving
local function givePlayerArmor(amount)
    local ped = PlayerPedId()
    amount = amount or 100
    SetPedArmour(ped, amount)
    safeNotify('You have received armor.')
end

-- Vehicle pushing
local pushing = false
local function pushVehicle(vehicle)
    if pushing then return end
    pushing = true

    local ped = PlayerPedId()
    -- Play a push animation
    local dict = 'missfinale_c2ig_11'
    local anim = 'pushcar_offcliff_m' -- short push-like animation, fallback to shove
    RequestAnimDict(dict)
    local timeout = GetGameTimer() + 1000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < timeout do
        Citizen.Wait(0)
    end

    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, anim, 8.0, -8.0, 3000, 0, 0, false, false, false)
    end

    -- Apply a small forward force from the rear of the vehicle
    local vx, vy, vz = table.unpack(GetEntityForwardVector(vehicle))
    local pushPower = 2.0
    local fx, fy, fz = vx * pushPower, vy * pushPower, 0.0

    -- Temporarily unfreeze vehicle and set its velocity/force
    SetVehicleOnGroundProperly(vehicle)
    local cx, cy, cz = table.unpack(GetEntityCoords(vehicle))
    -- Make sure player is behind the vehicle and facing it
    local heading = GetEntityHeading(ped)

    -- Simple loop to nudge the vehicle forward while animation plays
    local start = GetGameTimer()
    while GetGameTimer() - start < 2000 do
        -- Apply small velocity
        local currentVel = GetEntityVelocity(vehicle)
        SetEntityVelocity(vehicle, currentVel.x + fx * 0.01, currentVel.y + fy * 0.01, currentVel.z + fz * 0.01)
        Citizen.Wait(50)
    end

    pushing = false
    safeNotify('You pushed the vehicle.')
end

-- ox_target registration for vehicle entity trunk
local function registerEntityTrunkTarget()
    if not hasOxTarget then return end

    -- Define options for entity-targeting vehicles
    local options = {
        {
            name = 'bodycam_get_armor',
            event = 'bodycam:requestGetArmor',
            icon = 'fa-solid fa-shield-alt',
            label = 'Get Armor',
            canInteract = function(entity, distance, data)
                if not DoesEntityExist(entity) then return false end
                if not IsEntityAVehicle(entity) then return false end
                local trunkCoords = getClosestVehicleBoneOffset(entity)
                if not trunkCoords then return false end
                return isPlayerNearCoords(trunkCoords, 2.5)
            end
        },
        {
            name = 'bodycam_push_vehicle',
            event = 'bodycam:requestPushVehicle',
            icon = 'fa-solid fa-car-bump',
            label = 'Push Vehicle',
            canInteract = function(entity, distance, data)
                if not DoesEntityExist(entity) then return false end
                if not IsEntityAVehicle(entity) then return false end
                local trunkCoords = getClosestVehicleBoneOffset(entity)
                if not trunkCoords then return false end
                return isPlayerNearCoords(trunkCoords, 2.5)
            end
        }
        ,
        {
            name = 'bodycam_grab_medstation',
            event = 'bodycam:requestGrabMedstation',
            icon = 'fa-solid fa-box-medical',
            label = 'Grab Medstation',
            canInteract = function(entity, distance, data)
                if not DoesEntityExist(entity) then return false end
                if not IsEntityAVehicle(entity) then return false end
                local trunkCoords = getClosestVehicleBoneOffset(entity)
                if not trunkCoords then return false end
                return isPlayerNearCoords(trunkCoords, 2.5)
            end
        }
        ,
        {
            name = 'bodycam_tow_vehicle',
            event = 'bodycam:requestTowVehicle',
            icon = 'fa-solid fa-truck-field',
            label = 'Tow Vehicle',
            canInteract = function(entity, distance, data)
                if not DoesEntityExist(entity) then return false end
                if not IsEntityAVehicle(entity) then return false end
                local trunkCoords = getClosestVehicleBoneOffset(entity)
                if not trunkCoords then return false end
                return isPlayerNearCoords(trunkCoords, 2.5)
            end
        }
    }

    -- Try multiple possible ox_target API signatures
    local function tryAddEntityTarget(entity, opts)
        local attempts = {
            function() return exports.ox_target:addEntity({ entity = entity, options = opts }) end,
            function() return exports.ox_target:addEntity(entity, opts) end,
            function() return exports.ox_target:addEntity(opts) end,
            function() return exports.ox_target:addEntity({ options = opts }) end,
        }
        for _, fn in ipairs(attempts) do
            local ok, _ = pcall(fn)
            if ok then return true end
        end
        return false
    end

    tryAddEntityTarget(nil, options)
end

-- Fallback: create a recurring poll to add a zone when near vehicle trunk if ox_target supports addBoxZone only
local function registerZoneFallback()
    if not hasOxTarget then return end

    -- If the resource exposes addBoxZone (server-side older versions), try to add an entity based target per nearby vehicle
    -- We'll poll nearby vehicles and create per-vehicle zones using addBoxZone with a unique id
    Citizen.CreateThread(function()
        local knownZones = {}
        while true do
            local ped = PlayerPedId()
            local pcoords = GetEntityCoords(ped)
            local vehicles = GetGamePool('CVehicle')
            for _, vehicle in ipairs(vehicles) do
                if DoesEntityExist(vehicle) then
                    local trunkCoords = getClosestVehicleBoneOffset(vehicle)
                    if trunkCoords and Vdist(trunkCoords.x, trunkCoords.y, trunkCoords.z, pcoords.x, pcoords.y, pcoords.z) < 5.0 then
                        local netId = VehToNet(vehicle)
                        local zoneId = 'bodycam_trunk_' .. tostring(netId)
                        if not knownZones[zoneId] then
                            local success, err = pcall(function()
                                exports.ox_target:addBoxZone({
                                    coords = trunkCoords,
                                    size = vec3(1.2, 1.2, 1.0),
                                    rotation = 0.0,
                                    debug = false,
                                    options = {
                                        {
                                            name = 'bodycam_get_armor_' .. tostring(netId),
                                            event = 'bodycam:requestGetArmor',
                                            icon = 'fa-solid fa-shield-alt',
                                            label = 'Get Armor',
                                            canInteract = function()
                                                return true
                                            end,
                                        },
                                        {
                                            name = 'bodycam_push_vehicle_' .. tostring(netId),
                                            event = 'bodycam:requestPushVehicle',
                                            icon = 'fa-solid fa-car-bump',
                                            label = 'Push Vehicle',
                                            canInteract = function()
                                                return true
                                            end,
                                        }
                                        ,
                                        {
                                            name = 'bodycam_grab_medstation_' .. tostring(netId),
                                            event = 'bodycam:requestGrabMedstation',
                                            icon = 'fa-solid fa-box-medical',
                                            label = 'Grab Medstation',
                                            canInteract = function()
                                                return true
                                            end,
                                        }
                                        ,
                                        {
                                            name = 'bodycam_tow_vehicle_' .. tostring(netId),
                                            event = 'bodycam:requestTowVehicle',
                                            icon = 'fa-solid fa-truck-field',
                                            label = 'Tow Vehicle',
                                            canInteract = function()
                                                return true
                                            end,
                                        }
                                    }
                                })
                            end)
                            knownZones[zoneId] = true
                        end
                    end
                end
            end
            Citizen.Wait(3000)
        end
    end)
end

-- Register events
RegisterNetEvent('bodycam:leotarget:getArmor', function(data)
    local ped = PlayerPedId()
    -- Primary check: are we near a vehicle trunk? If not, still give armor as a fallback
    local vehicle = nil
    local pcoords = GetEntityCoords(ped)
    local vehicles = GetGamePool('CVehicle')
    for _, v in ipairs(vehicles) do
        if DoesEntityExist(v) then
            local trunkCoords = getClosestVehicleBoneOffset(v)
            if trunkCoords and Vdist(trunkCoords.x, trunkCoords.y, trunkCoords.z, pcoords.x, pcoords.y, pcoords.z) < 2.5 then
                vehicle = v
                break
            end
        end
    end

    if vehicle then
        givePlayerArmor(100)
    else
        givePlayerArmor(100)
    end
end)

RegisterNetEvent('bodycam:leotarget:pushVehicle', function(data)
    local ped = PlayerPedId()
    local vehicle = nil
    local pcoords = GetEntityCoords(ped)
    local vehicles = GetGamePool('CVehicle')
    for _, v in ipairs(vehicles) do
        if DoesEntityExist(v) then
            local trunkCoords = getClosestVehicleBoneOffset(v)
            if trunkCoords and Vdist(trunkCoords.x, trunkCoords.y, trunkCoords.z, pcoords.x, pcoords.y, pcoords.z) < 2.5 then
                vehicle = v
                break
            end
        end
    end

    if vehicle then
        pushVehicle(vehicle)
    else
        safeNotify('No vehicle trunk nearby to push.')
    end
end)

RegisterNetEvent('bodycam:leotarget:grabMedstation', function(data)
    -- If already carrying, drop it
    if carriedMedstation and DoesEntityExist(carriedMedstation) then
        removeCarriedMedstation()
        return
    end

    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    -- spawn the medstation slightly in front of player so attach works
    local model = GetHashKey('prop_medstation_03')
    RequestModel(model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(model) then
        safeNotify('Failed to load medstation model.')
        return
    end

    local fx, fy, fz = table.unpack(GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.8, -0.95))
    local obj = CreateObject(model, fx, fy, fz, true, true, true)
    SetEntityAsMissionEntity(obj, true, true)
    PlaceObjectOnGroundProperly(obj)
    Citizen.Wait(100)
    attachMedstationToPlayer(obj)
    -- release model
    SetModelAsNoLongerNeeded(model)
end)

-- Init
Citizen.CreateThread(function()
    if not hasOxTarget then
        print('bodycam: ox_target not found - trunk interactions disabled')
        return
    end

    -- Prefer entity targeting if available
    local ok, _ = pcall(function()
        registerEntityTrunkTarget()
    end)

    -- Also start fallback poll for older ox_target that may only support addBoxZone
    registerZoneFallback()
end)

-- Client-side forwarders: some ox_target/lib setups trigger client events, so forward them to server
RegisterNetEvent('bodycam:requestGetArmor', function()
    TriggerServerEvent('bodycam:requestGetArmor')
end)

RegisterNetEvent('bodycam:requestPushVehicle', function()
    TriggerServerEvent('bodycam:requestPushVehicle')
end)

RegisterNetEvent('bodycam:requestGrabMedstation', function()
    TriggerServerEvent('bodycam:requestGrabMedstation')
end)

RegisterNetEvent('bodycam:requestSpawnVehicle', function(data)
    -- lib context may pass args as table or string
    if type(data) == 'table' and data.model then
        TriggerServerEvent('bodycam:requestSpawnVehicle', data.model)
    elseif type(data) == 'string' then
        TriggerServerEvent('bodycam:requestSpawnVehicle', data)
    end
end)

RegisterNetEvent('bodycam:requestTowVehicle', function(data)
    -- Forward to server; ox_target may pass a netId or nothing
    if type(data) == 'number' then
        TriggerServerEvent('bodycam:requestTowVehicle', data)
    elseif type(data) == 'table' and data.vehicleNetId then
        TriggerServerEvent('bodycam:requestTowVehicle', data.vehicleNetId)
    else
        -- try to find nearest vehicle and pass its network id
        local ped = PlayerPedId()
        local pcoords = GetEntityCoords(ped)
        local vehicles = GetGamePool('CVehicle')
        local best = nil
        local bestDist = 999.0
        for _, v in ipairs(vehicles) do
            if DoesEntityExist(v) then
                local d = #(pcoords - GetEntityCoords(v))
                if d < bestDist then bestDist = d; best = v end
            end
        end
        if best then
            TriggerServerEvent('bodycam:requestTowVehicle', VehToNet(best))
        else
            safeNotify('No nearby vehicle found to tow.')
        end
    end
end)

-- Show a simple confirmation prompt (Y/N) using available UI hooks or chat prompt
local function promptConfirm(message, timeout)
    timeout = timeout or 15000
    -- Prefer NUI/BodycamNotify if available to show a blocking prompt; otherwise fallback to chat and key press
    if type(_G['BodycamConfirm']) == 'function' then
        local res = _G['BodycamConfirm'](message, timeout)
        return res
    end

    -- Fallback: send a chat message and wait for Y/N key press (E = accept, G = cancel) for simplicity
    safeNotify(message .. ' Press Y to confirm or N to cancel.')
    local start = GetGameTimer()
    while GetGameTimer() - start < timeout do
        if IsControlJustReleased(0, 246) or IsControlJustReleased(0, 246) then -- Y (INPUT_MP_TEXT_CHAT_TEAM) mapping can vary
            return true
        end
        if IsControlJustReleased(0, 249) then -- N
            return false
        end
        Citizen.Wait(0)
    end
    return false
end

-- Client-side: spawn tow truck, driver, drive to target, attach, drive to dropoff and cleanup
RegisterNetEvent('bodycam:performTow', function(payload)
    -- Deprecated: server now approves tow; this event is legacy and will be ignored
    safeNotify('Local tow event is deprecated. Use server-approved tow flow.')
end)


-- Handle server-approved tow payload: spawn tow truck & NPC, attach using model geometry, drive to server-provided drop coords
RegisterNetEvent('bodycam:performTowApproved', function(payload)
    if not payload or not payload.vehicleNetId then return end
    local targetNet = payload.vehicleNetId
    local targetVeh = NetToVeh(targetNet)
    if not DoesEntityExist(targetVeh) then
        safeNotify('Target vehicle not found or out of range.')
        return
    end

    local drop = payload.drop or nil
    local fee = payload.fee or 0
    local ticket = payload.ticket or ''

    -- Ask player to confirm tow and show fee
    local confirmed = promptConfirm(('Confirm tow to impound (fee $%d)? [Y/N]'):format(fee), 15000)
    if not confirmed then
        safeNotify('Tow cancelled.')
        return
    end

    -- Spawn tow truck and driver near the target
    local towModel = GetHashKey('flatbed') -- common tow truck model
    local driverModel = GetHashKey('s_m_m_trucker_01')
    RequestModel(towModel); RequestModel(driverModel)
    local deadline = GetGameTimer() + 5000
    while (not HasModelLoaded(towModel) or not HasModelLoaded(driverModel)) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(towModel) or not HasModelLoaded(driverModel) then
        safeNotify('Failed to load tow assets.')
        return
    end

    local vx, vy, vz = table.unpack(GetEntityCoords(targetVeh))
    -- spawn offset behind/side to avoid collisions
    local tx, ty, tz = vx + 6.0, vy + 2.0, vz
    local towVeh = CreateVehicle(towModel, tx, ty, tz, GetEntityHeading(targetVeh), true, false)
    if not DoesEntityExist(towVeh) then safeNotify('Failed to spawn tow truck'); return end
    SetVehicleDoorsLocked(towVeh, 1)

    local driver = CreatePedInsideVehicle(towVeh, 4, driverModel, -1, true, false)
    if not DoesEntityExist(driver) then safeNotify('Failed to spawn tow driver'); end

    -- Drive to the target
    local tx2, ty2, tz2 = table.unpack(GetEntityCoords(targetVeh))
    TaskVehicleDriveToCoord(driver, towVeh, tx2, ty2, tz2, 8.0, 0, GetEntityModel(towVeh), 786603, 1.0, 1.0)

    -- Wait until near the target or timeout
    local start = GetGameTimer()
    local cx, cy, cz = table.unpack(GetEntityCoords(towVeh))
    while (Vdist(cx, cy, cz, tx2, ty2, tz2) > 6.0) and (GetGameTimer() - start < 20000) do
        cx, cy, cz = table.unpack(GetEntityCoords(towVeh))
        Citizen.Wait(200)
    end

    -- Improved attach: compute tow offsets using tow model dimensions (wheel-lift style)
    local towLength = 6.0
    local attachX, attachY, attachZ = 0.0, -towLength, 0.8
    -- Attempt to attach at a more realistic position using both entities' forward vectors
    AttachEntityToEntity(targetVeh, towVeh, 0, attachX, attachY, attachZ, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    safeNotify('Vehicle attached to tow truck. Ticket: ' .. tostring(ticket))

    -- Drive to impound/drop provided by server
    local dropx, dropy, dropz = tx + 40.0, ty + 40.0, tz
    if drop then dropx, dropy, dropz = drop.x, drop.y, drop.z end
    TaskVehicleDriveToCoord(driver, towVeh, dropx, dropy, dropz, 15.0, 0, GetEntityModel(towVeh), 786603, 1.0, 1.0)

    -- Wait until arrives or times out
    start = GetGameTimer()
    local txw, tyw, tzw = table.unpack(GetEntityCoords(towVeh))
    while (Vdist(txw, tyw, tzw, dropx, dropy, dropz) > 6.0) and (GetGameTimer() - start < 60000) do
        txw, tyw, tzw = table.unpack(GetEntityCoords(towVeh))
        Citizen.Wait(500)
    end

    -- Detach and leave the vehicle at dropoff (do not delete); mark mission entity so it persists until server cleans
    DetachEntity(targetVeh, true, true)
    SetEntityAsMissionEntity(targetVeh, true, true)
    SetVehicleOnGroundProperly(targetVeh)
    safeNotify(('Vehicle towed to impound. Fee: $%d (ticket %s)'):format(fee, tostring(ticket)))

    -- Cleanup: delete tow truck and driver
    SetEntityAsMissionEntity(towVeh, true, true)
    DeleteVehicle(towVeh)
    if DoesEntityExist(driver) then
        DeletePed(driver)
    end

    -- Release models
    SetModelAsNoLongerNeeded(towModel)
    SetModelAsNoLongerNeeded(driverModel)
end)


-- Server instructs the client to spawn tow assets; client replies with net ids and proceeds to tow
RegisterNetEvent('bodycam:spawnTowVehicleClient', function(payload)
    if not payload or not payload.vehicleNetId then return end
    local targetNet = payload.vehicleNetId
    local targetVeh = NetToVeh(targetNet)
    if not DoesEntityExist(targetVeh) then
        safeNotify('Target vehicle not found or out of range.')
        return
    end

    local drop = payload.drop or nil
    local fee = payload.fee or 0
    local ticket = payload.ticket or ''

    -- Ask player to confirm tow (fee shown)
    local confirmed = promptConfirm(('Confirm tow and dispatch tow truck (fee $%d)? [Y/N]'):format(fee), 15000)
    if not confirmed then
        safeNotify('Tow cancelled.')
        return
    end

    -- Spawn tow truck a distance away so it must drive to the target
    local towModel = GetHashKey('flatbed')
    local driverModel = GetHashKey('s_m_m_trucker_01')
    RequestModel(towModel); RequestModel(driverModel)
    local deadline = GetGameTimer() + 5000
    while (not HasModelLoaded(towModel) or not HasModelLoaded(driverModel)) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(towModel) or not HasModelLoaded(driverModel) then
        safeNotify('Failed to load tow assets.')
        return
    end

    local vx, vy, vz = table.unpack(GetEntityCoords(targetVeh))
    local angle = math.rad(math.random(0, 359))
    local spawnDist = 20.0 + math.random() * 10.0 -- spawn 20-30m away
    local sx, sy, sz = vx + math.cos(angle) * spawnDist, vy + math.sin(angle) * spawnDist, vz
    local spawnHeading = (math.deg(angle) + 180.0) % 360.0
    local towVeh = CreateVehicle(towModel, sx, sy, sz, spawnHeading, true, true)
    if not DoesEntityExist(towVeh) then safeNotify('Failed to spawn tow truck'); return end
    SetVehicleDoorsLocked(towVeh, 1)

    local driver = CreatePedInsideVehicle(towVeh, 4, driverModel, -1, true, true)
    if not DoesEntityExist(driver) then safeNotify('Failed to spawn tow driver'); end

    -- Report spawned tow assets to server for authoritative tracking
    local towNet = VehToNet(towVeh)
    local driverNet = PedToNet(driver)
    TriggerServerEvent('bodycam:serverTowSpawned', { ticket = ticket, towNetId = towNet, driverNetId = driverNet })

    -- Make driver drive to the target vehicle
    local tx2, ty2, tz2 = table.unpack(GetEntityCoords(targetVeh))
    TaskVehicleDriveToCoord(driver, towVeh, tx2, ty2, tz2, 8.0, 0, GetEntityModel(towVeh), 786603, 1.0, 1.0)

    -- Wait until near the target or timeout
    local start = GetGameTimer()
    local cx, cy, cz = table.unpack(GetEntityCoords(towVeh))
    while (Vdist(cx, cy, cz, tx2, ty2, tz2) > 6.0) and (GetGameTimer() - start < 20000) do
        cx, cy, cz = table.unpack(GetEntityCoords(towVeh))
        Citizen.Wait(200)
    end

    -- Attach target vehicle to tow truck (wheel-lift style offset)
    local attachX, attachY, attachZ = 0.0, -6.0, 1.0
    AttachEntityToEntity(targetVeh, towVeh, 0, attachX, attachY, attachZ, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
    safeNotify('Vehicle attached to tow truck. Ticket: ' .. tostring(ticket))

    -- Drive to impound/drop provided by server (or default coordinates)
    local dropx, dropy, dropz, droph = 2365.5063, 3115.6067, 48.3112, 12.6129
    if drop and drop.x and drop.y and drop.z then
        dropx, dropy, dropz, droph = drop.x, drop.y, drop.z, drop.h or droph
    end
    TaskVehicleDriveToCoord(driver, towVeh, dropx, dropy, dropz, 15.0, 0, GetEntityModel(towVeh), 786603, 1.0, 1.0)

    -- Wait until arrives or times out
    start = GetGameTimer()
    local txw, tyw, tzw = table.unpack(GetEntityCoords(towVeh))
    while (Vdist(txw, tyw, tzw, dropx, dropy, dropz) > 6.0) and (GetGameTimer() - start < 60000) do
        txw, tyw, tzw = table.unpack(GetEntityCoords(towVeh))
        Citizen.Wait(500)
    end

    -- Detach and place the vehicle at dropoff
    DetachEntity(targetVeh, true, true)
    SetEntityAsMissionEntity(targetVeh, true, true)
    SetVehicleOnGroundProperly(targetVeh)
    if droph then SetEntityHeading(targetVeh, droph) end
    safeNotify(('Vehicle towed to impound. Fee: $%d (ticket %s)'):format(fee, tostring(ticket)))

    -- Notify server of completion
    TriggerServerEvent('bodycam:serverTowComplete', { ticket = ticket, dropCoords = { x = dropx, y = dropy, z = dropz } })

    -- Cleanup: delete tow truck and driver
    SetEntityAsMissionEntity(towVeh, true, true)
    DeleteVehicle(towVeh)
    if DoesEntityExist(driver) then DeletePed(driver) end

    SetModelAsNoLongerNeeded(towModel)
    SetModelAsNoLongerNeeded(driverModel)
end)

-- Spawn a police ped and add an ox_target to view on-duty officers
local copPed = nil
local function spawnPolicePed()
    local model = GetHashKey('s_m_y_cop_01')
    RequestModel(model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(model) then
        print('bodycam: failed to load cop model for on-duty ped')
        return
    end

    local x, y, z, h = -451.9812, 6012.6792, 31.3887, 228.9432
    copPed = CreatePed(4, model, x, y, z - 1.0, h, false, true)
    if DoesEntityExist(copPed) then
        SetEntityHeading(copPed, h)
        SetEntityAsMissionEntity(copPed, true, true)
        FreezeEntityPosition(copPed, true)
        SetBlockingOfNonTemporaryEvents(copPed, true)
        SetPedCanRagdoll(copPed, false)
        SetEntityInvincible(copPed, true)

        -- register ox_target option on this ped
        local opts = {
            {
                name = 'bodycam_view_onduty',
                event = 'bodycam:leotarget:viewOnduty',
                icon = 'fa-solid fa-list',
                label = 'View On-Duty Officers',
                canInteract = function(entity, distance, data)
                    return true
                end
            }
        }
        local ok = false
        -- try the flexible addEntity helper we defined earlier
        if type(tryAddEntityTarget) == 'function' then
            ok = tryAddEntityTarget(copPed, opts)
        end
        if not ok then
            pcall(function()
                exports.ox_target:addEntity(opts, { entity = copPed })
            end)
        end
    end
    SetModelAsNoLongerNeeded(model)
end

RegisterNetEvent('bodycam:leotarget:viewOnduty', function(data)
    -- Request the on-duty list from server; existing client handler will display it
    TriggerServerEvent('bodycam:requestOnDuty')
end)

Citizen.CreateThread(function()
    if hasOxTarget then
        spawnPolicePed()
    end
end)


-- Spawn a vehicle spawner ped with ox_target that opens a lib context menu
local spawnerPed = nil
local function spawnVehicleSpawnerPed()
    local model = GetHashKey('s_m_y_cop_01')
    RequestModel(model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(model) then
        print('bodycam: failed to load cop model for vehicle spawner ped')
        return
    end

    local x, y, z, h = -473.1522, 5971.9492, 31.3108, 350.3018
    spawnerPed = CreatePed(4, model, x, y, z - 1.0, h, false, true)
    if DoesEntityExist(spawnerPed) then
        SetEntityHeading(spawnerPed, h)
        SetEntityAsMissionEntity(spawnerPed, true, true)
        FreezeEntityPosition(spawnerPed, true)
        SetBlockingOfNonTemporaryEvents(spawnerPed, true)
        SetPedCanRagdoll(spawnerPed, false)
        SetEntityInvincible(spawnerPed, true)

        local opts = {
            {
                name = 'bodycam_vehicle_spawner',
                event = 'bodycam:leotarget:openVehicleSpawner',
                icon = 'fa-solid fa-truck',
                label = 'Vehicle Spawner',
                canInteract = function(entity, distance, data)
                    return true
                end
            }
        }
        local ok = tryAddEntityTarget(spawnerPed, opts)
        if not ok then
            pcall(function()
                exports.ox_target:addEntity(opts, { entity = spawnerPed })
            end)
        end
    end
    SetModelAsNoLongerNeeded(model)
end

-- Helper to spawn LEO vehicle at player's position
local function spawnLeoVehicle(modelName)
    local model = GetHashKey(modelName)
    RequestModel(model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(model) then
        safeNotify('Vehicle model failed to load: ' .. tostring(modelName))
        return
    end
    local ped = PlayerPedId()
    local px, py, pz = table.unpack(GetEntityCoords(ped))
    local fx, fy, fz = table.unpack(GetOffsetFromEntityInWorldCoords(ped, 0.0, 3.5, 0.0))
    local veh = CreateVehicle(model, fx, fy, pz, GetEntityHeading(ped), true, false)
    if DoesEntityExist(veh) then
        SetVehicleOnGroundProperly(veh)
        SetVehicleNumberPlateText(veh, 'L-E-O')
        SetModelAsNoLongerNeeded(model)
        safeNotify('Spawned vehicle: ' .. modelName)
    else
        safeNotify('Failed to spawn vehicle: ' .. modelName)
    end
end

-- Open a lib.context menu with multiple LEO vehicle options
RegisterNetEvent('bodycam:leotarget:openVehicleSpawner', function(data)
    local entries = {
        { id = 'police', title = 'Police Cruiser', description = 'Standard cruiser', action = function() spawnLeoVehicle('police') end },
        { id = 'sheriff', title = 'Sheriff Cruiser', description = 'Sheriff vehicle', action = function() spawnLeoVehicle('sheriff') end },
        { id = 'riot', title = 'Riot Van', description = 'Armored support', action = function() spawnLeoVehicle('riot') end },
    }

    -- Use lib.context / lib.showContext if available (safe local lookup)
    local contextLib = nil
    if type(_G['lib']) == 'table' then
        contextLib = _G['lib']
    end

    if contextLib and type(contextLib.showContext) == 'function' then
        local options = {}
        for _, e in ipairs(entries) do
            table.insert(options, { title = e.title, description = e.description, event = 'bodycam:requestSpawnVehicle', args = { model = e.id } })
        end
        pcall(function()
            contextLib.showContext({ options = options })
        end)
        return
    end

    -- Fallback: if lib.registerContext & lib.showContext pattern
    if contextLib and type(contextLib.registerContext) == 'function' and type(contextLib.showContext) == 'function' then
        local id = 'bodycam_vehicle_spawner'
        local ctx = { id = id, title = 'Vehicle Spawner', options = {} }
        for _, e in ipairs(entries) do
            table.insert(ctx.options, { id = e.id, title = e.title, description = e.description, event = 'bodycam:requestSpawnVehicle', args = { model = e.id } })
        end
        pcall(function()
            contextLib.registerContext(ctx)
            contextLib.showContext(id)
        end)
        return
    end

    -- Last resort fallback: ask server to spawn the first option (server will validate ACE)
    safeNotify('Context menu not available; requesting default vehicle spawn')
    TriggerServerEvent('bodycam:requestSpawnVehicle', entries[1].id)
end)

-- This event is intended to be called by the server after ACE validation
RegisterNetEvent('bodycam:leotarget:spawnVehicle', function(data)
    if data and data.model then
        spawnLeoVehicle(data.model)
    end
end)

Citizen.CreateThread(function()
    if hasOxTarget then
        spawnVehicleSpawnerPed()
    end
end)

-- Spawn an additional male NPC with a vehicle spawner ox_target at the requested location
local spawnerNpc = nil
local function spawnVehicleSpawnerNPC()
    local model = GetHashKey('a_m_m_business_01') -- generic male NPC
    RequestModel(model)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if not HasModelLoaded(model) then
        print('bodycam: failed to load NPC model for vehicle spawner NPC')
        return
    end

    local x, y, z, h = -473.8428, 5968.5469, 31.3108, 338.2041
    spawnerNpc = CreatePed(4, model, x, y, z - 1.0, h, false, true)
    if DoesEntityExist(spawnerNpc) then
        SetEntityHeading(spawnerNpc, h)
        SetEntityAsMissionEntity(spawnerNpc, true, true)
        FreezeEntityPosition(spawnerNpc, true)
        SetBlockingOfNonTemporaryEvents(spawnerNpc, true)
        SetPedCanRagdoll(spawnerNpc, false)
        SetEntityInvincible(spawnerNpc, true)

        local opts = {
            {
                name = 'bodycam_vehicle_spawner_npc',
                event = 'bodycam:leotarget:openVehicleSpawner',
                icon = 'fa-solid fa-truck',
                label = 'Vehicle Spawner',
                canInteract = function(entity, distance, data)
                    return true
                end
            }
        }
        local ok = tryAddEntityTarget(spawnerNpc, opts)
        if not ok then
            pcall(function()
                exports.ox_target:addEntity(opts, { entity = spawnerNpc })
            end)
        end
    end
    SetModelAsNoLongerNeeded(model)
end

Citizen.CreateThread(function()
    if hasOxTarget then
        spawnVehicleSpawnerNPC()
    end
end)
