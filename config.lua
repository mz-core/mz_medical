Config = Config or {}

Config.Medical = {
  enabled = true,
  scheduler = {
    intervalMs = 1000,
    maximumPlayersPerTick = 64,
    maximumOperationsPerTick = 64
  },
  recovery = {
    maximumAttempts = 5,
    backoffBaseSeconds = 2,
    backoffMaxSeconds = 30,
    terminalRetentionSeconds = 900
  },
  downed = {
    enabled = true,
    durationSeconds = 300,
    persistTimer = true,
    animation = {
      dictionary = 'combat@damage@writhe',
      clip = 'writhe_loop',
      flag = 1,
      loadTimeoutMs = 5000,
      reapplyIntervalMs = 1500
    }
  },
  death = {
    respawnDelaySeconds = 180,
    allowPlayerRevive = false
  },
  help = {
    enabled = true,
    key = 74,
    cooldownSeconds = 30,
    maximumPerWindow = 5,
    windowSeconds = 60
  },
  treatment = {
    enabled = true,
    command = 'treat',
    candidateRadius = 5.0,
    distance = 3.0,
    finalDistance = 3.5,
    durationMs = 10000,
    completionToleranceMs = 250,
    operationGraceSeconds = 15,
    cooldownSeconds = 30,
    item = 'firstaid',
    allowedOrganizations = { 'ambulance' },
    minimumGrades = { ambulance = 2 },
    requiredCapabilities = { ambulance = 'ambulance.revive.basic' },
    requireDuty = true,
    reviveHealth = 100,
    reviveArmor = 0
  },
  hospital = {
    enabled = true,
    defaultId = 'pillbox',
    hospitals = {
      {
        id = 'pillbox',
        label = 'Pillbox Hospital',
        enabled = true,
        -- Entrada de alta/recepcao do Pillbox correspondente ao IPL local pillbox_hospital.
        spawn = { x = 298.71, y = -584.98, z = 43.26, heading = 68.0 }
      }
    },
    spawnTimeoutSeconds = 30,
    respawnHealth = 200,
    respawnArmor = 0,
    billing = {
      enabled = false,
      fee = 500,
      policy = 'free'
    },
    itemLoss = {
      mode = 'none'
    }
  },
  voice = {
    allowWhileDowned = true,
    deadPolicy = 'unchanged'
  },
  staging = {
    enabled = false,
    ace = 'mz_medical.staging'
  },
  administration = {
    allowedResource = 'mz_admin',
    readResources = { 'mz_admin' },
    recoveryResources = { 'mz_admin' }
  },
  rateLimit = {
    maximumPerWindow = 12,
    windowSeconds = 10
  }
}
