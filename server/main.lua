local RejectLogWindows = {}

local function reject(sourceId, eventName, code)
  local key = ('%s:%s:%s'):format(tostring(sourceId), tostring(eventName), tostring(code))
  local current = GetGameTimer()
  local window = RejectLogWindows[key]
  if window and current - window.lastAt < 5000 then
    window.suppressed = window.suppressed + 1
    return
  end
  print(('[mz_medical][client_event_rejected] source=%s event=%s code=%s suppressed=%s'):format(
    tostring(sourceId), tostring(eventName), tostring(code), tostring(window and window.suppressed or 0)
  ))
  RejectLogWindows[key] = { lastAt = current, suppressed = 0 }
end

local function closedPayload(payload, allowed, maximum)
  if type(payload) ~= 'table' then return false end
  local count = 0
  for key in pairs(payload) do
    count = count + 1
    if count > maximum or allowed[key] ~= true then return false end
  end
  return true
end

local function validToken(value)
  return type(value) == 'string' and #value > 0 and #value <= 128
end

RegisterNetEvent('mz_medical:server:requestHelp', function(payload)
  local sourceId = source
  if not MZMedicalService.consumeClientAttempt(sourceId, 'help') then return reject(sourceId, 'requestHelp', 'rate_limited') end
  if not closedPayload(payload, { sessionToken = true }, 1) or not validToken(payload.sessionToken) then
    return reject(sourceId, 'requestHelp', 'invalid_payload')
  end
  local ok, result = MZMedicalService.requestHelp(sourceId, payload.sessionToken)
  TriggerClientEvent('mz_medical:client:result', sourceId, { action = 'help', ok = ok, result = result })
end)

RegisterNetEvent('mz_medical:server:startTreatment', function(payload)
  local sourceId = source
  if not MZMedicalService.consumeClientAttempt(sourceId, 'start_treatment') then return reject(sourceId, 'startTreatment', 'rate_limited') end
  if not closedPayload(payload, { target = true, sessionToken = true, revision = true }, 3)
    or type(payload.target) ~= 'number' or payload.target ~= math.floor(payload.target)
    or type(payload.revision) ~= 'number' or payload.revision ~= math.floor(payload.revision) or payload.revision < 0
    or not validToken(payload.sessionToken) then return reject(sourceId, 'startTreatment', 'invalid_payload') end
  local ok, result = MZMedicalService.startTreatment(sourceId, payload.target, payload.sessionToken, payload.revision)
  TriggerClientEvent('mz_medical:client:result', sourceId, { action = 'treatment', ok = ok, result = result })
end)

local function treatmentCandidate(eventName, payload, completed)
  local sourceId = source
  if not MZMedicalService.consumeClientAttempt(sourceId, eventName) then return reject(sourceId, eventName, 'rate_limited') end
  if not closedPayload(payload, { operationId = true, token = true, sessionToken = true }, 3)
    or not validToken(payload.operationId) or not validToken(payload.token)
    or not validToken(payload.sessionToken) then return reject(sourceId, eventName, 'invalid_payload') end
  local ok, result
  if completed then
    ok, result = MZMedicalService.completeTreatment(sourceId, payload.operationId, payload.token, payload.sessionToken)
  else
    ok, result = MZMedicalService.cancelTreatment(sourceId, payload.operationId, payload.token, payload.sessionToken, 'client_cancelled')
  end
  TriggerClientEvent('mz_medical:client:result', sourceId, { action = eventName, ok = ok, result = result })
end

RegisterNetEvent('mz_medical:server:completeTreatment', function(payload) treatmentCandidate('completeTreatment', payload, true) end)
RegisterNetEvent('mz_medical:server:cancelTreatment', function(payload) treatmentCandidate('cancelTreatment', payload, false) end)

RegisterNetEvent('mz_medical:server:requestHospitalRespawn', function(payload)
  local sourceId = source
  if not MZMedicalService.consumeClientAttempt(sourceId, 'request_respawn') then return reject(sourceId, 'requestHospitalRespawn', 'rate_limited') end
  if not closedPayload(payload, { sessionToken = true, revision = true }, 2)
    or type(payload.revision) ~= 'number' or payload.revision ~= math.floor(payload.revision) or payload.revision < 0
    or not validToken(payload.sessionToken) then return reject(sourceId, 'requestHospitalRespawn', 'invalid_payload') end
  local ok, result = MZMedicalService.requestHospitalRespawn(sourceId, payload.sessionToken, payload.revision)
  TriggerClientEvent('mz_medical:client:result', sourceId, { action = 'respawn', ok = ok, result = result })
end)

RegisterNetEvent('mz_medical:server:hospitalSpawnReady', function(payload)
  local sourceId = source
  if not MZMedicalService.consumeClientAttempt(sourceId, 'spawn_ready') then return reject(sourceId, 'hospitalSpawnReady', 'rate_limited') end
  if not closedPayload(payload, { operationId = true, token = true }, 2)
    or not validToken(payload.operationId) or not validToken(payload.token) then
    return reject(sourceId, 'hospitalSpawnReady', 'invalid_payload')
  end
  local ok, result = MZMedicalService.confirmHospitalSpawn(sourceId, payload.operationId, payload.token)
  TriggerClientEvent('mz_medical:client:result', sourceId, { action = 'spawn_ready', ok = ok, result = result })
end)

AddEventHandler('mz_core:server:playerDeathStateChangedInternal', function(sourceId)
  MZMedicalService.ensureDeadline(sourceId)
end)

AddEventHandler('playerDropped', function()
  MZMedicalService.cancelPlayerOperations(source, 'player_dropped')
  local prefix = tostring(source) .. ':'
  for key in pairs(RejectLogWindows) do if key:sub(1, #prefix) == prefix then RejectLogWindows[key] = nil end end
end)

AddEventHandler('onResourceStart', function(resourceName)
  if resourceName ~= GetCurrentResourceName() then return end
  MZMedicalService.resetForStart()
  CreateThread(function()
    Wait(1000)
    for _, rawSource in ipairs(GetPlayers()) do MZMedicalService.ensureDeadline(tonumber(rawSource)) end
  end)
end)

AddEventHandler('onResourceStop', function(resourceName)
  if resourceName == GetCurrentResourceName() then MZMedicalService.stop() end
end)

CreateThread(function()
  while true do
    Wait(math.max(250, math.floor(tonumber(Config.Medical.scheduler.intervalMs) or 1000)))
    MZMedicalService.tick()
  end
end)

exports('GetMedicalState', function(source)
  local stateOk, state = exports['mz_core']:GetPlayerState(source)
  if not stateOk then return false, state end
  return true, { deathState = state.state.deathState, revision = state.revision, deathTimestamps = state.state.deathTimestamps }
end)

local function resourceAllowed(list, invokingResource)
  if type(invokingResource) ~= 'string' or invokingResource == '' then return false end
  for _, resourceName in ipairs(type(list) == 'table' and list or {}) do
    if resourceName == invokingResource then return true end
  end
  return false
end

exports('GetMedicalOperations', function()
  local administration = Config.Medical.administration or {}
  if not resourceAllowed(administration.readResources, GetInvokingResource()) then
    return false, { code = 'not_authorized' }
  end
  return true, MZMedicalService.getOperations()
end)

exports('RecoverMedicalOperation', function(operationId)
  local administration = Config.Medical.administration or {}
  if not resourceAllowed(administration.recoveryResources, GetInvokingResource()) then
    return false, { code = 'not_authorized' }
  end
  if type(operationId) ~= 'string' or operationId == '' or #operationId > 128 then
    return false, { code = 'invalid_operation_id' }
  end
  return MZMedicalService.recoverOperation(operationId)
end)

exports('RecoverPlayer', function(source, reason)
  if GetInvokingResource() ~= Config.Medical.administration.allowedResource then return false, { code = 'not_authorized' } end
  return MZMedicalService.recoverPlayer(source, reason or 'admin_recovery')
end)

exports('CancelPlayerMedicalOperation', function(source, reason)
  if GetInvokingResource() ~= Config.Medical.administration.allowedResource then return false, { code = 'not_authorized' } end
  MZMedicalService.cancelPlayerOperations(source, reason or 'admin_cancel')
  return true, { code = 'cancelled' }
end)

local StagingCommandWindows = {}

local function stagingReply(source, message)
  if tonumber(source) == 0 then
    print(('[mz_medical][staging] %s'):format(tostring(message)))
    return
  end
  TriggerClientEvent('chat:addMessage', source, { args = { 'MZ Medical', tostring(message) } })
end

local function stagingAllowed(source, command)
  local staging = Config.Medical.staging or {}
  if staging.enabled ~= true then
    stagingReply(source, ('%s: staging_disabled'):format(command))
    return false
  end
  source = tonumber(source) or 0
  if source ~= 0 and (type(IsPlayerAceAllowed) ~= 'function' or not IsPlayerAceAllowed(source, tostring(staging.ace or 'mz_medical.staging'))) then
    stagingReply(source, ('%s: not_authorized'):format(command))
    return false
  end
  local now = GetGameTimer()
  local window = StagingCommandWindows[source]
  if not window or now - window.startedAt >= 10000 then
    window = { startedAt = now, count = 0 }
    StagingCommandWindows[source] = window
  end
  window.count = window.count + 1
  if window.count > 12 then
    stagingReply(source, ('%s: rate_limited'):format(command))
    return false
  end
  return true
end

local function stagingEncode(value)
  local ok, encoded = pcall(json.encode, value)
  return ok and encoded or tostring(value)
end

RegisterCommand('mz_medical_diag', function(source, args)
  if not stagingAllowed(source, 'mz_medical_diag') then return end
  local target = tonumber(type(args) == 'table' and args[1] or nil)
  if not target or target <= 0 or not GetPlayerName(target) then return stagingReply(source, 'uso: mz_medical_diag <source>') end
  local ok, state = exports['mz_core']:GetPlayerState(math.floor(target))
  stagingReply(source, stagingEncode({ ok = ok == true, result = state }))
end, false)

RegisterCommand('mz_medical_ops', function(source)
  if not stagingAllowed(source, 'mz_medical_ops') then return end
  stagingReply(source, stagingEncode({ ok = true, result = MZMedicalService.getOperations() }))
end, false)

RegisterCommand('mz_medical_recover', function(source, args)
  if not stagingAllowed(source, 'mz_medical_recover') then return end
  local operationId = tostring(type(args) == 'table' and args[1] or '')
  if operationId == '' or #operationId > 128 then return stagingReply(source, 'uso: mz_medical_recover <operationId>') end
  local ok, result = MZMedicalService.recoverOperation(operationId)
  stagingReply(source, stagingEncode({ ok = ok == true, result = result }))
end, false)

AddEventHandler('playerDropped', function()
  StagingCommandWindows[tonumber(source)] = nil
end)
