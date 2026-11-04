MZMedicalService = MZMedicalService or {}

local Treatments = {}
local TreatmentByExecutor = {}
local TreatmentByTarget = {}
local Respawns = {}
local ClientWindows = {}
local HelpWindows = {}
local TreatmentCooldowns = {}
local sequence = 0
local stopping = false

local ERROR_MESSAGES = {
  player_not_loaded = 'Jogador nao carregado.', target_not_loaded = 'Alvo nao carregado.',
  invalid_state = 'Estado incompativel.', invalid_target = 'Alvo invalido.', same_player = 'Alvo deve ser outro jogador.',
  invalid_distance = 'Distancia invalida.', not_authorized = 'Acao nao autorizada.', invalid_job = 'Organizacao invalida.',
  not_on_duty = 'Profissional fora de servico.', item_missing = 'Item medico ausente.',
  item_reservation_failed = 'Falha ao reservar item medico.', operation_in_progress = 'Atendimento ja em andamento.',
  target_in_treatment = 'Alvo ja esta em atendimento.', cooldown = 'Aguarde o cooldown.',
  operation_not_found = 'Operacao nao encontrada.', operation_expired = 'Operacao expirada.',
  operation_already_completed = 'Operacao ja concluida.', session_mismatch = 'Sessao divergente.',
  revision_mismatch = 'Revision divergente.', timer_not_finished = 'Temporizador ainda ativo.',
  respawn_not_available = 'Respawn hospitalar indisponivel.', payment_failed = 'Cobranca falhou.',
  inventory_consequence_failed = 'Consequencia de inventario falhou.', spawn_timeout = 'Spawn hospitalar expirou.',
  core_transition_failed = 'Transicao canonica falhou.', persistence_pending = 'Persistencia canonica pendente.',
  resource_stopping = 'Resource medico encerrando.', internal_error = 'Falha interna.'
}

local function cfg()
  return Config and Config.Medical or {}
end

local function clone(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = clone(child) end
  return result
end

local function failure(code, extra)
  local result = clone(type(extra) == 'table' and extra or {})
  result.code = code
  result.message = ERROR_MESSAGES[code] or ERROR_MESSAGES.internal_error
  return false, result
end

local function success(data)
  return true, clone(type(data) == 'table' and data or {})
end

local INVENTORY_EXPORTS = {
  ReserveMedicalItem = true,
  CommitMedicalItemReservation = true,
  CancelMedicalItemReservation = true,
  CancelMedicalItemReservationsForResource = true,
  GetMedicalItemReservations = true
}

local ORG_EXPORTS = {
  GetPlayerOrgs = true,
  CanOrg = true
}

local function coreCall(name, ...)
  local args = table.pack(...)
  local ok, a, b = pcall(function()
    local resourceName = INVENTORY_EXPORTS[name] and 'mz_inventory'
      or ORG_EXPORTS[name] and 'mz_org'
      or 'mz_core'
    local resourceExports = exports[resourceName]
    return resourceExports[name](resourceExports, table.unpack(args, 1, args.n))
  end)
  if not ok then return false, { code = 'internal_error', detail = tostring(a) } end
  return a, b
end

local function nowMs()
  if type(GetGameTimer) == 'function' then return GetGameTimer() end
  return math.floor(os.clock() * 1000)
end

local function newId(prefix, source)
  sequence = sequence + 1
  return ('%s-%s-%s-%s'):format(prefix, tostring(source or 0), tostring(os.time()), tostring(sequence))
end

local function randomWord()
  if type(GetRandomIntInRange) == 'function' then
    local ok, value = pcall(GetRandomIntInRange, 0, 2147483647)
    if ok and tonumber(value) then return math.floor(tonumber(value)) end
  end
  return math.random(0, 2147483647)
end

local function newToken()
  return ('%08x%08x%08x%08x'):format(randomWord(), randomWord(), randomWord(), randomWord())
end

local function playerState(source)
  local ok, result = coreCall('GetPlayerState', source)
  if not ok or type(result) ~= 'table' or type(result.state) ~= 'table' then return nil end
  return result.state
end

local function identity(source)
  local ok, result = coreCall('GetPlayerStateIdentity', source)
  if not ok or type(result) ~= 'table' then return nil end
  return result
end

local function validateSession(source, sessionToken, revision)
  local current = identity(source)
  if not current or current.sessionToken ~= sessionToken then return false, 'session_mismatch' end
  if revision ~= nil and tonumber(revision) ~= tonumber(current.revision) then return false, 'revision_mismatch' end
  return true, current
end

local function coordsFor(source)
  if type(GetPlayerPed) ~= 'function' or type(GetEntityCoords) ~= 'function' then return nil end
  local ok, ped = pcall(GetPlayerPed, source)
  if not ok or not ped or ped == 0 then return nil end
  if type(DoesEntityExist) == 'function' then
    local existsOk, exists = pcall(DoesEntityExist, ped)
    if not existsOk or not exists then return nil end
  end
  local coordsOk, coords = pcall(GetEntityCoords, ped)
  if not coordsOk or not coords then return nil end
  return { x = tonumber(coords.x or coords[1]), y = tonumber(coords.y or coords[2]), z = tonumber(coords.z or coords[3]) }
end

local function distance(leftSource, rightSource)
  if type(GetPlayerRoutingBucket) == 'function'
    and GetPlayerRoutingBucket(leftSource) ~= GetPlayerRoutingBucket(rightSource) then return nil, 'routing_bucket' end
  local left, right = coordsFor(leftSource), coordsFor(rightSource)
  if not left or not right or not left.x or not right.x then return nil, 'position_unavailable' end
  local dx, dy, dz = left.x - right.x, left.y - right.y, left.z - right.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function setOperationalBag(source, key, value)
  if type(Player) ~= 'function' then return end
  pcall(function()
    local player = Player(source)
    if player and player.state and type(player.state.set) == 'function' then player.state:set(key, value, true) end
  end)
end

local TELEMETRY_EVENTS = {
  help_requested = 'medical_help_requested',
  treatment_started = 'medical_treatment_started',
  treatment_stopped = 'medical_treatment_cancelled',
  revive_completed = 'medical_treatment_completed',
  item_commit_pending = 'medical_item_commit_pending',
  item_rollback_pending = 'medical_item_rollback_pending',
  respawn_started = 'medical_respawn_started',
  respawn_completed = 'medical_respawn_completed',
  respawn_timeout = 'medical_respawn_aborted',
  respawn_cancelled = 'medical_respawn_aborted',
  respawn_session_cancelled = 'medical_respawn_aborted',
  restart_respawn_recovered = 'medical_operation_recovered',
  admin_recovery = 'medical_operation_recovered',
  inventory_operation_recovered = 'medical_operation_recovered'
}

local function log(action, fields)
  fields = type(fields) == 'table' and fields or {}
  print(('[mz_medical] action=%s operationId=%s executor=%s target=%s result=%s error=%s'):format(
    tostring(action), tostring(fields.operationId or '-'), tostring(fields.executor or '-'),
    tostring(fields.target or fields.source or '-'), tostring(fields.result or '-'), tostring(fields.error or '-')
  ))
  local eventName = TELEMETRY_EVENTS[action]
  if eventName then
    pcall(function()
      exports['mz_core']:RecordPlayerStateEvent(eventName, {
        auditId = fields.auditId,
        operationId = fields.operationId,
        source = tonumber(fields.executor or fields.source),
        target = tonumber(fields.target or fields.source),
        revision = tonumber(fields.revision),
        reason = fields.reason or fields.error or action,
        result = fields.result,
        error = fields.error,
        evidence = fields.evidence
      })
    end)
  end
end

local function scheduleInventoryRetry(operation, errorCode)
  local recovery = cfg().recovery or {}
  operation.inventoryRetryCount = (tonumber(operation.inventoryRetryCount) or 0) + 1
  operation.inventoryRetryError = tostring(errorCode or 'inventory_operation_failed'):sub(1, 96)
  local base = math.max(1, math.floor(tonumber(recovery.backoffBaseSeconds) or 2))
  local maximum = math.max(base, math.floor(tonumber(recovery.backoffMaxSeconds) or 30))
  local delay = math.min(maximum, base * (2 ^ math.max(0, operation.inventoryRetryCount - 1)))
  operation.inventoryRetryAt = os.time() + delay
  return operation.inventoryRetryCount < math.max(1, math.floor(tonumber(recovery.maximumAttempts) or 5))
end

local function retryInventoryOperation(operation, force)
  if not operation or operation.reserved ~= true then return false, 'not_pending' end
  if force ~= true and os.time() < (tonumber(operation.inventoryRetryAt) or 0) then return false, 'backoff' end
  local exportName = operation.effectCommitted == true
    and 'CommitMedicalItemReservation' or 'CancelMedicalItemReservation'
  local ok, result = coreCall(exportName, operation.executorSource, operation.operationId)
  if ok then
    operation.reserved = false
    operation.state = operation.effectCommitted == true and 'completed' or 'rolled_back'
    operation.finishedAt = os.time()
    operation.inventoryRetryAt = nil
    log('inventory_operation_recovered', {
      operationId = operation.operationId, executor = operation.executorSource,
      target = operation.targetSource, result = operation.state
    })
    return true
  end
  local resultCode = type(result) == 'table' and result.code or result
  local retrying = scheduleInventoryRetry(operation, resultCode)
  if not retrying then
    operation.state = operation.effectCommitted == true and 'commit_exhausted' or 'rollback_exhausted'
    operation.finishedAt = os.time()
    pcall(function()
      exports['mz_core']:ReportPlayerStateSuspicion('medical_inventory_recovery_exhausted', operation.executorSource, {
        reason = operation.state,
        error = operation.inventoryRetryError,
        evidence = { operationId = operation.operationId, attempts = operation.inventoryRetryCount }
      })
    end)
  end
  return false, resultCode
end

local function consumeWindow(source, bucket)
  local settings = cfg().rateLimit or {}
  local maximum = math.max(1, math.floor(tonumber(settings.maximumPerWindow) or 12))
  local windowMs = math.max(1000, math.floor((tonumber(settings.windowSeconds) or 10) * 1000))
  local key = ('%s:%s'):format(tostring(source), tostring(bucket))
  local current = nowMs()
  local window = ClientWindows[key]
  if not window or current - window.startedAt >= windowMs then window = { startedAt = current, count = 0 }; ClientWindows[key] = window end
  if window.count >= maximum then return false end
  window.count = window.count + 1
  return true
end

local function medicalAuthorization(source)
  local organizations = coreCall('GetPlayerOrgs', source)
  if type(organizations) ~= 'table' then return false, 'invalid_job' end
  local treatment = cfg().treatment or {}
  for _, allowedCode in ipairs(treatment.allowedOrganizations or {}) do
    for _, organization in ipairs(organizations) do
      if organization.code == allowedCode and organization.active ~= false then
        local level = tonumber(organization.grade and organization.grade.level or organization.gradeLevel) or 0
        local minimum = tonumber(treatment.minimumGrades and treatment.minimumGrades[allowedCode]) or 0
        if level < minimum then return false, 'invalid_job' end
        if treatment.requireDuty == true and organization.duty ~= true then return false, 'not_on_duty' end
        local capability = treatment.requiredCapabilities and treatment.requiredCapabilities[allowedCode]
        if capability then
          local capabilityOk = coreCall('CanOrg', source, allowedCode, capability)
          if capabilityOk ~= true then return false, 'not_authorized' end
        end
        return true, organization
      end
    end
  end
  return false, 'invalid_job'
end

local function deadlineFor(source, state)
  local timestamp = os.time()
  if state.deathState == 'downed' then
    local deadline = state.deathTimestamps and tonumber(state.deathTimestamps.downedExpiresAt)
    if not deadline then
      deadline = timestamp + math.max(1, math.floor(tonumber(cfg().downed and cfg().downed.durationSeconds) or 300))
      local ok = coreCall('SetPlayerDeathDeadline', source, 'downed', deadline, {
        reason = 'medical_downed_deadline', operationId = newId('deadline', source)
      })
      if not ok then return nil end
    end
    return deadline
  end
  if state.deathState == 'dead' then
    local deadline = state.deathTimestamps and tonumber(state.deathTimestamps.respawnAvailableAt)
    if not deadline then
      deadline = timestamp + math.max(0, math.floor(tonumber(cfg().death and cfg().death.respawnDelaySeconds) or 180))
      local ok = coreCall('SetPlayerDeathDeadline', source, 'respawn', deadline, {
        reason = 'medical_respawn_deadline', operationId = newId('deadline', source)
      })
      if not ok then return nil end
    end
    return deadline
  end
  return nil
end

local function clearTreatment(operation, state, reason, rollback)
  if not operation then return false end
  if operation.state == 'completed' or operation.state == 'rolled_back' then return false end
  operation.state = state or 'cancelled'
  operation.finishedAt = os.time()
  TreatmentByExecutor[operation.executorSource] = nil
  TreatmentByTarget[operation.targetSource] = nil
  setOperationalBag(operation.executorSource, 'mz:medicalAction', false)
  setOperationalBag(operation.targetSource, 'mz:beingTreated', false)
  if rollback == true and operation.reserved == true then
    local exportName = operation.effectCommitted == true
      and 'CommitMedicalItemReservation' or 'CancelMedicalItemReservation'
    local ok, result = coreCall(exportName, operation.executorSource, operation.operationId)
    if ok then
      operation.reserved = false
      operation.state = operation.effectCommitted == true and 'completed' or 'rolled_back'
    else
      operation.state = operation.effectCommitted == true and 'completed_inventory_pending' or 'rollback_pending'
      scheduleInventoryRetry(operation, result and result.code or result)
      log(operation.effectCommitted == true and 'item_commit_pending' or 'item_rollback_pending', {
        operationId = operation.operationId, executor = operation.executorSource,
        target = operation.targetSource, result = operation.state,
        error = result and result.code or result,
        evidence = { attempt = operation.inventoryRetryCount }
      })
    end
  end
  TriggerClientEvent('mz_medical:client:operationStopped', operation.executorSource, {
    operationId = operation.operationId, reason = tostring(reason or state or 'cancelled')
  })
  log('treatment_stopped', { operationId = operation.operationId, executor = operation.executorSource, target = operation.targetSource, result = operation.state, error = reason })
  return true
end

function MZMedicalService.ensureDeadline(source)
  local state = playerState(source)
  if not state then return failure('player_not_loaded') end
  if state.deathState == 'respawning' and not Respawns[tonumber(source)] then
    local ok, result = coreCall('AbortPlayerRespawn', source, {
      reason = 'orphaned_respawn_recovery', operationId = newId('orphan-recovery', source)
    })
    if not ok then return failure(result and result.code or 'core_transition_failed') end
    state = playerState(source) or state
    log('restart_respawn_recovered', { source = source, target = source, result = state.deathState })
  end
  return success({ deadline = deadlineFor(source, state), deathState = state.deathState })
end

function MZMedicalService.requestHelp(source, sessionToken)
  if stopping then return failure('resource_stopping') end
  local state = playerState(source)
  if not state then return failure('player_not_loaded') end
  if state.deathState ~= 'downed' and state.deathState ~= 'dead' then return failure('invalid_state') end
  local sessionOk, sessionErr = validateSession(source, sessionToken)
  if not sessionOk then return failure(sessionErr) end
  local settings = cfg().help or {}
  local current = os.time()
  local window = HelpWindows[source]
  if not window or current - window.startedAt >= (tonumber(settings.windowSeconds) or 60) then
    window = { startedAt = current, count = 0, lastAt = 0 }; HelpWindows[source] = window
  end
  if current - window.lastAt < (tonumber(settings.cooldownSeconds) or 30) or window.count >= (tonumber(settings.maximumPerWindow) or 5) then
    return failure('cooldown')
  end
  window.lastAt, window.count = current, window.count + 1
  local coords = coordsFor(source)
  log('help_requested', { source = source, target = source, result = 'accepted' })
  local dispatch = { ok = false, code = 'dispatch_unavailable' }
  if GetResourceState('mz_dispatch') == 'started' then
    local ok, response = pcall(function()
      return exports['mz_dispatch']:CreateMedicalHelpCall(
        source,
        ('medical_%s_%s'):format(tostring(source), tostring(current))
      )
    end)
    if ok and type(response) == 'table' then dispatch = response end
  end
  return success({ accepted = true, coordinatesAvailable = coords ~= nil, dispatch = dispatch })
end

function MZMedicalService.startTreatment(executor, target, sessionToken, revision)
  if stopping then return failure('resource_stopping') end
  executor, target = tonumber(executor), tonumber(target)
  if not executor or not target or target <= 0 then return failure('invalid_target') end
  if executor == target then return failure('same_player') end
  if TreatmentByExecutor[executor] then return failure('operation_in_progress') end
  if TreatmentByTarget[target] then return failure('target_in_treatment') end
  local sessionOk, executorIdentity = validateSession(executor, sessionToken, revision)
  if not sessionOk then return failure(executorIdentity) end
  local executorState, targetState = playerState(executor), playerState(target)
  if not executorState then return failure('player_not_loaded') end
  if not targetState then return failure('target_not_loaded') end
  if executorState.deathState ~= 'alive' then return failure('invalid_state') end
  if targetState.deathState ~= 'downed' then return failure('invalid_state') end
  local targetIdentity = identity(target)
  if not targetIdentity then return failure('target_not_loaded') end
  local authorized, authorizationErr = medicalAuthorization(executor)
  if not authorized then return failure(authorizationErr) end
  local measured = distance(executor, target)
  if not measured or measured > (tonumber(cfg().treatment and cfg().treatment.distance) or 3.0) then return failure('invalid_distance') end
  local cooldownAt = tonumber(TreatmentCooldowns[executor]) or 0
  if os.time() < cooldownAt then return failure('cooldown', { availableAt = cooldownAt }) end

  local operationId = newId('treatment', executor)
  local token = newToken()
  local durationMs = math.max(1000, math.floor(tonumber(cfg().treatment and cfg().treatment.durationMs) or 10000))
  local grace = math.max(5, math.floor(tonumber(cfg().treatment and cfg().treatment.operationGraceSeconds) or 15))
  local operation = {
    operationId = operationId, token = token, executorSource = executor, targetSource = target,
    executorSession = executorIdentity.sessionToken, targetSession = targetIdentity.sessionToken,
    executorRevision = executorIdentity.revision, targetRevision = targetIdentity.revision,
    item = tostring(cfg().treatment and cfg().treatment.item or 'firstaid'),
    startedAtMs = nowMs(), startedAt = os.time(), minimumCompleteAtMs = nowMs() + durationMs,
    expiresAt = os.time() + math.ceil(durationMs / 1000) + grace, state = 'created', reserved = false
  }
  Treatments[operationId] = operation
  TreatmentByExecutor[executor], TreatmentByTarget[target] = operationId, operationId
  local reserveOk, reserveResult = coreCall('ReserveMedicalItem', executor, operation.item, operationId, math.ceil(durationMs / 1000) + grace)
  if not reserveOk then
    clearTreatment(operation, 'failed', reserveResult == 'not_enough_items' and 'item_missing' or 'item_reservation_failed', false)
    return failure(reserveResult == 'not_enough_items' and 'item_missing' or 'item_reservation_failed')
  end
  operation.reserved, operation.state = true, 'presenting'
  setOperationalBag(executor, 'mz:medicalAction', operationId)
  setOperationalBag(target, 'mz:beingTreated', operationId)
  TriggerClientEvent('mz_medical:client:startTreatment', executor, {
    operationId = operationId, token = token, target = target, durationMs = durationMs
  })
  log('treatment_started', { operationId = operationId, executor = executor, target = target, result = 'presenting' })
  return success({ operationId = operationId, state = operation.state, durationMs = durationMs })
end

function MZMedicalService.cancelTreatment(executor, operationId, token, sessionToken, reason)
  local operation = Treatments[tostring(operationId or '')]
  if not operation or operation.executorSource ~= tonumber(executor) then return failure('operation_not_found') end
  if operation.token ~= token or operation.executorSession ~= sessionToken then return failure('session_mismatch') end
  clearTreatment(operation, 'cancelled', reason or 'client_cancelled', true)
  return success({ operationId = operation.operationId, state = operation.state })
end

function MZMedicalService.completeTreatment(executor, operationId, token, sessionToken)
  local operation = Treatments[tostring(operationId or '')]
  if not operation or operation.executorSource ~= tonumber(executor) then return failure('operation_not_found') end
  if operation.state == 'completed' then return failure('operation_already_completed') end
  if operation.token ~= token or operation.executorSession ~= sessionToken then return failure('session_mismatch') end
  if os.time() > operation.expiresAt then clearTreatment(operation, 'expired', 'operation_expired', true); return failure('operation_expired') end
  local tolerance = math.max(0, tonumber(cfg().treatment and cfg().treatment.completionToleranceMs) or 250)
  if nowMs() + tolerance < operation.minimumCompleteAtMs then return failure('timer_not_finished') end
  local executorIdentity, targetIdentity = identity(operation.executorSource), identity(operation.targetSource)
  if not executorIdentity or not targetIdentity or executorIdentity.sessionToken ~= operation.executorSession
    or targetIdentity.sessionToken ~= operation.targetSession then
    clearTreatment(operation, 'cancelled', 'session_mismatch', true); return failure('session_mismatch')
  end
  if tonumber(targetIdentity.revision) ~= tonumber(operation.targetRevision) then
    clearTreatment(operation, 'cancelled', 'revision_mismatch', true); return failure('revision_mismatch')
  end
  local executorState, targetState = playerState(operation.executorSource), playerState(operation.targetSource)
  if not executorState or executorState.deathState ~= 'alive' or not targetState or targetState.deathState ~= 'downed' then
    clearTreatment(operation, 'cancelled', 'invalid_state', true); return failure('invalid_state')
  end
  local measured = distance(operation.executorSource, operation.targetSource)
  if not measured or measured > (tonumber(cfg().treatment and cfg().treatment.finalDistance) or 3.5) then
    clearTreatment(operation, 'cancelled', 'invalid_distance', true); return failure('invalid_distance')
  end

  operation.state = 'transitioning'
  local reviveOk, reviveResult = coreCall('RevivePlayer', operation.targetSource, {
    reason = 'medical_treatment', actorSource = operation.executorSource, item = operation.item,
    operationId = operation.operationId,
    reviveHealth = tonumber(cfg().treatment and cfg().treatment.reviveHealth) or 100,
    reviveArmor = tonumber(cfg().treatment and cfg().treatment.reviveArmor) or 0,
    expectedRevision = operation.targetRevision
  })
  local changedToAlive = reviveResult and reviveResult.state and reviveResult.state.deathState == 'alive'
  if not reviveOk and not (reviveResult and reviveResult.code == 'persistence_pending' and changedToAlive) then
    clearTreatment(operation, 'failed', reviveResult and reviveResult.code or 'core_transition_failed', true)
    return failure(reviveResult and reviveResult.code == 'persistence_pending' and 'persistence_pending' or 'core_transition_failed')
  end
  local commitOk, commitResult = coreCall('CommitMedicalItemReservation', operation.executorSource, operation.operationId)
  operation.effectCommitted = true
  if not commitOk then
    operation.state = 'completed_inventory_pending'
    scheduleInventoryRetry(operation, commitResult and commitResult.code or commitResult)
    log('item_commit_pending', {
      operationId = operation.operationId, executor = operation.executorSource,
      target = operation.targetSource, result = operation.state,
      error = commitResult and commitResult.code or commitResult,
      evidence = { attempt = operation.inventoryRetryCount }
    })
  else
    operation.reserved, operation.state = false, reviveOk and 'completed' or 'completed_persistence_pending'
  end
  TreatmentByExecutor[operation.executorSource], TreatmentByTarget[operation.targetSource] = nil, nil
  operation.finishedAt = os.time()
  setOperationalBag(operation.executorSource, 'mz:medicalAction', false)
  setOperationalBag(operation.targetSource, 'mz:beingTreated', false)
  TreatmentCooldowns[operation.executorSource] = os.time() + math.max(0, tonumber(cfg().treatment and cfg().treatment.cooldownSeconds) or 30)
  log('revive_completed', { operationId = operation.operationId, executor = operation.executorSource, target = operation.targetSource, result = operation.state })
  return success({ operationId = operation.operationId, state = operation.state })
end

local function selectedHospital()
  local settings = cfg().hospital or {}
  for _, hospital in ipairs(settings.hospitals or {}) do
    if hospital.enabled ~= false and hospital.id == settings.defaultId then return hospital end
  end
  for _, hospital in ipairs(settings.hospitals or {}) do if hospital.enabled ~= false then return hospital end end
  return nil
end

function MZMedicalService.requestHospitalRespawn(source, sessionToken, revision)
  if stopping then return failure('resource_stopping') end
  if Respawns[source] then return failure('operation_in_progress') end
  if TreatmentByTarget[source] then return failure('target_in_treatment') end
  local sessionOk, currentIdentity = validateSession(source, sessionToken, revision)
  if not sessionOk then return failure(currentIdentity) end
  local state = playerState(source)
  if not state then return failure('player_not_loaded') end
  if state.deathState ~= 'dead' then return failure('invalid_state') end
  local deadline = deadlineFor(source, state)
  if not deadline or os.time() < deadline then return failure('timer_not_finished', { availableAt = deadline }) end
  local hospital = selectedHospital()
  if not hospital or type(hospital.spawn) ~= 'table' then return failure('respawn_not_available') end

  local operationId, token = newId('respawn', source), newToken()
  local timeout = math.max(10, math.floor(tonumber(cfg().hospital and cfg().hospital.spawnTimeoutSeconds) or 30))
  local operation = {
    operationId = operationId, token = token, source = source, session = currentIdentity.sessionToken,
    revision = currentIdentity.revision, hospital = hospital.id, spawn = clone(hospital.spawn),
    state = 'created', startedAt = os.time(), expiresAt = os.time() + timeout, attempts = 0,
    billing = 'disabled', itemLoss = 'none'
  }
  Respawns[source] = operation
  local beginOk, beginResult = coreCall('BeginPlayerRespawn', source, {
    reason = 'hospital_respawn', operationId = operationId, expectedRevision = currentIdentity.revision
  })
  if not beginOk then Respawns[source] = nil; return failure(beginResult and beginResult.code or 'core_transition_failed') end
  operation.state = 'spawning'
  operation.revision = beginResult.revision
  operation.attempts = 1
  local spawnOk, spawnResult = coreCall('SpawnPlayerForMedical', source, {
    operationId = operationId, token = token,
    x = operation.spawn.x, y = operation.spawn.y, z = operation.spawn.z, heading = operation.spawn.heading
  })
  if not spawnOk then
    coreCall('AbortPlayerRespawn', source, { reason = 'hospital_spawn_dispatch_failed', operationId = operationId })
    Respawns[source] = nil
    return failure('core_transition_failed', { detail = spawnResult })
  end
  log('respawn_started', { operationId = operationId, source = source, target = source, result = 'spawning' })
  return success({ operationId = operationId, state = operation.state, hospital = hospital.id })
end

function MZMedicalService.confirmHospitalSpawn(source, operationId, token)
  local operation = Respawns[tonumber(source)]
  if not operation or operation.operationId ~= operationId then return failure('operation_not_found') end
  if operation.token ~= token then return failure('session_mismatch') end
  if operation.state == 'completed' then return failure('operation_already_completed') end
  if os.time() > operation.expiresAt then return failure('spawn_timeout') end
  local currentIdentity = identity(source)
  if not currentIdentity or currentIdentity.sessionToken ~= operation.session then return failure('session_mismatch') end
  local state = playerState(source)
  if not state or state.deathState ~= 'respawning' then return failure('invalid_state') end
  local completeOk, completeResult = coreCall('CompletePlayerRespawn', source, {
    reason = 'hospital_spawn_ready', operationId = operation.operationId,
    respawnHealth = tonumber(cfg().hospital and cfg().hospital.respawnHealth) or 200,
    respawnArmor = tonumber(cfg().hospital and cfg().hospital.respawnArmor) or 0,
    expectedRevision = operation.revision
  })
  if not completeOk and not (completeResult and completeResult.code == 'persistence_pending'
    and completeResult.state and completeResult.state.deathState == 'alive') then
    return failure(completeResult and completeResult.code or 'core_transition_failed')
  end
  operation.state = completeOk and 'completed' or 'completed_persistence_pending'
  Respawns[source] = nil
  log('respawn_completed', { operationId = operation.operationId, source = source, target = source, result = operation.state })
  return success({ operationId = operation.operationId, state = operation.state })
end

function MZMedicalService.recoverPlayer(source, reason)
  local operationId = Respawns[tonumber(source)] and Respawns[tonumber(source)].operationId or newId('recovery', source)
  if TreatmentByExecutor[source] then clearTreatment(Treatments[TreatmentByExecutor[source]], 'cancelled', reason or 'admin_recovery', true) end
  if TreatmentByTarget[source] then clearTreatment(Treatments[TreatmentByTarget[source]], 'cancelled', reason or 'admin_recovery', true) end
  local state = playerState(source)
  if not state then return failure('player_not_loaded') end
  if state.deathState == 'respawning' then
    local ok, result = coreCall('AbortPlayerRespawn', source, { reason = reason or 'admin_recovery', operationId = operationId })
    if not ok then return failure(result and result.code or 'core_transition_failed') end
  end
  Respawns[source] = nil
  for _, operation in pairs(Treatments) do
    if operation and operation.reserved == true
      and (operation.executorSource == tonumber(source) or operation.targetSource == tonumber(source)) then
      retryInventoryOperation(operation, true)
    end
  end
  log('admin_recovery', { operationId = operationId, source = source, target = source, result = 'recovered' })
  return success({ operationId = operationId, state = 'recovered' })
end

function MZMedicalService.getOperations()
  local result = {}
  for operationId, operation in pairs(Treatments) do
    result[#result + 1] = {
      operationId = operationId,
      executorSource = operation.executorSource,
      targetSource = operation.targetSource,
      item = operation.item,
      state = operation.state,
      reserved = operation.reserved == true,
      effectCommitted = operation.effectCommitted == true,
      retryCount = tonumber(operation.inventoryRetryCount) or 0,
      retryAt = operation.inventoryRetryAt,
      startedAt = operation.startedAt,
      finishedAt = operation.finishedAt
    }
  end
  table.sort(result, function(a, b) return tostring(a.operationId) < tostring(b.operationId) end)
  return result
end

function MZMedicalService.recoverOperation(operationId)
  local operation = Treatments[tostring(operationId or '')]
  if not operation then return failure('operation_not_found') end
  if operation.reserved ~= true then return success({ operationId = operation.operationId, state = operation.state }) end
  local ok, err = retryInventoryOperation(operation, true)
  if not ok then return failure('inventory_consequence_failed', {
    operationId = operation.operationId, state = operation.state, detail = err
  }) end
  return success({ operationId = operation.operationId, state = operation.state })
end

function MZMedicalService.cancelPlayerOperations(source, reason)
  source = tonumber(source)
  if TreatmentByExecutor[source] then clearTreatment(Treatments[TreatmentByExecutor[source]], 'cancelled', reason, true) end
  if TreatmentByTarget[source] then clearTreatment(Treatments[TreatmentByTarget[source]], 'cancelled', reason, true) end
  local respawn = Respawns[source]
  if respawn then
    local state = playerState(source)
    if state and state.deathState == 'respawning' then
      local ok, result = coreCall('AbortPlayerRespawn', source, {
        reason = reason or 'medical_operation_cancelled', operationId = respawn.operationId,
        expectedRevision = respawn.revision
      })
      log('respawn_cancelled', {
        operationId = respawn.operationId, source = source, target = source,
        result = ok and 'dead' or 'abort_failed', error = not ok and result and result.code or nil
      })
    end
    Respawns[source] = nil
  end
  local sourcePrefix = tostring(source) .. ':'
  for key in pairs(ClientWindows) do
    if key:sub(1, #sourcePrefix) == sourcePrefix then ClientWindows[key] = nil end
  end
  HelpWindows[source], TreatmentCooldowns[source] = nil, nil
end

function MZMedicalService.tick()
  if stopping or cfg().enabled == false then return { players = 0, operations = 0 } end
  local sources = type(GetPlayers) == 'function' and GetPlayers() or {}
  local maximumPlayers = math.max(1, math.floor(tonumber(cfg().scheduler and cfg().scheduler.maximumPlayersPerTick) or 64))
  local processed = 0
  for _, rawSource in ipairs(sources) do
    if processed >= maximumPlayers then break end
    local source = tonumber(rawSource)
    local state = source and playerState(source) or nil
    if state and (state.deathState == 'downed' or state.deathState == 'dead') then
      local deadline = deadlineFor(source, state)
      if state.deathState == 'downed' and deadline and os.time() >= deadline then
        local ok, result = coreCall('MarkPlayerDead', source, {
          reason = 'downed_timer_expired', operationId = ('downed-expiry:%s:%s'):format(source, deadline),
          expectedRevision = state.revision
        })
        log('downed_expired', { source = source, target = source, result = ok and 'dead' or 'failed', error = result and result.code })
      end
    end
    processed = processed + 1
  end

  local maximumOperations = math.max(1, math.floor(tonumber(cfg().scheduler and cfg().scheduler.maximumOperationsPerTick) or 64))
  local operationIds = {}
  for operationId in pairs(Treatments) do operationIds[#operationIds + 1] = operationId end
  table.sort(operationIds)
  for index = 1, math.min(#operationIds, maximumOperations) do
    local operation = Treatments[operationIds[index]]
    if operation and (operation.state == 'presenting' or operation.state == 'created') then
      if os.time() > operation.expiresAt then clearTreatment(operation, 'expired', 'operation_expired', true)
      else
        local executorIdentity, targetIdentity = identity(operation.executorSource), identity(operation.targetSource)
        if not executorIdentity or not targetIdentity or executorIdentity.sessionToken ~= operation.executorSession
          or targetIdentity.sessionToken ~= operation.targetSession then
          clearTreatment(operation, 'cancelled', 'session_mismatch', true)
        else
          local measured = distance(operation.executorSource, operation.targetSource)
          if not measured or measured > (tonumber(cfg().treatment and cfg().treatment.finalDistance) or 3.5) then
            clearTreatment(operation, 'cancelled', 'invalid_distance', true)
          end
        end
      end
    elseif operation and (operation.state == 'completed_inventory_pending' or operation.state == 'rollback_pending')
      and operation.reserved == true then
      retryInventoryOperation(operation, false)
    elseif operation and operation.finishedAt and os.time() - operation.finishedAt > 300 then
      local retention = math.max(300, math.floor(tonumber(cfg().recovery and cfg().recovery.terminalRetentionSeconds) or 900))
      if operation.reserved ~= true and os.time() - operation.finishedAt > retention then
        Treatments[operation.operationId] = nil
      end
    end
  end

  for source, operation in pairs(Respawns) do
    local currentIdentity = identity(source)
    if not currentIdentity or currentIdentity.sessionToken ~= operation.session then
      local state = playerState(source)
      if state and state.deathState == 'respawning' then
        coreCall('AbortPlayerRespawn', source, { reason = 'respawn_session_mismatch', operationId = operation.operationId })
      end
      Respawns[source] = nil
      log('respawn_session_cancelled', { operationId = operation.operationId, source = source, target = source, result = 'aborted', error = 'session_mismatch' })
    elseif os.time() > operation.expiresAt then
      local state = playerState(source)
      if state and state.deathState == 'respawning' then
        coreCall('AbortPlayerRespawn', source, { reason = 'hospital_spawn_timeout', operationId = operation.operationId })
      end
      Respawns[source] = nil
      TriggerClientEvent('mz_medical:client:respawnFailed', source, { code = 'spawn_timeout' })
      log('respawn_timeout', { operationId = operation.operationId, source = source, target = source, result = 'aborted', error = 'spawn_timeout' })
    end
  end
  return { players = processed, operations = math.min(#operationIds, maximumOperations) }
end

function MZMedicalService.setStopping(value)
  stopping = value == true
end

function MZMedicalService.resetForStart()
  stopping = false
  coreCall('CancelMedicalItemReservationsForResource')
end

function MZMedicalService.stop()
  stopping = true
  local ids = {}
  for operationId in pairs(Treatments) do ids[#ids + 1] = operationId end
  for _, operationId in ipairs(ids) do clearTreatment(Treatments[operationId], 'cancelled', 'resource_stopping', true) end
  local respawnSources = {}
  for source in pairs(Respawns) do respawnSources[#respawnSources + 1] = source end
  for _, source in ipairs(respawnSources) do MZMedicalService.cancelPlayerOperations(source, 'resource_stopping') end
end

function MZMedicalService.consumeClientAttempt(source, bucket)
  return consumeWindow(source, bucket)
end

MZMedicalService.ERROR_MESSAGES = ERROR_MESSAGES

if rawget(_G, 'MZ_MEDICAL_TESTING') == true then
  MZMedicalService._test = {
    treatments = Treatments, respawns = Respawns, treatmentByExecutor = TreatmentByExecutor,
    treatmentByTarget = TreatmentByTarget, deadlineFor = deadlineFor, clearTreatment = clearTreatment,
    reset = function()
      Treatments, TreatmentByExecutor, TreatmentByTarget, Respawns = {}, {}, {}, {}
      ClientWindows, HelpWindows, TreatmentCooldowns = {}, {}, {}
      stopping = false
    end
  }
end
