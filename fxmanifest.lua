fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_medical'
author 'Mazus'
description 'Server-authoritative medical flow for MZ player state'
version '1.0.0'

shared_scripts {
  '@ox_lib/init.lua',
  'config.lua'
}

server_scripts {
  'server/service.lua',
  'server/main.lua'
}

client_scripts {
  'client/main.lua'
}

dependencies {
  'ox_lib',
  'mz_core',
  'mz_org',
  'mz_inventory',
  'mz_progress',
  'spawnmanager'
}
