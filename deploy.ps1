# AutoOS Deploy Script
# Downloads the latest CI artifact and deploys to the PrismLauncher game directory.
# Run this after CI passes on main.
#
# Usage:
#   .\deploy.ps1                  # Deploy latest from GitHub Actions
#   .\deploy.ps1 -LocalBuild      # Deploy from local project files (skip download)

param(
    [switch]$LocalBuild,
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"

# Paths
$ProjectRoot = "C:\Users\tjmel\OneDrive\Documents\Cursor_proj\AutoOS"
$GameHome = "C:\Users\tjmel\AppData\Roaming\PrismLauncher\instances\GT_New_Horizons_2.8.4_Java_17-25\.minecraft\saves\AutoOS\opencomputers\0f6fe1af-265f-4dcf-be91-d707dc877e0d\home"

# Ensure game directory exists
if (-not (Test-Path $GameHome)) {
    Write-Error "Game directory not found: $GameHome"
    Write-Error "Is PrismLauncher installed and the GTNH instance created?"
    exit 1
}

$TempDir = "$env:TEMP\autos-deploy-$PID"
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

try {
    if ($LocalBuild) {
        Write-Host "[AutoOS Deploy] Using local project files..." -ForegroundColor Cyan
        $SourceDir = $ProjectRoot
    }
    else {
        Write-Host "[AutoOS Deploy] Downloading latest CI artifact..." -ForegroundColor Cyan

        # Check for gh CLI
        $gh = Get-Command gh -ErrorAction SilentlyContinue
        if (-not $gh) {
            Write-Warning "GitHub CLI (gh) not found. Falling back to local build."
            Write-Host "Install gh: winget install --id GitHub.cli" -ForegroundColor Yellow
            $LocalBuild = $true
            $SourceDir = $ProjectRoot
        }
        else {
            # Get latest workflow run ID (CI workflow, main branch, success)
            $runId = (gh run list --workflow ci.yml --branch main --status success --limit 1 --json databaseId --jq '.[0].databaseId') 2>$null
            if (-not $runId) {
                Write-Warning "No successful CI run found. Falling back to local build."
                $LocalBuild = $true
                $SourceDir = $ProjectRoot
            }
            else {
                Write-Host "  Latest passing run: $runId" -ForegroundColor Gray
                gh run download $runId --name autos-release --dir $TempDir 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not download artifact. Falling back to local build."
                    $LocalBuild = $true
                    $SourceDir = $ProjectRoot
                }
                else {
                    $SourceDir = $TempDir
                }
            }
        }
    }

    # Deploy: copy broker files
    Write-Host "[AutoOS Deploy] Copying files to game directory..." -ForegroundColor Cyan

    $BrokerSrc = if ($LocalBuild) { "$SourceDir\subnet_broker" } else { (Get-ChildItem -Path $SourceDir -Directory | Where-Object { $_.Name -like "*broker*" }).FullName }
    $OrchSrc = if ($LocalBuild) { "$SourceDir\orchestrator" } else { (Get-ChildItem -Path $SourceDir -Directory | Where-Object { $_.Name -like "*orchestrator*" }).FullName }
    $SharedSrc = if ($LocalBuild) { "$SourceDir\shared" } else { (Get-ChildItem -Path $SourceDir -Directory | Where-Object { $_.Name -like "*shared*" }).FullName }

    # Copy broker modules
    $BrokerDest = "$GameHome\subnet_broker"
    New-Item -ItemType Directory -Force -Path $BrokerDest | Out-Null
    if ($BrokerSrc -and (Test-Path $BrokerSrc)) {
        Copy-Item -Path "$BrokerSrc\*.lua" -Destination $BrokerDest -Force
        Write-Host "  subnet_broker -> $BrokerDest" -ForegroundColor Green
    }

    # Copy orchestrator modules
    $OrchDest = "$GameHome\orchestrator"
    New-Item -ItemType Directory -Force -Path $OrchDest | Out-Null
    if ($OrchSrc -and (Test-Path $OrchSrc)) {
        Copy-Item -Path "$OrchSrc\*.lua" -Destination $OrchDest -Force
        Write-Host "  orchestrator -> $OrchDest" -ForegroundColor Green
    }

    # Copy shared modules
    if ($SharedSrc -and (Test-Path $SharedSrc)) {
        Copy-Item -Path "$SharedSrc\*.lua" -Destination $BrokerDest -Force
        Copy-Item -Path "$SharedSrc\*.lua" -Destination $OrchDest -Force
        Write-Host "  shared -> both broker and orchestrator dirs" -ForegroundColor Green
    }

    # Copy installer if present
    $Installer = "$SourceDir\installer.lua"
    if (Test-Path $Installer) {
        Copy-Item -Path $Installer -Destination $GameHome -Force
        Write-Host "  installer.lua -> $GameHome" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "[AutoOS Deploy] Done. Files deployed to:" -ForegroundColor Green
    Write-Host "  $GameHome" -ForegroundColor White
    Write-Host ""
    Write-Host "Next: Start Minecraft, boot the OC computer, and run the broker/orchestrator." -ForegroundColor Gray
}
finally {
    # Cleanup temp
    if (Test-Path $TempDir) {
        Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
    }
}
