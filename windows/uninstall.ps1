# Removes the dictation helper and puts Handy back on its own paste (Ctrl+V). Handy stays installed: remove it in
# Settings > Apps if you want. Your word list is kept in %LOCALAPPDATA%\dictation\vocabulary.txt.
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:LOCALAPPDATA "dictation"
$settings = Join-Path $env:APPDATA "com.pais.handy\settings_store.json"

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Dictation helper" -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$handy = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq "handy" } | Select-Object -First 1
$handyExe = if ($handy) { $handy.Path } else { $null }
if ($handy) { $handy | Stop-Process -Force; Start-Sleep -Milliseconds 500 }
if (Test-Path $settings) {
  $doc = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json
  $doc.settings.paste_method = "ctrl_v"
  $doc.settings.external_script_path = $null
  # without a byte-order mark: Handy cannot read settings that start with one
  [IO.File]::WriteAllText($settings, ($doc | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
  Write-Host "Handy pastes with Ctrl+V again."
}
if ($handyExe) { Start-Process $handyExe }

Get-ChildItem $Root -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "vocabulary.txt" } |
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Removed the dictation helper and its models. Your word list is still in $Root\vocabulary.txt."
