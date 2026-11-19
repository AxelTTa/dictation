# Dictation for Windows: Handy (speech to text) plus a second pass that knows your words, punctuation, and a paste
# that lands in the window you started in. Re-run it any time to update; your word list is kept.
#
#   Double-click install.cmd, or in PowerShell:
#   irm https://raw.githubusercontent.com/AxelTTa/dictation/main/windows/install.ps1 | iex
#
# Options (install.cmd -BigModel, or $env:DICTATION_OPTIONS = "-BigModel" before the one-liner):
#   -BigModel    Whisper Large v3 (1.2 GB, wants a good graphics card) instead of Large v3 Turbo (0.6 GB)
#   -CI          tests: no questions, no windows opened at the end
# Everything goes in %LOCALAPPDATA%\dictation (about 2.5 GB with the models) plus Handy itself.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$options = @($args) + @(("$env:DICTATION_OPTIONS" -split " ") | Where-Object { $_ })
$BigModel = $options -contains "-BigModel"
$CI = $options -contains "-CI"

$Root = Join-Path $env:LOCALAPPDATA "dictation"
$HandyData = Join-Path $env:APPDATA "com.pais.handy"
$HandyLogs = Join-Path $env:LOCALAPPDATA "com.pais.handy\logs"
$Venv = Join-Path $Root "venv"
$Py = Join-Path $Venv "Scripts\python.exe"
$PasteExe = Join-Path $Venv "Scripts\dictation-paste.exe"
$HelperExe = Join-Path $Venv "Scripts\dictation-helper.exe"
$RepoZip = "https://github.com/AxelTTa/dictation/archive/refs/heads/main.zip"

# Pinned and checked: versions this setup was tested with.
$HandyVersion = "0.9.8"
$HandySetup = @{
  url = "https://github.com/cjpais/Handy/releases/download/v0.9.8/Handy_0.9.8_x64-setup.exe"
  sha = "4212edb5658ec2867855fc2ee83ac16ec5bbad09db3c2da8d3d9d5f8bd5eeccc" }
if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
  $HandySetup = @{
    url = "https://github.com/cjpais/Handy/releases/download/v0.9.8/Handy_0.9.8_arm64-setup.exe"
    sha = "c023ff141c76417dd7891dd1454b25de09e3fbcfeb6a560373655fdb66140a4d" }
}
$Uv = @{
  url = "https://github.com/astral-sh/uv/releases/download/0.13.5/uv-x86_64-pc-windows-msvc.zip"
  sha = "a38b8d1902b7cfbc76b423ba1bb456f623f42064cdc72628b6075b89afd1019a" }
$LiveModel = @{
  id = "handy-computer/parakeet-unified-en-0.6b-gguf/parakeet-unified-en-0.6b-Q8_0.gguf"
  file = "parakeet-unified-en-0.6b-Q8_0.gguf"
  url = "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/7e948f21b7bdbac698d3318db9d350f1096f3b6c/parakeet-unified-en-0.6b-Q8_0.gguf"
  sha = "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795" }
$Whisper = @{
  file = "whisper-large-v3-turbo-Q5_K_M.gguf"
  url = "https://huggingface.co/handy-computer/whisper-large-v3-turbo-gguf/resolve/5eaf945c7978e564bae5b28a5b1639dd93c2bfb1/whisper-large-v3-turbo-Q5_K_M.gguf"
  sha = "977b5db4e004349dffd1ab9caa10ba5aaba3fc3edd3ba72cadb84328a3203e36" }
if ($BigModel) {
  $Whisper = @{
    file = "whisper-large-v3-Q5_K_M.gguf"
    url = "https://huggingface.co/handy-computer/whisper-large-v3-gguf/resolve/e3e29bee6389c7da4a141406f07bb80ddac5337c/whisper-large-v3-Q5_K_M.gguf"
    sha = "6053d0fd69a0fd48b8fea5ea7a52b9e0cde389343566fa30e453a1b2b258dc38" }
}
$Punct = "https://huggingface.co/1-800-BAD-CODE/punct_cap_seg_en/resolve/b26fd1c40e88678859048898218ea4edcc24c84a"

function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }

function Get-File($url, $dest, $sha) {
  if ((Test-Path $dest) -and (!$sha -or (Get-FileHash $dest -Algorithm SHA256).Hash -eq $sha.ToUpper())) { return }
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  $part = "$dest.part"
  Write-Host "   downloading $(Split-Path $dest -Leaf)"
  if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    & curl.exe -fL --retry 3 --silent --show-error -o $part $url
    if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
  } else {
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
  }
  if ($sha -and (Get-FileHash $part -Algorithm SHA256).Hash -ne $sha.ToUpper()) {
    Remove-Item $part -Force
    throw "checksum mismatch for $url"
  }
  Move-Item -Force $part $dest
}

function Find-Handy {
  $keys = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
  foreach ($k in Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "Handy" }) {
    foreach ($dir in @($k.InstallLocation, (Split-Path ("$($k.DisplayIcon)" -replace '"|,\d+$', '') -ErrorAction SilentlyContinue))) {
      if ($dir) { foreach ($n in "handy.exe", "Handy.exe") { if (Test-Path (Join-Path $dir $n)) { return (Join-Path $dir $n) } } }
    }
  }
  foreach ($dir in "$env:LOCALAPPDATA\Handy", "$env:ProgramFiles\Handy", "$env:LOCALAPPDATA\Programs\Handy") {
    foreach ($n in "handy.exe", "Handy.exe") { if (Test-Path (Join-Path $dir $n)) { return (Join-Path $dir $n) } }
  }
  return $null
}

function Stop-Helper {
  $state = Join-Path $Root "helper.json"
  if (Test-Path $state) {
    try { Stop-Process -Id ((Get-Content $state -Raw | ConvertFrom-Json).pid) -Force -ErrorAction SilentlyContinue } catch {}
  }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item $state -Force -ErrorAction SilentlyContinue
}

Write-Host "Dictation setup for Windows (Handy $HandyVersion + accurate pass + punctuation)" -ForegroundColor Green

# --- 1. This repository's files -----------------------------------------------------------------------------------
Step "Getting the files"
$Src = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "dictation_helper.py"))) {
  $Src = Split-Path $PSScriptRoot
} else {
  $tmp = Join-Path $env:TEMP ("dictation-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  Get-File $RepoZip (Join-Path $tmp "repo.zip") $null
  Expand-Archive (Join-Path $tmp "repo.zip") $tmp -Force
  $Src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
}
New-Item -ItemType Directory -Force -Path $Root, (Join-Path $Root "app"), (Join-Path $Root "models"), (Join-Path $Root "logs") | Out-Null
Stop-Helper
foreach ($f in "windows\dictation_helper.py", "windows\dictation_paste.py", "windows\pyproject.toml", "common\accurate.py", "common\punctuate.py") {
  Copy-Item -Force (Join-Path $Src $f) (Join-Path $Root "app")
}
$vocab = Join-Path $Root "vocabulary.txt"
if (!(Test-Path $vocab)) { Copy-Item (Join-Path $Src "common\vocabulary.example.txt") $vocab }

# --- 2. Python and libraries (private copy, nothing system-wide) -------------------------------------------------
Step "Python and libraries"
$uvExe = Join-Path $Root "uv\uv.exe"
if (!(Test-Path $uvExe)) {
  Get-File $Uv.url (Join-Path $Root "uv\uv.zip") $Uv.sha
  Expand-Archive (Join-Path $Root "uv\uv.zip") (Join-Path $Root "uv") -Force
}
$env:UV_PYTHON_INSTALL_DIR = Join-Path $Root "python"
$env:UV_CACHE_DIR = Join-Path $Root "cache"
$env:UV_NO_PROGRESS = "1"
# x64 Python everywhere (the speech engine has no ARM build; Windows on ARM runs it emulated)
& $uvExe venv --quiet --allow-existing --managed-python --python cpython-3.12-windows-x86_64-none $Venv
if ($LASTEXITCODE -ne 0) { throw "could not create the Python environment" }
& $uvExe pip install --quiet --python $Py "numpy<3" sounddevice onnxruntime sentencepiece "transcribe-cpp==0.4.2" "transcribe-cpp-native==0.4.2"
if ($LASTEXITCODE -ne 0) { throw "could not install the Python libraries" }
& $uvExe pip install --quiet --python $Py -e (Join-Path $Root "app")
if ($LASTEXITCODE -ne 0) { throw "could not install the dictation programs" }

# --- 3. Models -----------------------------------------------------------------------------------------------------
Step "Models (about 1.6 GB the first time)"
$pm = Join-Path $Root "punct-model"
foreach ($f in "punct_cap_seg_en.onnx", "spe_32k_lc_en.model", "config.yaml") { Get-File "$Punct/$f" (Join-Path $pm $f) $null }
if (!(Test-Path (Join-Path $pm "punct_cap_seg_en.int8.onnx"))) {
  Write-Host "   making the 8-bit punctuation model"
  & $uvExe pip install --quiet --python $Py onnx
  & $Py -c "import sys; from onnxruntime.quantization import quantize_dynamic, QuantType; quantize_dynamic(sys.argv[1] + '/punct_cap_seg_en.onnx', sys.argv[1] + '/punct_cap_seg_en.int8.onnx', weight_type=QuantType.QInt8)" $pm
  if ($LASTEXITCODE -ne 0) { throw "could not make the punctuation model" }
  & $uvExe pip uninstall --quiet --python $Py onnx
}
Get-File $Whisper.url (Join-Path $Root "models\$($Whisper.file)") $Whisper.sha
Get-File $LiveModel.url (Join-Path $HandyData "models\$($LiveModel.file)") $LiveModel.sha

# --- 4. Handy --------------------------------------------------------------------------------------------------------
Step "Handy"
$handyExe = Find-Handy
if (!$handyExe) {
  $setup = Join-Path $Root "handy-setup.exe"
  Get-File $HandySetup.url $setup $HandySetup.sha
  Write-Host "   installing Handy $HandyVersion"
  Start-Process -Wait -FilePath $setup -ArgumentList "/S"
  Remove-Item $setup -Force
  $handyExe = Find-Handy
  if (!$handyExe) { throw "Handy did not install (try running $($HandySetup.url) by hand, then this again)" }
} else {
  $v = (Get-Item $handyExe).VersionInfo.ProductVersion
  if ($v -and -not $v.StartsWith($HandyVersion)) {
    Write-Host "   Handy $v is installed; this setup was tested with $HandyVersion. If dictation misbehaves, install $HandyVersion from $($HandySetup.url)" -ForegroundColor Yellow
  }
}
Write-Host "   $handyExe"

# Handy keeps its settings in memory and writes them back, so it must be closed while they change.
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $handyExe } | Stop-Process -Force
Start-Sleep -Milliseconds 500
$settings = Join-Path $HandyData "settings_store.json"
New-Item -ItemType Directory -Force -Path $HandyData | Out-Null
$edit = @'
import json, os, shutil, sys
path, paste, model = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {}
if os.path.exists(path):
    shutil.copyfile(path, path + ".bak-last-dictation-setup")
    if not os.path.exists(path + ".bak-before-dictation"):
        shutil.copyfile(path, path + ".bak-before-dictation")
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
s = doc.setdefault("settings", {})
fresh = not s
s.update({
    "paste_method": "external_script", "external_script_path": paste,   # the paste program (window you started in)
    "overlay_style": "minimal",          # the recording pill only, no words on screen while you talk
    "word_correction_threshold": 0.05,   # custom words: join exact split-ups only, never rewrite ordinary words
    "hold_threshold_ms": 1000,           # a quick tap is a tap even when the model takes 0.3 s to start
    "update_checks_enabled": False,      # this setup is tested with one Handy version
    "autostart_enabled": True,
})
if model:
    s["selected_model"] = model
if fresh:
    s["onboarding_completed"] = True
def binding(id_, name, desc, default, current=None):
    return {"id": id_, "name": name, "description": desc, "default_binding": default, "current_binding": current or default}
b = s.get("bindings")
if not b:
    s["bindings"] = {
        "transcribe": binding("transcribe", "Transcribe", "Converts your speech into text.", "ctrl+space"),
        "transcribe_with_post_process": binding("transcribe_with_post_process", "Transcribe with Post-Processing",
            "Converts your speech into text and applies AI post-processing.", "ctrl+shift+space"),
        "cancel": binding("cancel", "Cancel", "Cancels the current recording.", "escape", "shift+escape"),
    }
elif b.get("cancel", {}).get("current_binding") == "escape":
    b["cancel"]["current_binding"] = "shift+escape"   # bare Escape cancelled dictations when closing any popup
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2)
os.replace(tmp, path)
print("transcribe shortcut: " + s["bindings"]["transcribe"]["current_binding"])
'@
$editPy = Join-Path $Root "edit_settings.py"
Set-Content -Path $editPy -Value $edit -Encoding UTF8
$shortcut = & $Py $editPy $settings $PasteExe $LiveModel.id
if ($LASTEXITCODE -ne 0) { throw "could not update Handy's settings" }
Remove-Item $editPy -Force
Write-Host "   pastes through the dictation helper, $shortcut, cancel: Shift+Escape"

# --- 5. Start everything, and at every login -------------------------------------------------------------------------
Step "Starting"
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Dictation helper" -Value "`"$HelperExe`""
Start-Process -FilePath $HelperExe
Start-Process -FilePath $handyExe
$ping = @'
import json, socket, sys, time
deadline = time.time() + float(sys.argv[2])
while time.time() < deadline:
    try:
        state = json.load(open(sys.argv[1], encoding="utf-8"))
        with socket.create_connection(("127.0.0.1", state["port"]), timeout=1) as c:
            c.sendall((json.dumps({"token": state["token"], "ping": True}) + "\n").encode())
            print(c.recv(4096).decode()); sys.exit(0)
    except Exception:
        time.sleep(1)
sys.exit(1)
'@
$pingPy = Join-Path $Root "ping.py"
Set-Content -Path $pingPy -Value $ping -Encoding UTF8
Write-Host "   waiting for the helper to load its models (up to 3 minutes the first time)"
$status = & $Py $pingPy (Join-Path $Root "helper.json") 180
$helperOk = $LASTEXITCODE -eq 0
Remove-Item $pingPy -Force
if ($helperOk) {
  $s = $status | ConvertFrom-Json
  Write-Host ("   helper running: accurate pass " + $(if ($s.accurate) { "on" } else { "off (see logs\helper.log)" }) +
              ", punctuation " + $(if ($s.punctuation) { "on" } else { "off" }))
} else {
  Write-Host "   the helper did not answer: Handy still works and pastes its own text. Log: $Root\logs\helper.log" -ForegroundColor Yellow
}

Step "Done"
Write-Host @"
Press Ctrl+Space, talk, press Ctrl+Space again: the text is pasted where you started (hold Ctrl+Space for over
a second to talk only while holding). Shift+Escape cancels. Change the shortcut in Handy's settings (tray icon).

Your words (names, products, jargon that come out wrong): $vocab
One per line, most important first. Used from the next dictation on.

Logs: $Root\logs   Update: run this again   Remove: windows\uninstall.cmd
"@
if (!$CI) { Start-Process notepad.exe $vocab }
