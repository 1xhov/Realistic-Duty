fx_version 'cerulean'
game 'gta5'

-- Specify Lua version
lua54 'yes'

-- Resource metadata
name 'realistic Duty'
description 'A bodycam UI with persistent settings'
author 'Realpatt x Kmoc'
version '1.0.0'

-- Ensure these resources start before this one so exports (ox_target / ox_lib) are available
-- Note: ox_target and ox_lib are optional dependencies. If you have them installed,
-- add `ensure ox_target` and `ensure ox_lib` to your server.cfg to load them before this resource.
-- We don't declare hard dependencies here to allow the resource to start on standalone servers without them.

-- Client-side scripts
client_scripts {
    'client.lua',
    'leotargets.lua'
}

-- Server-side scripts
server_scripts {
    'server.lua'
}

-- HTML, CSS, and JS for the NUI
-- NUI files are in the resource root in this package
ui_page 'bodycam.html'

files {
    'bodycam.html',
    'postal.js',
    'postals.json',
    'logo.png',       -- Make sure this path is correct
    'bodycam_on.wav'  -- Make sure this path is correct
}