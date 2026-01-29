param(
  [string]$SettingsPath = $env:VSCODE_SETTINGS,
  [string]$Select = '',
  [switch]$Force,
  [switch]$Unmount,
  [int]$Interval = 15,
  [int]$Count = 3,
  [string]$DriveLetter = '',
  [string]$SshfsPath = $env:SSHFS_EXE,
  [switch]$DryRun,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LastSshfsWinStdout = ''
$script:LastSshfsWinStderr = ''

function Die([string]$Message) {
  Write-Error $Message
  exit 1
}

function Info([string]$Message) {
  Write-Host ("info: " + $Message)
}

function Get-PropValue($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -ne $p) { return $p.Value }
  return $null
}

function Resolve-PathLike([string]$PathLike, [string]$BaseDir) {
  if (-not $PathLike) { return $null }

  $p = [Environment]::ExpandEnvironmentVariables([string]$PathLike)
  if ($p.StartsWith('~')) {
    $home = $env:USERPROFILE
    if (-not $home) { $home = $HOME }
    if ($home) { $p = (Join-Path $home $p.TrimStart('~', '\', '/')) }
  }

  if ($BaseDir -and (-not ([IO.Path]::IsPathRooted($p)))) {
    $p = Join-Path $BaseDir $p
  }

  try { return (Resolve-Path -LiteralPath $p -ErrorAction Stop).Path } catch { return $p }
}

function Usage() {
  Write-Host @'
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
  -SshfsPath PATH          Path to sshfs-win.exe.
  -DryRun                  Print sshfs command and exit.
  -Help                    Show help.

  Environment:
  VSCODE_SETTINGS          Same as -SettingsPath.
  SSHFS_EXE                Same as -SshfsPath.
  SSHFS_EXTRA_OPTS         Extra sshfs -o options (comma-separated), appended to defaults.
'@
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
  function Resolve-Exe([string]$PathHint, [string]$CommandName, [string[]]$Candidates) {
    if ($PathHint) {
      $p = [Environment]::ExpandEnvironmentVariables([string]$PathHint)
      if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
      return $null
    }

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }

    foreach ($p in $Candidates) {
      if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
  }

  $candidatesWin = @()
  if ($env:ProgramFiles) {
    $candidatesWin += (Join-Path $env:ProgramFiles 'SSHFS-Win\bin\sshfs-win.exe')
    $candidatesWin += (Join-Path $env:ProgramFiles 'SSHFS-Win\sshfs-win.exe')
  }
  $pf86 = ${env:ProgramFiles(x86)}
  if ($pf86) {
    $candidatesWin += (Join-Path $pf86 'SSHFS-Win\bin\sshfs-win.exe')
    $candidatesWin += (Join-Path $pf86 'SSHFS-Win\sshfs-win.exe')
  }
  if ($env:LOCALAPPDATA) {
    $candidatesWin += (Join-Path $env:LOCALAPPDATA 'Programs\SSHFS-Win\bin\sshfs-win.exe')
    $candidatesWin += (Join-Path $env:LOCALAPPDATA 'Programs\SSHFS-Win\sshfs-win.exe')
  }

  $hint = $SshfsPath
  $hintWin = $null
  if ($hint) {
    $leaf = [IO.Path]::GetFileName([string]$hint).ToLowerInvariant()
    if ($leaf -eq 'sshfs-win.exe') { $hintWin = $hint }
    elseif ($leaf -eq 'sshfs.exe') {
      Write-Warning "You passed sshfs.exe via -SshfsPath. This script requires sshfs-win.exe (SSHFS-Win)."
    } else { $hintWin = $hint }
  }

  $script:SshfsWinCmd = Resolve-Exe $hintWin 'sshfs-win' $candidatesWin

  if ($script:SshfsWinCmd) {
    if (-not (Get-Command sshfs-win -ErrorAction SilentlyContinue)) {
      Write-Host ("Using sshfs-win.exe from: " + $script:SshfsWinCmd)
    }
    return
  }

  Write-Host "sshfs-win.exe not found. Windows needs WinFsp + SSHFS-Win."
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
    Write-Host "Then ensure 'sshfs-win.exe' is in PATH (or pass -SshfsPath) and re-run."
  }

  Write-Host ""
  Write-Host "If SSHFS-Win is installed but sshfs-win.exe isn't in PATH:"
  Write-Host "  1) Find it: where sshfs-win   (in cmd)  OR  Get-Command sshfs-win (in PowerShell)"
  Write-Host "  2) Re-run with: -SshfsPath 'C:\\path\\to\\sshfs-win.exe'  (or set env SSHFS_EXE)"

  if ($DryRun) { Write-Warning "sshfs-win is not installed; continuing because -DryRun was used."; return }
  Die "sshfs-win.exe is required"
}

function Safe-Name([string]$Name) {
  if (-not $Name) { return 'sshfs-mount' }
  $s = $Name -replace '\s+', '_' -replace '[\\/]+', '_'
  $s = -join ($s.ToCharArray() | Where-Object { $_ -match '[A-Za-z0-9._-]' })
  if (-not $s) { return 'sshfs-mount' }
  return $s
}

function Quote-Arg([string]$Arg) {
  if ($null -eq $Arg) { return '""' }
  if ($Arg -eq '') { return '""' }
  if ($Arg -match '[\s"]') { return '"' + ($Arg -replace '"', '""') + '"' }
  return $Arg
}

function Build-SshfsWinPrefix {
  param(
    [string]$RemoteHost,
    [string]$RemoteUser,
    [string]$Port,
    [string]$Root
  )

  $suffix = ''
  $path = ''
  if ($Root) {
    $r = [string]$Root
    if ($r.StartsWith('/')) {
      $suffix = '.r'
      $r = $r.TrimStart('/')
    }
    $r = $r.TrimStart('\', '/')
    if ($r) { $path = ($r -replace '/', '\') }
  }

  $server = 'sshfs' + $suffix
  $hostPart = if ($RemoteUser) { ([string]$RemoteUser + '@' + [string]$RemoteHost) } else { [string]$RemoteHost }
  if ($Port) { $hostPart = $hostPart + '!' + [string]$Port }

  # sshfs-win "svc" expects a Windows UNC prefix **with a single leading backslash**
  # (see SSHFS-Win README: "note single backslash").
  $prefix = '\' + $server + '\' + $hostPart
  if ($path) { $prefix = $prefix + '\' + $path }
  return $prefix
}

function Invoke-SshfsWinSvc {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Prefix,
    [Parameter(Mandatory = $true)]
    [string]$DriveMount,
    [string]$LocalUser = '',
    [string[]]$Options = @(),
    [string]$Password = ''
  )

  if (-not $script:SshfsWinCmd) { Die "sshfs-win.exe is required (not found)" }

  $argv = @('svc', $Prefix, $DriveMount)
  $hasOptions = @($Options | Where-Object { $_ }).Count -gt 0
  # sshfs-win svc has an optional LOCUSER positional arg. If we pass -o options, we must still include
  # LOCUSER (can be empty) so that '-o' isn't consumed as LOCUSER.
  if ($hasOptions -or $LocalUser) { $argv += @([string]$LocalUser) }
  foreach ($o in @($Options)) {
    if ($o) { $argv += @('-o', [string]$o) }
  }
  $argLine = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '

  $script:LastSshfsWinStdout = ''
  $script:LastSshfsWinStderr = ''

  if (-not $Password) {
    & $script:SshfsWinCmd @argv
    return $LASTEXITCODE
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:SshfsWinCmd
  $psi.Arguments = $argLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  try {
    $proc.StandardInput.WriteLine($Password)
    $proc.StandardInput.Close()
  } catch { }

  $stdout = ''
  $stderr = ''
  try { $stdout = $proc.StandardOutput.ReadToEnd() } catch { }
  try { $stderr = $proc.StandardError.ReadToEnd() } catch { }
  $proc.WaitForExit()

  $script:LastSshfsWinStdout = $stdout
  $script:LastSshfsWinStderr = $stderr

  if ($stdout) { $stdout.TrimEnd("`r", "`n") | Write-Host }
  if ($stderr) { $stderr.TrimEnd("`r", "`n") | Write-Host }

  return $proc.ExitCode
}

function Get-FreeDriveLetter {
  $used = @()
  try {
    $used += [System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() }
  } catch { }
  try {
    $used += (Get-PSDrive -PSProvider FileSystem).Name | ForEach-Object { $_.ToUpperInvariant() }
  } catch { }
  $used = @($used | Where-Object { $_ } | Select-Object -Unique)

  foreach ($c in [char[]]([char]'Z'..[char]'D')) {
    $letter = ([string]$c).ToUpperInvariant()
    if ($used -notcontains $letter) { return $letter }
  }
  return $null
}

function Normalize-DriveLetter([string]$Value) {
  if (-not $Value) { return '' }
  $x = ([string]$Value).Trim().TrimEnd(':')
  if ($x.Length -ne 1) { return '' }
  return $x.ToUpperInvariant()
}

function Get-ProviderFromPrefix([string]$Prefix) {
  if (-not $Prefix) { return '' }
  return ('\\' + ([string]$Prefix).TrimStart('\'))
}

function Get-LocalUserForSshfsWin {
  if ($env:USERNAME) {
    if ($env:USERDOMAIN) { return ([string]$env:USERDOMAIN + '+' + [string]$env:USERNAME) }
    return [string]$env:USERNAME
  }

  try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id -and $id.Name) {
      $n = [string]$id.Name
      if ($n -match '^[^\\]+\\[^\\]+$') { return ($n -replace '\\', '+') }
      return $n
    }
  } catch { }

  return ''
}

function Get-DriveProviderName([string]$DriveLetter) {
  $dl = Normalize-DriveLetter $DriveLetter
  if (-not $dl) { return '' }
  $id = $dl + ':'
  $filter = "DeviceID='$id'"

  $disk = $null
  try {
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter $filter -ErrorAction Stop
  } catch {
    try { $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter $filter -ErrorAction Stop } catch { $disk = $null }
  }

  if ($disk -and $disk.PSObject.Properties.Match('ProviderName').Count -gt 0 -and $disk.ProviderName) {
    return [string]$disk.ProviderName
  }
  return ''
}

function Find-DriveLetterByProviderName([string]$ProviderName) {
  if (-not $ProviderName) { return '' }
  $want = [string]$ProviderName

  $disks = $null
  try {
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=4" -ErrorAction Stop
  } catch {
    try { $disks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=4" -ErrorAction Stop } catch { $disks = $null }
  }
  if (-not $disks) { return '' }

  $hits = @()
  foreach ($d in @($disks)) {
    $pn = if ($d.ProviderName) { [string]$d.ProviderName } else { '' }
    if ($pn -and ($pn -ieq $want)) {
      $hits += (Normalize-DriveLetter ([string]$d.DeviceID))
    }
  }
  $hits = @($hits | Where-Object { $_ })
  if ($hits.Count -gt 1) {
    Write-Warning ("Multiple drives match provider '" + $want + "': " + (($hits | Sort-Object -Unique) -join ', ') + ". Using: " + $hits[0])
  }
  if ($hits.Count -ge 1) { return $hits[0] }
  return ''
}

function Try-UnmountDrive([string]$DriveLetter) {
  $dl = Normalize-DriveLetter $DriveLetter
  if (-not $dl) { return $true }
  $root = $dl + ':\'
  if (-not (Test-Path -LiteralPath $root)) { return $true }

  $mount = $dl + ':'
  try { cmd /c ("net use " + $mount + " /delete /y") | Out-Null } catch { }
  try { mountvol $mount /D | Out-Null } catch { }

  for ($i = 0; $i -lt 8; $i++) {
    if (-not (Test-Path -LiteralPath $root)) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
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

function Test-IsEmptyDir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }
  try {
    $one = Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 1
    return ($null -eq $one)
  } catch {
    return $false
  }
}

Ensure-Dependencies

if (-not $SettingsPath) { $SettingsPath = Get-DefaultSettingsPath }
if (-not $SettingsPath) { Die "could not find VS Code settings.json (set VSCODE_SETTINGS or pass -SettingsPath)" }
if (-not (Test-Path -LiteralPath $SettingsPath)) { Die "settings.json not found: $SettingsPath" }

$settingsDir = Split-Path -Parent $SettingsPath
$settings = Load-Jsonc $SettingsPath

$configs = @()
$mainConfigs = Get-PropValue $settings 'sshfs.configs'
if ($null -ne $mainConfigs) { $configs += @($mainConfigs) }

$configPaths = Get-PropValue $settings 'sshfs.configpaths'
if ($null -ne $configPaths) {
  foreach ($p in @($configPaths)) {
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

$configs = @($configs | Where-Object { $_ -and (Get-PropValue $_ 'host') })
if ($configs.Count -eq 0) { Die "no sshfs.configs found in $SettingsPath" }

function Get-Display($cfg) {
  $nameProp = Get-PropValue $cfg 'name'
  $hostProp = Get-PropValue $cfg 'host'
  $userProp = Get-PropValue $cfg 'username'
  $portProp = Get-PropValue $cfg 'port'
  $rootProp = Get-PropValue $cfg 'root'

  $name = if ($nameProp) { [string]$nameProp } else { [string]$hostProp }
  $remoteHost = [string]$hostProp
  $user = if ($userProp) { [string]$userProp } else { '' }
  $port = if ($portProp) { [string]$portProp } else { '' }
  $root = if ($rootProp) { [string]$rootProp } else { '' }

  $summary = ''
  if ($user -and $remoteHost) { $summary = "$user@$remoteHost" } else { $summary = $remoteHost }
  if ($port) { $summary = "$summary`:$port" }
  if ($root) { $summary = "$summary $root" }
  if ($summary) { return "$name ($summary)" }
  return $name
}

function Pick-Index {
  if ($Select) {
    if ($Select -match '^\d+$') { return [int]$Select }
    for ($i = 0; $i -lt $configs.Count; $i++) {
      $nProp = Get-PropValue $configs[$i] 'name'
      $hProp = Get-PropValue $configs[$i] 'host'
      $n = if ($nProp) { [string]$nProp } else { [string]$hProp }
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

$nameProp = Get-PropValue $cfg 'name'
$hostProp = Get-PropValue $cfg 'host'
$name = if ($nameProp) { [string]$nameProp } else { [string]$hostProp }
$safeName = Safe-Name $name
$mountDir = Join-Path $PSScriptRoot $safeName
$statePath = Join-Path $PSScriptRoot (".codex-sshfs-" + $safeName + ".json")

$remoteHost = [string](Get-PropValue $cfg 'host')
$userProp = Get-PropValue $cfg 'username'
$portProp = Get-PropValue $cfg 'port'
$rootProp = Get-PropValue $cfg 'root'
$passwordProp = Get-PropValue $cfg 'password'
$passphraseProp = Get-PropValue $cfg 'passphrase'
$keyPathProp = (Get-PropValue $cfg 'privateKeyPath')
if (-not $keyPathProp) { $keyPathProp = (Get-PropValue $cfg 'privateKey') }
if (-not $keyPathProp) { $keyPathProp = (Get-PropValue $cfg 'identityFile') }
$user = if ($userProp) { [string]$userProp } else { '' }
$port = if ($portProp) { [string]$portProp } else { '' }
$root = if ($rootProp) { [string]$rootProp } else { '' }

$askpassSecret = ''
if ($passwordProp -is [string]) {
  $askpassSecret = [string]$passwordProp
} elseif ($passwordProp -is [bool]) {
  # Some setups store the actual password in VS Code secret storage and keep a boolean flag in settings.json.
  # This script intentionally does not try to read VS Code secrets to keep dependencies minimal.
  if ($passwordProp) {
    Write-Warning "Password is set as a boolean in sshfs.configs. The actual secret is not readable from settings.json; you may be prompted for a password."
  }
}

if (-not $askpassSecret -and ($passphraseProp -is [string]) -and [string]$passphraseProp) {
  $askpassSecret = [string]$passphraseProp
}

$keyPath = ''
if ($keyPathProp -is [string] -and [string]$keyPathProp) {
  $keyPath = Resolve-PathLike ([string]$keyPathProp) $settingsDir
}

$remote = if ($user) { "$user@$remoteHost" } else { $remoteHost }
$remoteSpec = if ($root) { "$remote`:$root" } else { "$remote`:" }
$sshfsWinPrefix = Build-SshfsWinPrefix -RemoteHost $remoteHost -RemoteUser $user -Port $port -Root $root
$expectedProvider = Get-ProviderFromPrefix $sshfsWinPrefix

$opts = @(
  "ServerAliveInterval=$Interval",
  "ServerAliveCountMax=$Count",
  # Avoid interactive "Are you sure you want to continue connecting (yes/no)?" prompts.
  # Note: sshfs-win "svc" already uses safe defaults for known_hosts; this keeps behavior consistent.
  "StrictHostKeyChecking=no",
  "UserKnownHostsFile=/dev/null"
)
if ($env:SSHFS_EXTRA_OPTS) { $opts += [string]$env:SSHFS_EXTRA_OPTS }
$opts = @($opts | Where-Object { $_ })

if ($keyPath) {
  $opts += @("IdentityFile=$keyPath", "IdentitiesOnly=yes")
}

# Best-effort non-interactive password feeding for sshfs/ssh on Windows.
# Works only if the bundled sshfs supports "password_stdin". If not supported, the retry logic will drop options.
if ($askpassSecret -and (-not $keyPath)) {
  $opts += @("password_stdin")
}

function Write-State($obj) {
  ($obj | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Read-State {
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  try { return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Unmount-ByState {
  $st = Read-State
  if (-not $st) {
    return [pscustomobject]@{
      Found         = $false
      DriveLetter   = ''
      ProviderExpected = ''
      ProviderActual   = ''
      DriveUnmounted = $true
      MountDirRemoved = $false
      StateRemoved  = $false
    }
  }

  $dl = ''
  if ($st.PSObject.Properties.Match('DriveLetter').Count -gt 0 -and $st.DriveLetter) {
    $dl = Normalize-DriveLetter ([string]$st.DriveLetter)
  }
  $md = if ($st.PSObject.Properties.Match('MountDir').Count -gt 0 -and $st.MountDir) { [string]$st.MountDir } else { $mountDir }

  $providerExpected = ''
  if ($st.PSObject.Properties.Match('Provider').Count -gt 0 -and $st.Provider) { $providerExpected = [string]$st.Provider }
  if (-not $providerExpected) { $providerExpected = $expectedProvider }

  $drivePresentAtDl = $false
  if ($dl) {
    try { $drivePresentAtDl = (Test-Path -LiteralPath ($dl + ':\')) } catch { $drivePresentAtDl = $false }
  }

  $providerActual = ''
  if ($drivePresentAtDl) { $providerActual = Get-DriveProviderName $dl }

  $res = [pscustomobject]@{
    Found           = $true
    DriveLetter     = $dl
    ProviderExpected = $providerExpected
    ProviderActual   = $providerActual
    DriveUnmounted  = $true
    MountDirRemoved = $false
    StateRemoved    = $false
  }

  if ($DryRun) {
    Write-Host "Would unmount: $md"
    return $res
  }

  $targetDrive = ''
  if ($dl -and $drivePresentAtDl) {
    if ($providerExpected) {
      if (-not $providerActual) {
        Write-Warning ("Drive " + $dl + ": provider cannot be determined; refusing to unmount by drive letter.")
      } elseif ($providerActual -ine $providerExpected) {
        Write-Warning ("Drive " + $dl + ": provider '" + $providerActual + "' does not match expected '" + $providerExpected + "'.")
      } else {
        $targetDrive = $dl
      }
    } else {
      $targetDrive = $dl
    }
  }
  if (-not $targetDrive -and $providerExpected) {
    $targetDrive = Find-DriveLetterByProviderName $providerExpected
  }

  if ($targetDrive) {
    $res.DriveLetter = $targetDrive
    $res.ProviderActual = Get-DriveProviderName $targetDrive
    $res.DriveUnmounted = Try-UnmountDrive $targetDrive
    if (-not $res.DriveUnmounted) {
      Write-Warning ("Failed to unmount drive " + $targetDrive + ":")
      if ($script:LastSshfsWinStdout) { $script:LastSshfsWinStdout.TrimEnd("`r", "`n") | Write-Host }
      if ($script:LastSshfsWinStderr) { $script:LastSshfsWinStderr.TrimEnd("`r", "`n") | Write-Host }
    }
  } else {
    # No drive found. Only treat as "unmounted" if the state drive letter is not present anymore.
    # Otherwise, refuse to proceed to avoid unmounting/cleaning up the wrong thing.
    if (-not $drivePresentAtDl) {
      $res.DriveUnmounted = $true
    } else {
      $res.DriveUnmounted = $false
    }
  }

  if (Test-IsJunction $md) {
    try { cmd /c "rmdir ""$md""" | Out-Null; $res.MountDirRemoved = $true } catch { }
  } elseif (Test-IsEmptyDir $md) {
    try { Remove-Item -LiteralPath $md -Force; $res.MountDirRemoved = $true } catch { }
  }

  if ($res.DriveUnmounted) {
    try { Remove-Item -LiteralPath $statePath -Force; $res.StateRemoved = $true } catch { }
  }

  return $res
}

if ($Unmount) {
  $un = Unmount-ByState
  if (-not $un.Found) {
    Write-Host "No state found to unmount for: $name"
  } else {
    if (-not $un.DriveUnmounted) {
      Die ("Failed to unmount drive " + $un.DriveLetter + ":")
    }
    Write-Host "Unmounted: $name"
    Write-Host " -> $mountDir"
  }
  exit 0
}

if ($DryRun) {
  $fmt = {
    param([string[]]$arr)
    ($arr | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  }

  $letterForPrint = if ($DriveLetter) { ([string]$DriveLetter).TrimEnd(':').Trim() } else { Get-FreeDriveLetter }
  if ($letterForPrint) { $letterForPrint = $letterForPrint.ToUpperInvariant() }

  if ($letterForPrint) {
    $driveMountForPrint = ($letterForPrint + ':')
    if ($script:SshfsWinCmd) {
      $locUserForPrint = ''
      if ($env:USERNAME) {
        if ($env:USERDOMAIN) {
          $locUserForPrint = ([string]$env:USERDOMAIN + '+' + [string]$env:USERNAME)
        } else {
          $locUserForPrint = [string]$env:USERNAME
        }
      }

      $printedSvc = @($script:SshfsWinCmd, 'svc', $sshfsWinPrefix, $driveMountForPrint)
      if ($locUserForPrint) { $printedSvc += @($locUserForPrint) }
      foreach ($o in @($opts)) { if ($o) { $printedSvc += @('-o', [string]$o) } }
      Write-Host ('sshfs-win command (drive): ' + (& $fmt $printedSvc))
    } else {
      Write-Host "sshfs-win command (drive): <sshfs-win not found>"
    }
    Write-Host ('junction target: ' + $mountDir + ' -> ' + $letterForPrint + ':\')
  } else {
    Write-Host "sshfs-win command (drive): <no free drive letter available>"
  }
  exit 0
}

$st = Read-State
$stDrive = ''
if ($st -and $st.PSObject.Properties.Match('DriveLetter').Count -gt 0) { $stDrive = Normalize-DriveLetter ([string]$st.DriveLetter) }
$stDriveMounted = $false
if ($stDrive) {
  try { $stDriveMounted = (Test-Path -LiteralPath ($stDrive + ':\')) } catch { $stDriveMounted = $false }
}
$stDriveProvider = ''
if ($stDriveMounted) { $stDriveProvider = Get-DriveProviderName $stDrive }
$stDriveMatchesExpected = $false
if ($stDriveProvider -and $expectedProvider -and ($stDriveProvider -ieq $expectedProvider)) { $stDriveMatchesExpected = $true }

if ($Force) {
  if ($st) {
    $un = Unmount-ByState
    if ($un.Found -and (-not $un.DriveUnmounted)) {
      if ($un.ProviderActual -and $un.ProviderExpected -and ($un.ProviderActual -ine $un.ProviderExpected)) {
        Write-Warning ("State drive " + $un.DriveLetter + ": points to '" + $un.ProviderActual + "', expected '" + $un.ProviderExpected + "'. Skipping unmount.")
      } else {
        Die ("Failed to unmount drive " + $un.DriveLetter + ":")
      }
    }
  }
  if (Test-Path -LiteralPath $mountDir) { Remove-JunctionOrDir $mountDir }
  try { Remove-Item -LiteralPath $statePath -Force } catch { }
} else {
  if ($st) {
    if ($stDriveMounted) {
      if ($expectedProvider) {
        if (-not $stDriveProvider) {
          Write-Warning ("State drive letter " + $stDrive + ": is mounted but provider cannot be determined. Remounting.")
          try { Remove-Item -LiteralPath $statePath -Force } catch { }
          if (Test-IsJunction $mountDir) { Remove-JunctionOrDir $mountDir }
        } elseif (-not $stDriveMatchesExpected) {
          Write-Warning ("State drive letter " + $stDrive + ": is mounted but points to '" + $stDriveProvider + "', expected '" + $expectedProvider + "'. Remounting.")
          try { Remove-Item -LiteralPath $statePath -Force } catch { }
          if (Test-IsJunction $mountDir) { Remove-JunctionOrDir $mountDir }
        } else {
          # If the mount exists (drive is present), don't remount; just ensure the junction exists.
          if (Test-Path -LiteralPath $mountDir) {
            if (-not (Test-IsJunction $mountDir)) {
              if (-not (Test-IsEmptyDir $mountDir)) {
                Die "mount dir already exists and is not empty: $mountDir`nRe-run with -Force to replace it."
              }
              Remove-JunctionOrDir $mountDir
            }
          }

          if (-not (Test-Path -LiteralPath $mountDir)) {
            cmd /c "mklink /J ""$mountDir"" ""$stDrive`:\\""" | Out-Null
          }

          Write-State ([pscustomobject]@{
              Name        = $name
              MountDir    = $mountDir
              DriveLetter = $stDrive
              Provider    = $expectedProvider
              Prefix      = $sshfsWinPrefix
              Remote      = $remoteSpec
              CreatedAt   = (Get-Date).ToString('o')
            })

          Write-Host "Already mounted: $name"
          Write-Host " -> $mountDir"
          exit 0
        }
      } else {
        # No expected provider info; trust drive letter and ensure junction exists.
        if (Test-Path -LiteralPath $mountDir) {
          if (-not (Test-IsJunction $mountDir)) {
            if (-not (Test-IsEmptyDir $mountDir)) {
              Die "mount dir already exists and is not empty: $mountDir`nRe-run with -Force to replace it."
            }
            Remove-JunctionOrDir $mountDir
          }
        }

        if (-not (Test-Path -LiteralPath $mountDir)) {
          cmd /c "mklink /J ""$mountDir"" ""$stDrive`:\\""" | Out-Null
        }

        Write-State ([pscustomobject]@{
            Name        = $name
            MountDir    = $mountDir
            DriveLetter = $stDrive
            Provider    = $expectedProvider
            Prefix      = $sshfsWinPrefix
            Remote      = $remoteSpec
            CreatedAt   = (Get-Date).ToString('o')
          })

        Write-Host "Already mounted: $name"
        Write-Host " -> $mountDir"
        exit 0
      }
    } else {
      # Stale state: drive is not present. Do not try to unmount by drive letter (it could be reused).
      Write-Warning "State file exists but drive is not mounted; remounting."
      try { Remove-Item -LiteralPath $statePath -Force } catch { }
      if (Test-IsJunction $mountDir) { Remove-JunctionOrDir $mountDir }
    }
  }

  if (Test-Path -LiteralPath $mountDir -PathType Container) {
    if (Test-IsJunction $mountDir) {
      Die "mount dir exists as a junction but no state file was found: $mountDir`nRe-run with -Force to remount."
    }
    if (-not (Test-IsEmptyDir $mountDir)) {
      Die "mount dir already exists and is not empty: $mountDir`nRe-run with -Force to replace it."
    }
  }
}

function Try-MountToDriveAndJunction {
  $letter = ''
  if ($DriveLetter) { $letter = Normalize-DriveLetter $DriveLetter }
  if (-not $letter) { $letter = Get-FreeDriveLetter }
  if (-not $letter) { Die "no free drive letter available" }

  $driveMount = ($letter + ':')
  $driveRoot = ($letter + ':\')

  if (Test-Path -LiteralPath $driveRoot) {
    $prov = Get-DriveProviderName $letter
    if ($prov -and $expectedProvider -and ($prov -ieq $expectedProvider)) {
      # The drive is already our sshfs mapping; just ensure the junction exists.
      Write-Host ("Drive already mounted for this host: " + $driveMount)
      Remove-JunctionOrDir $mountDir
      cmd /c "mklink /J ""$mountDir"" ""$letter`:\\""" | Out-Null
      $script:MountedDriveLetter = [string]$letter
      return $true
    }
    if ($prov) {
      Die ("drive letter already in use: " + $driveMount + " (" + $prov + ")`nPick another -DriveLetter (or omit it).")
    }
    Die "drive letter already in use: $driveMount`nPick another -DriveLetter (or omit it)."
  }

  $rc = 1
  if ($script:SshfsWinCmd) {
    Write-Host ("Mounting via sshfs-win to drive " + $driveMount + " ...")

    # sshfs-win.exe svc syntax: sshfs-win svc PREFIX X: [LOCUSER] [SSHFS_OPTIONS...]
    # If LOCUSER is omitted, the next argument is consumed as LOCUSER, so we must always pass it
    # when we also pass "-o ..." options.
    $locUser = Get-LocalUserForSshfsWin

    $tries = @(
      ,@($opts),
      ,@($opts | Where-Object { $_ -ne 'password_stdin' }),
      ,@($opts | Where-Object { $_ -notmatch '^ServerAliveInterval=' -and $_ -notmatch '^ServerAliveCountMax=' }),
      ,@($opts | Where-Object { $_ -ne 'StrictHostKeyChecking=no' }),
      ,@($opts | Where-Object { $_ -ne 'UserKnownHostsFile=/dev/null' }),
      ,@()
    )

    foreach ($optSet in $tries) {
      $script:LastSshfsWinStdout = ''
      $script:LastSshfsWinStderr = ''
      $rc = Invoke-SshfsWinSvc -Prefix $sshfsWinPrefix -DriveMount $driveMount -LocalUser $locUser -Options $optSet -Password $askpassSecret

      # Some builds may return a non-zero exit code even though the mount is created.
      $driveAppears = $false
      try { $driveAppears = (Test-Path -LiteralPath $driveRoot) } catch { $driveAppears = $false }
      if ($rc -eq 0 -or $driveAppears) {
        if ($rc -ne 0) {
          Write-Warning ("sshfs-win exited with code " + $rc + " but " + $driveMount + " appears mounted; continuing.")
        }
        break
      }
      # Keep trying reduced option sets; sshfs-win builds vary in supported -o options.
    }
  } else {
    Die "sshfs-win.exe not found"
  }
  $driveReady = $false
  for ($i = 0; $i -lt 10; $i++) {
    if (Test-Path -LiteralPath $driveRoot) { $driveReady = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $driveReady) { return $false }
  if ($rc -ne 0) {
    Write-Warning ("sshfs exited with code " + $rc + " but " + $driveMount + " is accessible; continuing.")
  }

  # Create junction: .\<host-name> -> X:\
  Remove-JunctionOrDir $mountDir
  cmd /c "mklink /J ""$mountDir"" ""$letter`:\\""" | Out-Null
  $script:MountedDriveLetter = [string]$letter

  return $true
}

$script:MountedDriveLetter = $null
$mounted = Try-MountToDriveAndJunction
if (-not $mounted) { Die "sshfs mount failed" }

if (-not (Test-Path -LiteralPath $mountDir)) { Die "mount completed but mount dir is missing: $mountDir" }

Write-State ([pscustomobject]@{
    Name      = $name
    MountDir  = $mountDir
    DriveLetter = $script:MountedDriveLetter
    Provider  = $expectedProvider
    Prefix    = $sshfsWinPrefix
    Remote    = $remoteSpec
    CreatedAt = (Get-Date).ToString('o')
  })

Write-Host "Mounted: $name"
Write-Host " -> $mountDir"
