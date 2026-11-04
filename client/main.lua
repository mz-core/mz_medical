local current = nil
local treatment = nil
local presentationGeneration = 0
local nextHudRefreshAt = 0

print('[mz_medical][client_started] presentation_clock=server_anchored_v2')

local function canonical()
  local ok, state = pcall(function() return exports['mz_core']:GetLocalPlayerState() end)
  if not ok or type(state) ~= 'table' then return nil end
  local envelopeOk, envelope = pcall(function() return exports['mz_core']:GetLocalPlayerStateEnvelope() end)
  if not envelopeOk or type(envelope) ~= 'table' or type(envelope.sessionToken) ~= 'string' then return nil end
  state.sessionToken = envelope.sessionToken
  return state
end

local function notify(message, kind)
  if lib and lib.notify then lib.notify({ title = 'Medico', description = message, type = kind or 'inform' }) end
end

local function secondsRemaining(deadline, snapshot)
  if not deadline then return 0 end
  local serverTime = snapshot and snapshot.reason and tonumber(snapshot.reason.serverTime)
  local receivedAt = snapshot and tonumber(snapshot._medicalReceivedAtMs)
  local estimatedServerTime = serverTime
  if serverTime and receivedAt then
    estimatedServerTime = serverTime + math.max(0, GetGameTimer() - receivedAt) / 1000
  end
  if not estimatedServerTime then return 0 end
  return math.max(0, math.ceil(tonumber(deadline) - estimatedServerTime))
end

local function hudPayload(snapshot)
  local death = snapshot and snapshot.death or {}
  local deadline = death.state == 'downed' and death.downedExpiresAt
    or death.state == 'dead' and death.respawnAvailableAt or nil
  local remaining = secondsRemaining(deadline, snapshot)
  return {
    state = death.state or 'alive',
    revision = snapshot and snapshot.revision or 0,
    deadline = deadline,
    remaining = remaining,
    serverTime = snapshot and snapshot.reason and snapshot.reason.serverTime or 0,
    helpEnabled = Config.Medical.help.enabled == true,
    respawnAvailable = death.state == 'dead' and deadline ~= nil and remaining <= 0,
    treatment = treatment ~= nil
  }
end

local function updatePresentation(snapshot)
  if type(snapshot) ~= 'table' then return end
  if current and current.sessionToken == snapshot.sessionToken and tonumber(snapshot.revision) < tonumber(current.revision) then return end
  if current and current.sessionToken ~= snapshot.sessionToken then treatment = nil end
  snapshot._medicalReceivedAtMs = GetGameTimer()
  current = snapshot
  nextHudRefreshAt = 0
  presentationGeneration = presentationGeneration + 1
  TriggerEvent('mz_hud:client:medicalState', hudPayload(snapshot))
end

local function loadAnim(dictionary, timeoutMs)
  RequestAnimDict(dictionary)
  local deadline = GetGameTimer() + timeoutMs
  while not HasAnimDictLoaded(dictionary) and GetGameTimer() < deadline do Wait(25) end
  return HasAnimDictLoaded(dictionary)
end

local function maintainDownedAnimation(generation)
  local animation = Config.Medical.downed.animation
  CreateThread(function()
    local loaded = loadAnim(animation.dictionary, animation.loadTimeoutMs)
    if not loaded then
      print(('[mz_medical][downed_animation_failed] dictionary=%s clip=%s'):format(
        tostring(animation.dictionary), tostring(animation.clip)
      ))
    end
    while generation == presentationGeneration and current and current.death.state == 'downed' do
      local ped = PlayerPedId()
      if loaded and ped and ped ~= 0 and DoesEntityExist(ped)
        and not IsEntityPlayingAnim(ped, animation.dictionary, animation.clip, 3) then
        TaskPlayAnim(ped, animation.dictionary, animation.clip, 8.0, -8.0, -1,
          tonumber(animation.flag) or 1, 0.0, false, false, false)
      end
      Wait(animation.reapplyIntervalMs)
    end
    local ped = PlayerPedId()
    if ped and ped ~= 0 and DoesEntityExist(ped) and loaded then StopAnimTask(ped, animation.dictionary, animation.clip, 2.0) end
  end)
end

RegisterNetEvent('mz_core:client:playerStateSync', function(payload)
  CreateThread(function()
    Wait(0)
    local snapshot = payload
    updatePresentation(snapshot)
    if snapshot.death and snapshot.death.state == 'downed' then
      maintainDownedAnimation(presentationGeneration)
    end
  end)
end)

RegisterNetEvent('mz_medical:client:startTreatment', function(payload)
  if type(payload) ~= 'table' or type(payload.operationId) ~= 'string' or type(payload.token) ~= 'string'
    or tonumber(payload.durationMs) == nil then return end
  treatment = { operationId = payload.operationId, token = payload.token }
  TriggerEvent('mz_hud:client:medicalState', hudPayload(current))
  local started = exports['mz_progress']:Start({
    id = payload.operationId, type = 'hospital', title = 'Atendimento medico',
    description = 'Estabilizando o paciente...', duration = payload.durationMs,
    cancellable = true, disable = { move = true, car = true, combat = true },
    animation = { dict = 'mini@cpr@char_a@cpr_str', clip = 'cpr_pumpchest', flag = 1 }
  }, function(cancelled)
    local operation = treatment
    treatment = nil
    TriggerEvent('mz_hud:client:medicalState', hudPayload(current))
    if not operation then return end
    local snapshot = current or canonical()
    TriggerServerEvent(cancelled and 'mz_medical:server:cancelTreatment' or 'mz_medical:server:completeTreatment', {
      operationId = operation.operationId, token = operation.token,
      sessionToken = snapshot and snapshot.sessionToken or ''
    })
  end)
  if not started then
    local operation = treatment
    treatment = nil
    if operation then TriggerServerEvent('mz_medical:server:cancelTreatment', {
      operationId = operation.operationId, token = operation.token,
      sessionToken = current and current.sessionToken or ''
    }) end
  end
end)

RegisterNetEvent('mz_medical:client:operationStopped', function(payload)
  if treatment and payload and payload.operationId == treatment.operationId then
    treatment = nil
    exports['mz_progress']:Cancel(payload.reason or 'server_cancelled')
    TriggerEvent('mz_hud:client:medicalState', hudPayload(current))
  end
end)

RegisterNetEvent('mz_core:client:authorizedSpawnReady', function(payload)
  if type(payload) ~= 'table' or type(payload.operationId) ~= 'string' or type(payload.token) ~= 'string' then return end
  TriggerServerEvent('mz_medical:server:hospitalSpawnReady', {
    operationId = payload.operationId, token = payload.token
  })
end)

RegisterNetEvent('mz_medical:client:result', function(payload)
  if not payload or payload.ok == true then return end
  notify(payload.result and (payload.result.message or payload.result.code) or 'Acao recusada.', 'error')
end)

RegisterNetEvent('mz_medical:client:respawnFailed', function(payload)
  notify(('Respawn falhou: %s'):format(tostring(payload and payload.code or 'unknown')), 'error')
end)

RegisterCommand(Config.Medical.treatment.command, function()
  local snapshot = current or canonical()
  if not snapshot or not snapshot.death or snapshot.death.state ~= 'alive' then return notify('Voce nao pode atender agora.', 'error') end
  local closestPlayer, closestDistance = nil, Config.Medical.treatment.candidateRadius
  local ownPed = PlayerPedId()
  local ownCoords = GetEntityCoords(ownPed)
  for _, player in ipairs(GetActivePlayers()) do
    if player ~= PlayerId() then
      local ped = GetPlayerPed(player)
      if ped and ped ~= 0 and DoesEntityExist(ped) then
        local measured = #(ownCoords - GetEntityCoords(ped))
        if measured <= closestDistance then closestPlayer, closestDistance = player, measured end
      end
    end
  end
  if not closestPlayer then return notify('Nenhum paciente proximo.', 'error') end
  TriggerServerEvent('mz_medical:server:startTreatment', {
    target = GetPlayerServerId(closestPlayer), sessionToken = snapshot.sessionToken, revision = snapshot.revision
  })
end, false)

CreateThread(function()
  Wait(1000)
  local snapshot = canonical()
  if snapshot then
    updatePresentation(snapshot)
    if snapshot.death and snapshot.death.state == 'downed' then maintainDownedAnimation(presentationGeneration) end
  else
    TriggerServerEvent('mz_core:server:requestPlayerStateSync')
  end
  while true do
    local snapshotNow = current
    local state = snapshotNow and snapshotNow.death and snapshotNow.death.state or 'alive'
    if state == 'alive' then Wait(1000)
    else
      DisablePlayerFiring(PlayerId(), true)
      for _, control in ipairs({ 21, 22, 23, 24, 25, 30, 31, 36, 37, 44, 45, 47, 58, 59, 63, 64, 71, 72, 75, 140, 141, 142, 143, 257, 263, 264 }) do
        DisableControlAction(0, control, true)
      end
      local death = snapshotNow.death
      local deadline = state == 'downed' and death.downedExpiresAt or death.respawnAvailableAt
      if GetGameTimer() >= nextHudRefreshAt then
        nextHudRefreshAt = GetGameTimer() + 1000
        TriggerEvent('mz_hud:client:medicalState', hudPayload(snapshotNow))
      end
      if Config.Medical.help.enabled and IsControlJustReleased(0, Config.Medical.help.key) then
        TriggerServerEvent('mz_medical:server:requestHelp', { sessionToken = snapshotNow.sessionToken })
      end
      if state == 'dead' and deadline and secondsRemaining(deadline, snapshotNow) <= 0
        and IsDisabledControlJustReleased(0, 38) then
        TriggerServerEvent('mz_medical:server:requestHospitalRespawn', {
          sessionToken = snapshotNow.sessionToken, revision = snapshotNow.revision
        })
      end
      Wait(0)
    end
  end
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  presentationGeneration = presentationGeneration + 1
  TriggerEvent('mz_hud:client:medicalState', { state = 'alive', revision = 0 })
  if exports['mz_progress']:IsRunning() then exports['mz_progress']:Cancel('resource_stopping') end
end)
