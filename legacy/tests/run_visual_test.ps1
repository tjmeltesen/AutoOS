# AutoOS — run Lua visual smoke test (no admin required)
$Lua = "C:\Lua\lua55.exe"
$Script = Join-Path $PSScriptRoot "lua_visual_test.lua"

if (-not (Test-Path $Lua)) {
  Write-Host "Lua not found at $Lua" -ForegroundColor Red
  Write-Host "Install Lua 5.5 to C:\Lua or edit `$Lua in this script."
  exit 1
}

if (-not (Test-Path $Script)) {
  Write-Host "Test script not found: $Script" -ForegroundColor Red
  exit 1
}

& $Lua $Script
exit $LASTEXITCODE
