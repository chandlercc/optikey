<#
.SYNOPSIS
    Build all OptiKey variants and installers without signing.

.DESCRIPTION
    Replicates the GitHub Actions release workflow (build apps -> build installers)
    but skips signing entirely. Produces unsigned EXE bootstrappers in
    installer/SetupFiles/. Compatible with Windows PowerShell 5.1+.

.PARAMETER Variants
    Which variants to build. Defaults to all four.
    Example: -Variants Pro,Chat

.PARAMETER SkipAppBuild
    Skip the MSBuild step (useful if app binaries already exist).

.PARAMETER SkipInstallerBuild
    Skip the Advanced Installer step (just verify existing output).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-unsigned.ps1
    powershell -ExecutionPolicy Bypass -File .\build-unsigned.ps1 -Variants Pro
    powershell -ExecutionPolicy Bypass -File .\build-unsigned.ps1 -SkipAppBuild
#>

[CmdletBinding()]
param(
    [ValidateSet('Pro','Chat','Mouse','Symbol')]
    [string[]] $Variants = @('Pro','Chat','Mouse','Symbol'),

    [switch] $SkipAppBuild,
    [switch] $SkipInstallerBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
$LogFile   = Join-Path $PSScriptRoot "build-unsigned.log"
$StartTime = Get-Date

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Write-Section {
    param([string]$Title)
    $bar = '=' * 60
    Write-Log $bar
    Write-Log "  $Title"
    Write-Log $bar
}

function Invoke-Logged {
    param([string]$Description, [scriptblock]$Block)
    Write-Log "START: $Description"
    try {
        & $Block
        Write-Log "OK:    $Description"
    } catch {
        Write-Log "FAIL:  $Description -- $_" 'ERROR'
        throw
    }
}

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------
"" | Set-Content $LogFile
Write-Section "OptiKey Unsigned Build -- $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Log "Variants          : $($Variants -join ', ')"
Write-Log "Repo root         : $PSScriptRoot"
Write-Log "Log file          : $LogFile"
Write-Log "SkipAppBuild      : $SkipAppBuild"
Write-Log "SkipInstallerBuild: $SkipInstallerBuild"

# ---------------------------------------------------------------------------
# Resolve tool paths
# ---------------------------------------------------------------------------
Write-Section "Locating Tools"

# MSBuild -- try vswhere first, fall back to PATH
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$msbuild = 'msbuild'
if (Test-Path $vswhere) {
    $found = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null
    if ($found) { $msbuild = $found | Select-Object -Last 1 }
}
Write-Log "MSBuild    : $msbuild"

# NuGet
$nugetCmd = Get-Command nuget -ErrorAction SilentlyContinue
$nuget = if ($nugetCmd) { $nugetCmd.Source } else { 'nuget' }
Write-Log "NuGet      : $nuget"

# Advanced Installer
$aiCmd = Get-Command AdvancedInstaller.com -ErrorAction SilentlyContinue
$aiExe = if ($aiCmd) { $aiCmd.Source } else { $null }
if (-not $aiExe) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Caphyon\Advanced Installer *\bin\x86\AdvancedInstaller.com",
        "${env:ProgramFiles}\Caphyon\Advanced Installer *\bin\x86\AdvancedInstaller.com"
    )
    foreach ($c in $candidates) {
        $found = Resolve-Path $c -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($found) { $aiExe = $found.Path; break }
    }
}
if (-not $aiExe) {
    Write-Log "AdvancedInstaller.com not found. Install it or add it to PATH." 'ERROR'
    exit 1
}
Write-Log "AdvInst    : $aiExe"

# ---------------------------------------------------------------------------
# Variant map
# ---------------------------------------------------------------------------
$VariantMap = @{
    Pro    = @{
        AppSrc = "src\JuliusSweetland.OptiKey.Pro\bin\x64\Release\OptikeyPro.exe"
        AIP    = "installer\OptiKeyPro.aip"
        Out    = "installer\SetupFiles\OptiKeyPro.exe"
    }
    Chat   = @{
        AppSrc = "src\JuliusSweetland.OptiKey.Chat\bin\x64\Release\OptikeyChat.exe"
        AIP    = "installer\OptiKeyChat.aip"
        Out    = "installer\SetupFiles\OptiKeyChat.exe"
    }
    Mouse  = @{
        AppSrc = "src\JuliusSweetland.OptiKey.Mouse\bin\x64\Release\OptikeyMouse.exe"
        AIP    = "installer\OptiKeyMouse.aip"
        Out    = "installer\SetupFiles\OptiKeyMouse.exe"
    }
    Symbol = @{
        AppSrc = "src\JuliusSweetland.OptiKey.Symbol\bin\x64\Release\OptikeySymbol.exe"
        AIP    = "installer\OptiKeySymbol.aip"
        Out    = "installer\SetupFiles\OptiKeySymbol.exe"
    }
}

# ---------------------------------------------------------------------------
# Stage 1 -- Build application binaries
# ---------------------------------------------------------------------------
if (-not $SkipAppBuild) {
    Write-Section "Stage 1: Build Application Binaries (unsigned)"

    Invoke-Logged "NuGet restore" {
        & $nuget restore "OptiKeyDeployment.sln" -NonInteractive
        if ($LASTEXITCODE -ne 0) { throw "nuget restore failed (exit $LASTEXITCODE)" }
    }

    Invoke-Logged "MSBuild -- Release x64" {
        & $msbuild "OptiKeyDeployment.sln" /m /t:Rebuild `
            /p:Configuration=Release /p:Platform=x64 `
            "/flp:LogFile=$LogFile;Append=true;Verbosity=normal"
        if ($LASTEXITCODE -ne 0) { throw "MSBuild failed (exit $LASTEXITCODE)" }
    }

    Write-Log "Checking app binaries:"
    foreach ($v in $Variants) {
        $path = Join-Path $PSScriptRoot $VariantMap[$v].AppSrc
        if (Test-Path $path) {
            $info = Get-Item $path
            $sig  = Get-AuthenticodeSignature $path
            Write-Log ("  [{0}] {1}  size={2}KB  sig={3}" -f $v, $info.Name, [math]::Round($info.Length/1KB), $sig.Status)
        } else {
            Write-Log "  [$v] MISSING: $path" 'WARN'
        }
    }
} else {
    Write-Log "(SkipAppBuild -- skipping Stage 1)"
}

# ---------------------------------------------------------------------------
# Stage 2 -- Build installers
# ---------------------------------------------------------------------------
if (-not $SkipInstallerBuild) {
    Write-Section "Stage 2: Build Installers (unsigned)"

    if ($env:ADVINST_LICENSE_KEY) {
        Invoke-Logged "Activate Advanced Installer licence" {
            & $aiExe /register $env:ADVINST_LICENSE_KEY
            if ($LASTEXITCODE -ne 0) { throw "Licence activation failed (exit $LASTEXITCODE)" }
        }
    }

    $repoPath = Join-Path $PSScriptRoot "installer"
    Invoke-Logged "Set AI repository path -> $repoPath" {
        & $aiExe /SetRepositoryPath "$repoPath"
        if ($LASTEXITCODE -ne 0) { throw "SetRepositoryPath failed (exit $LASTEXITCODE)" }
    }

    foreach ($v in $Variants) {
        $aip = Join-Path $PSScriptRoot $VariantMap[$v].AIP
        Invoke-Logged "Build installer: $v  ($aip)" {
            & $aiExe /build "$aip"
            if ($LASTEXITCODE -ne 0) { throw "AI build failed for $v (exit $LASTEXITCODE)" }
        }
    }
} else {
    Write-Log "(SkipInstallerBuild -- skipping Stage 2)"
}

# ---------------------------------------------------------------------------
# Results summary
# ---------------------------------------------------------------------------
Write-Section "Build Results"

$allOk = $true
foreach ($v in $Variants) {
    $outPath = Join-Path $PSScriptRoot $VariantMap[$v].Out
    if (Test-Path $outPath) {
        $info = Get-Item $outPath
        $sig  = Get-AuthenticodeSignature $outPath
        Write-Log ("  [OK]   {0} -- {1}  size={2}MB  modified={3}  sig={4}" -f `
            $v, $info.Name, [math]::Round($info.Length/1MB,1), $info.LastWriteTime.ToString('HH:mm:ss'), $sig.Status)
    } else {
        Write-Log "  [MISS] $v -- expected output not found: $outPath" 'WARN'
        $allOk = $false
    }
}

# Also list everything in SetupFiles so we can see if an MSI is produced too
$setupFiles = Join-Path $PSScriptRoot "installer\SetupFiles"
if (Test-Path $setupFiles) {
    Write-Log ""
    Write-Log "All files in installer\SetupFiles:"
    Get-ChildItem $setupFiles | ForEach-Object {
        Write-Log ("  {0,-40} {1,8}KB  {2}" -f $_.Name, [math]::Round($_.Length/1KB), $_.LastWriteTime.ToString('HH:mm:ss'))
    }
}

$elapsed = [math]::Round(((Get-Date) - $StartTime).TotalSeconds)
Write-Section "Done in ${elapsed}s -- log saved to build-unsigned.log"

if (-not $allOk) {
    Write-Log "One or more outputs are missing -- check the log above." 'WARN'
    exit 1
}
