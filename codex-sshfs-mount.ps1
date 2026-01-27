param(
  [string]$SettingsPath = $env:VSCODE_SETTINGS,
  [string]$Select = '',
  [switch]$Force,
  [switch]$Unmount,
  [int]$Interval = 15,
  [int]$Count = 3,
  [string]$DriveLetter = '',
  [switch]$DryRun,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Die([string]$Message) {
  Write-Error $Message
  exit 1
}

function Usage() {
@'
Usage: powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 [options]

Reads SSH FS configs from VS Code settings.json (sshfs.configs), lets you pick a host, and mounts it via
SSHFS-Win (WinFsp) into a folder next to this script (.\<host-name>\).

Options:
  -SettingsPath PATH       Path to VS Code settings.json (JSON/JSONC). Auto-detected if omitted.
  -Select NAME|NUMBER      Non-interactive selection (match by name, or 1-based index).
  -Force                   If already mounted, unmount first.
  -Unmount                 Unmount selected host (no mount).
  -Interval SECONDS        SSH keepalive interval (default: 15).
  -Count N                 SSH keepalive max missed (default: 3).
  -DriveLetter X           Prefer drive letter (e.g. Z). If omitted, auto-pick when needed.
  -DryRun                  Print sshfs command and exit.
  -Help                    Show help.

Environment:
  VSCODE_SETTINGS          Same as -SettingsPath.
  SSHFS_EXTRA_OPTS         Extra sshfs -o options (comma-separated), appended to defaults.
'@ | Write-Host
}

if ($Help) { Usage; exit 0 }

function Get-DefaultSettingsPath {
  $appData = $env:APPDATA
  if (-not $appData) { return $null }
  $candidates = @(
    (Join-Path $appData 'Code\User\settings.json'),
    (Join-Path $appData 'Code - Insiders\User\settings.json'),
    (Join-Path $appData 'VSCodium\User\settings.json')
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Strip-Jsonc([string]$Text) {
  # Removes // and /* */ comments while respecting JSON strings.
  $out = New-Object System.Text.StringBuilder
  $inString = $false
  $escape = $false
  $inLineComment = $false
  $inBlockComment = $false

  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    $next = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

    if ($inLineComment) {
      if ($ch -eq "`n") { $inLineComment = $false; [void]$out.Append($ch) }
      continue
    }
    if ($inBlockComment) {
      if ($ch -eq '*' -and $next -eq '/') { $inBlockComment = $false; $i++ }
      continue
    }

    if ($inString) {
      [void]$out.Append($ch)
      if ($escape) { $escape = $false; continue }
      if ($ch -eq '\') { $escape = $true; continue }
      if ($ch -eq '"') { $inString = $false }
      continue
    }

    if ($ch -eq '"') { $inString = $true; [void]$out.Append($ch); continue }
    if ($ch -eq '/' -and $next -eq '/') { $inLineComment = $true; $i++; continue }
    if ($ch -eq '/' -and $next -eq '*') { $inBlockComment = $true; $i++; continue }

    [void]$out.Append($ch)
  }

  $noComments = $out.ToString()

  # Remove trailing commas before } or ] while respecting strings.
  $out2 = New-Object System.Text.StringBuilder
  $inString = $false
  $escape = $false
  for ($i = 0; $i -lt $noComments.Length; $i++) {
    $ch = $noComments[$i]
    if ($inString) {
      [void]$out2.Append($ch)
      if ($escape) { $escape = $false; continue }
      if ($ch -eq '\') { $escape = $true; continue }
      if ($ch -eq '"') { $inString = $false }
      continue
    }
    if ($ch -eq '"') { $inString = $true; [void]$out2.Append($ch); continue }

    if ($ch -eq ',') {
      $j = $i + 1
      while ($j -lt $noComments.Length -and $noComments[$j] -match '\s') { $j++ }
      if ($j -lt $noComments.Length -and ($noComments[$j] -eq '}' -or $noComments[$j] -eq ']')) {
        continue
      }
    }

    [void]$out2.Append($ch)
  }

  return $out2.ToString()
}

function Load-Jsonc([string]$Path) {
  $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  $clean = Strip-Jsonc $raw
  return $clean | ConvertFrom-Json
}

function Ensure-Dependencies {
  $sshfs = Get-Command sshfs -ErrorAction SilentlyContinue
  if ($sshfs) { return }

  Write-Host "sshfs not found in PATH (Windows needs WinFsp + SSHFS-Win)."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "Install (recommended):"
    Write-Host "  winget install WinFsp.WinFsp"
    Write-Host "  winget install SSHFS-Win.SSHFS-Win"
  } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Host "Install (Chocolatey):"
    Write-Host "  choco install -y winfsp sshfs-win"
  } else {
    Write-Host "Install:"
    Write-Host "  1) WinFsp"
    Write-Host "  2) SSHFS-Win"
    Write-Host "Then ensure 'sshfs.exe' is in PATH and re-run."
  }

  if ($DryRun) {
    Write-Warning "sshfs is not installed; continuing because -DryRun was used."
    return
  }
  Die "sshfs is required"
}

function Safe-Name([string]$Name) {
  if (-not $Name) { return 'sshfs-mount' }
  $s = $Name -replace '\s+', '_' -replace '[\\/]+', '_'
  $s = -join ($s.ToCharArray() | Where-Object { $_ -match '[A-Za-z0-9._-]' })
  if (-not $s) { return 'sshfs-mount' }
  return $s
}

function Get-FreeDriveLetter {
  $used = (Get-PSDrive -PSProvider FileSystem).Name
  foreach ($c in [char[]]([char]'Z'..[char]'D')) {
    if ($used -notcontains $c) { return $c }
  }
  return $null
}

function Test-IsJunction([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
  } catch {
    return $false
  }
}

function Remove-JunctionOrDir([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    if (Test-IsJunction $Path) {
      cmd /c "rmdir ""$Path""" | Out-Null
    } else {
      Remove-Item -LiteralPath $Path -Recurse -Force
    }
  }
}

function Is-Mounted([string]$MountDir, [string]$DriveLetter) {
  if ($DriveLetter) {
    return (Test-Path -LiteralPath ($DriveLetter + ':\'))
  }
  # Best-effort: if dir is a junction to a live target, treat as mounted
  if (Test-IsJunction $MountDir) {
    try { (Get-Item -LiteralPath $MountDir -Force) | Out-Null; return $true } catch { return $false }
  }
  return $false
}

Ensure-Dependencies

if (-not $SettingsPath) { $SettingsPath = Get-DefaultSettingsPath }
if (-not $SettingsPath) { Die "could not find VS Code settings.json (set VSCODE_SETTINGS or pass -SettingsPath)" }
if (-not (Test-Path -LiteralPath $SettingsPath)) { Die "settings.json not found: $SettingsPath" }

$settingsDir = Split-Path -Parent $SettingsPath
$settings = Load-Jsonc $SettingsPath

$configs = @()
if ($settings.'sshfs.configs') { $configs += @($settings.'sshfs.configs') }

if ($settings.'sshfs.configpaths') {
  foreach ($p in @($settings.'sshfs.configpaths')) {
    if (-not $p) { continue }
    $p2 = [Environment]::ExpandEnvironmentVariables([string]$p)
    if (-not ([IO.Path]::IsPathRooted($p2))) { $p2 = Join-Path $settingsDir $p2 }
    if (Test-Path -LiteralPath $p2) {
      $extra = Load-Jsonc $p2
      if ($extra -and $extra.PSObject.Properties.Match('sshfs.configs').Count -gt 0) {
        $configs += @($extra.'sshfs.configs')
      } elseif ($extra -is [System.Array]) {
        $configs += @($extra)
      }
    }
  }
}

$configs = @($configs | Where-Object { $_ -and $_.host })
if ($configs.Count -eq 0) { Die "no sshfs.configs found in $SettingsPath" }

function Get-Display($cfg) {
  $name = if ($cfg.name) { [string]$cfg.name } else { [string]$cfg.host }
  $host = [string]$cfg.host
  $user = if ($cfg.username) { [string]$cfg.username } else { '' }
  $port = if ($cfg.port) { [string]$cfg.port } else { '' }
  $root = if ($cfg.root) { [string]$cfg.root } else { '' }

  $summary = ''
  if ($user -and $host) { $summary = "$user@$host" } else { $summary = $host }
  if ($port) { $summary = "$summary`:$port" }
  if ($root) { $summary = "$summary $root" }
  if ($summary) { return "$name ($summary)" }
  return $name
}

function Pick-Index {
  if ($Select) {
    if ($Select -match '^\d+$') { return [int]$Select }
    for ($i = 0; $i -lt $configs.Count; $i++) {
      $n = if ($configs[$i].name) { [string]$configs[$i].name } else { [string]$configs[$i].host }
      if ($n -eq $Select) { return $i + 1 }
    }
    Die "no host matches -Select '$Select'"
  }

  for ($i = 0; $i -lt $configs.Count; $i++) {
    "{0,3}) {1}" -f ($i + 1), (Get-Display $configs[$i]) | Write-Host
  }
  $picked = Read-Host "Select host number"
  if ($picked -notmatch '^\d+$') { Die "invalid selection: $picked" }
  return [int]$picked
}

$selected = Pick-Index
if ($selected -lt 1 -or $selected -gt $configs.Count) { Die "selection out of range: $selected" }
$cfg = $configs[$selected - 1]

$name = if ($cfg.name) { [string]$cfg.name } else { [string]$cfg.host }
$safeName = Safe-Name $name
$mountDir = Join-Path $PSScriptRoot $safeName
$statePath = Join-Path $PSScriptRoot (".codex-sshfs-" + $safeName + ".json")

$host = [string]$cfg.host
$user = if ($cfg.username) { [string]$cfg.username } else { '' }
$port = if ($cfg.port) { [string]$cfg.port } else { '' }
$root = if ($cfg.root) { [string]$cfg.root } else { '' }

$remote = if ($user) { "$user@$host" } else { $host }
$remoteSpec = if ($root) { "$remote`:$root" } else { "$remote`:" }

$opts = @(
  "reconnect",
  "ServerAliveInterval=$Interval",
  "ServerAliveCountMax=$Count",
  "TCPKeepAlive=yes"
)
if ($env:SSHFS_EXTRA_OPTS) { $opts += [string]$env:SSHFS_EXTRA_OPTS }
$optStr = ($opts -join ',')

function Write-State($obj) {
  ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Read-State {
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  try { return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Unmount-ByState {
  $st = Read-State
  if (-not $st) { return $false }
  $dl = if ($st.DriveLetter) { [string]$st.DriveLetter } else { '' }
  $md = if ($st.MountDir) { [string]$st.MountDir } else { $mountDir }

  if ($DryRun) {
    Write-Host "Would unmount: $md"
    return $true
  }

  if ($dl) {
    try { mountvol ($dl + ':') /D | Out-Null } catch { }
  }
  if (Test-IsJunction $md) {
    try { cmd /c "rmdir ""$md""" | Out-Null } catch { }
  }
  try { Remove-Item -LiteralPath $statePath -Force } catch { }
  return $true
}

if ($Unmount) {
  if (-not (Unmount-ByState)) {
    Write-Host "No state found to unmount for: $name"
  } else {
    Write-Host "Unmounted: $name"
    Write-Host " -> $mountDir"
  }
  exit 0
}

if (Test-Path -LiteralPath $mountDir -PathType Container) {
  if ($Force) {
    Unmount-ByState | Out-Null
    Remove-JunctionOrDir $mountDir
  } else {
    $st = Read-State
    if ($st) {
      Write-Host "Already mounted (state exists): $mountDir"
      exit 0
    }
  }
} else {
  New-Item -ItemType Directory -Path $mountDir | Out-Null
}

$cmdArgs = @()
if ($port) { $cmdArgs += @('-p', $port) }
$cmdArgs += @($remoteSpec, $mountDir, '-o', $optStr)

if ($DryRun) {
  $printed = @('sshfs') + $cmdArgs
  Write-Host ('sshfs command: ' + ($printed | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } } -join ' '))
  exit 0
}

function Try-MountToDir {
  try {
    & sshfs @cmdArgs 2>&1 | ForEach-Object { $_ } | Out-Host
    return $true
  } catch {
    return $false
  }
}

function Try-MountToDriveAndJunction {
  $letter = ''
  if ($DriveLetter) { $letter = $DriveLetter.TrimEnd(':') } else { $letter = Get-FreeDriveLetter }
  if (-not $letter) { Die "no free drive letter available" }

  # Remove empty dir and replace with junction to X:\
  if (Test-Path -LiteralPath $mountDir) { Remove-JunctionOrDir $mountDir }
  cmd /c "mkdir ""$mountDir""" | Out-Null

  $args = @()
  if ($port) { $args += @('-p', $port) }
  $args += @($remoteSpec, ($letter + ':'), '-o', $optStr)

  & sshfs @args 2>&1 | ForEach-Object { $_ } | Out-Host

  # Create junction: .\<host-name> -> X:\
  Remove-JunctionOrDir $mountDir
  cmd /c "mklink /J ""$mountDir"" ""$letter`:\"" | Out-Null
  $script:MountedDriveLetter = $letter

  return $true
}

$script:MountedDriveLetter = $null
$mounted = Try-MountToDir
if (-not $mounted) {
  # Fallback for setups that only support drive letters.
  $mounted = Try-MountToDriveAndJunction
}

if (-not $mounted) { Die "sshfs mount failed" }

if (-not (Test-Path -LiteralPath $mountDir)) { Die "mount completed but mount dir is missing: $mountDir" }

Write-State ([pscustomobject]@{
    Name      = $name
    MountDir  = $mountDir
    DriveLetter = $script:MountedDriveLetter
    Remote    = $remoteSpec
    CreatedAt = (Get-Date).ToString('o')
  })

Write-Host "Mounted: $name"
Write-Host " -> $mountDir"
