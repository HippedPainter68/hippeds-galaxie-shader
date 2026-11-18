# Starts a second Horizon without a window, in its own scratch folders, with the galaxy_sky pack from this
# folder, so the pack can be looked at without touching the player's game, worlds or settings.
#
#   . .\test-rig.ps1          start it (dot-source, so the C function stays)
#   C command "/time set midnight"
#   C tp 200 119 530 ; C look 20 35
#   C screenshot "$Rig\shots\a.png"
#   C quit
#
# The pack folder is watched: a saved .wgsl file is live in the test game within a second.
param([string]$Rig = "$env:TEMP\galaxy-sky-rig")

$launcher = "$env:APPDATA\horizon-launcher"
$game = (Get-ChildItem "$launcher\run" -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName + "\game"
$resources = (Get-ChildItem "$launcher\versions" -Directory -Filter "nightly-*" | Sort-Object Name -Descending | Select-Object -First 1).FullName + "\.local\horizon-client\26.3"
$ctl = "$game\horizon-ctl.exe"

New-Item -ItemType Directory -Force "$Rig\game", "$Rig\home", "$Rig\lhome", "$Rig\shots" | Out-Null
# Dynamic lights on, as in the player's game.
[IO.File]::WriteAllText("$Rig\game\horizon-extras.txt", "dynamicLights:true`n")
$env:HORIZON_HOME = "$Rig\home"
$env:HORIZON_LAUNCHER_HOME = "$Rig\lhome"
$env:HORIZON_LAUNCHER_NO_SELF_UPDATE = "1"
$env:HORIZON_NO_AUDIO = "1"
$env:HORIZON_SHADER_PACK = "$PSScriptRoot\galaxy_sky"

function C { & $ctl --socket "$Rig\ctl.sock" @args }

Push-Location "$Rig\game"
C launch --world T --seed 7 --creative --offscreen --wait --game "$game\horizon-client.exe" --resources $resources --game-dir "$Rig\game" | Out-Null
Pop-Location
C wait-ready 120 | Out-Null
"Test game ready. Screenshots go to $Rig\shots"
