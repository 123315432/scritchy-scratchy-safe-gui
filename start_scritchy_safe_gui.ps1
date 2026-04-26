$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$gui = Join-Path $root 'scripts\scritchy_safe_gui.pyw'
$steamAppId = '3948120'

function Find-CheatEngine {
  if ($env:CHEAT_ENGINE_EXE -and (Test-Path $env:CHEAT_ENGINE_EXE)) { return $env:CHEAT_ENGINE_EXE }
  $candidates = @(
    'C:\Program Files\Cheat Engine\cheatengine-x86_64.exe',
    'C:\Program Files (x86)\Cheat Engine\cheatengine-x86_64.exe'
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Find-PythonGui {
  $candidates = @()
  if ($env:PYTHONW_EXE -and (Test-Path $env:PYTHONW_EXE)) { $candidates += $env:PYTHONW_EXE }
  $cmd = Get-Command pythonw.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { $candidates += $cmd.Source }
  foreach ($root in @(
    "$env:LOCALAPPDATA\Programs\Python\Python314",
    "$env:LOCALAPPDATA\Programs\Python\Python313",
    "$env:LOCALAPPDATA\Programs\Python\Python312",
    "$env:LOCALAPPDATA\Programs\Python\Python311",
    "$env:LOCALAPPDATA\Programs\Python\Python310"
  )) {
    if ($root) {
      $candidate = Join-Path $root 'pythonw.exe'
      if (Test-Path $candidate) { $candidates += $candidate }
    }
  }
  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path $candidate) { return @{ File = $candidate; Args = @() } }
  }
  $pyw = Get-Command pyw.exe -ErrorAction SilentlyContinue
  if ($pyw -and $pyw.Source) { return @{ File = $pyw.Source; Args = @('-3') } }
  $py = Get-Command py.exe -ErrorAction SilentlyContinue
  if ($py -and $py.Source) { return @{ File = $py.Source; Args = @('-3') } }
  return $null
}

function Get-SteamRoots {
  $roots = @()
  if ($env:STEAM_ROOT -and (Test-Path $env:STEAM_ROOT)) { $roots += $env:STEAM_ROOT }
  $steamPath = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
  if ($steamPath -and (Test-Path $steamPath)) { $roots += $steamPath }
  foreach ($candidate in @('C:\Program Files (x86)\Steam', 'C:\Program Files\Steam', 'D:\Steam', 'D:\steam1')) {
    if (Test-Path $candidate) { $roots += $candidate }
  }
  $roots | Select-Object -Unique
}

function Get-SteamLibraries($steamRoot) {
  $libraries = @($steamRoot)
  $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
  if (Test-Path $vdf) {
    $content = Get-Content -Path $vdf -Raw
    foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
      $path = $match.Groups[1].Value.Replace('\\', '\')
      if (Test-Path $path) { $libraries += $path }
    }
  }
  $libraries | Select-Object -Unique
}

function Find-Game {
  if ($env:SCRITCHY_GAME_EXE -and (Test-Path $env:SCRITCHY_GAME_EXE)) { return $env:SCRITCHY_GAME_EXE }
  foreach ($rootPath in Get-SteamRoots) {
    foreach ($library in Get-SteamLibraries $rootPath) {
      $candidate = Join-Path $library 'steamapps\common\Scritchy Scratchy\ScritchyScratchy.exe'
      if (Test-Path $candidate) { return $candidate }
    }
  }
  return $null
}

function Find-SteamExe {
  if ($env:STEAM_EXE -and (Test-Path $env:STEAM_EXE)) { return $env:STEAM_EXE }
  foreach ($rootPath in Get-SteamRoots) {
    $candidate = Join-Path $rootPath 'steam.exe'
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Start-ScritchyGame {
  $steamExe = Find-SteamExe
  if ($steamExe) {
    Start-Process -FilePath $steamExe -ArgumentList @('-applaunch', $steamAppId)
    return
  }
  Start-Process -FilePath "steam://rungameid/$steamAppId"
}

$ce = Find-CheatEngine
if (-not (Get-Process cheatengine-x86_64 -ErrorAction SilentlyContinue)) {
  if ($ce) { Start-Process -FilePath $ce }
}

Start-Sleep -Seconds 2

$game = Find-Game
if (-not (Get-Process ScritchyScratchy -ErrorAction SilentlyContinue)) {
  Start-ScritchyGame
}

Start-Sleep -Seconds 2

$pythonGui = Find-PythonGui
if (-not $pythonGui) {
  Write-Host '未找到 pythonw.exe 或 py.exe；请安装 Python，或设置 PYTHONW_EXE 指向 pythonw.exe。'
  exit 1
}

Start-Process -FilePath $pythonGui.File -ArgumentList ($pythonGui.Args + @($gui)) -WorkingDirectory $root
Write-Host "已启动 GUI：$gui"
