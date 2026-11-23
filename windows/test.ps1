# Checks a Windows install end to end (run after install.ps1): Handy set up, the accurate pass on spoken audio, and a
# real dictation through the helper and the paste program into Notepad, started in one window and ended in another.
# Uses a stand-in Handy log and a spoken WAV instead of the mic; never touches your own Handy log.
$ErrorActionPreference = "Stop"
$Root = Join-Path $env:LOCALAPPDATA "dictation"
$Py = Join-Path $Root "venv\Scripts\python.exe"
$PasteExe = Join-Path $Root "venv\Scripts\dictation-paste.exe"
$script:fails = 0
function Check($name, $ok, $detail = "") {
  if ($ok) { Write-Host "ok   $name $detail" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fails++ }
}

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class W {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static string Text(IntPtr top) {
    IntPtr e = FindWindowEx(top, IntPtr.Zero, "Edit", null);
    if (e == IntPtr.Zero) e = FindWindowEx(top, IntPtr.Zero, "RichEditD2DPT", null);
    if (e == IntPtr.Zero) return "<no text box found>";
    int n = (int)SendMessage(e, 0x000E, IntPtr.Zero, IntPtr.Zero);
    var sb = new StringBuilder(n + 1);
    SendMessage(e, 0x000D, (IntPtr)(n + 1), sb);
    return sb.ToString();
  }
}
"@

# --- the install --------------------------------------------------------------------------------------------------
Check "paste program installed" (Test-Path $PasteExe)
Check "helper installed" (Test-Path (Join-Path $Root "venv\Scripts\dictation-helper.exe"))
$settings = (Get-Content (Join-Path $env:APPDATA "com.pais.handy\settings_store.json") -Raw | ConvertFrom-Json).settings
Check "Handy pastes through the paste program" ($settings.paste_method -eq "external_script" -and $settings.external_script_path -eq $PasteExe)
Check "Handy uses the live model, which is there" ($settings.selected_model -like "*parakeet*" -and
  (Test-Path (Join-Path $env:APPDATA "com.pais.handy\models\parakeet-unified-en-0.6b-Q8_0.gguf")))
Check "cancel is Shift+Escape" ($settings.bindings.cancel.current_binding -eq "shift+escape")
Check "helper starts at login" ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run")."Dictation helper" -like "*dictation-helper.exe*")
Check "helper is running" (Test-Path (Join-Path $Root "helper.json"))
$handy = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "^handy$" }
Check "Handy is running" ($handy.Count -ge 1)
$handyLog = Join-Path $env:LOCALAPPDATA "com.pais.handy\logs\handy.log"
for ($i = 0; $i -lt 30 -and !(Test-Path $handyLog); $i++) { Start-Sleep 1 }
Check "Handy's log is where the helper reads it" (Test-Path $handyLog)
if (Test-Path $handyLog) { Get-Content $handyLog -Tail 15 | ForEach-Object { Write-Host "   handy: $_" } }

# --- spoken audio -------------------------------------------------------------------------------------------------
$tmp = Join-Path $env:TEMP ("dictation-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$wav = Join-Path $tmp "say.wav"
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$format = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo 16000, ([System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen), ([System.Speech.AudioFormat.AudioChannel]::Mono)
$synth.SetOutputToWaveFile($wav, $format)
$synth.Speak("Ask Priya to update the YellowForce dashboard before Friday afternoon, and check every number twice.")
$synth.Dispose()
$heard = "Ask Maria to update the yellow folder dashboard before Friday afternoon and check every number twice"

$vocab = Join-Path $tmp "vocabulary.txt"
[IO.File]::WriteAllText($vocab, "YellowForce`nPriya`n")
$env:HANDY_ACCURATE_VOCABULARY = $vocab
$model = (Get-ChildItem (Join-Path $Root "models") -Filter "whisper-*.gguf" | Select-Object -First 1).FullName
$env:HANDY_ACCURATE_MODEL = $model
$env:HANDY_PUNCT_MODEL = Join-Path $Root "punct-model"
# A test machine has no graphics card: Whisper takes seconds, not the half second a real PC with one takes.
$env:HANDY_ACCURATE_WAIT = "90"
$env:DICTATION_HELPER_WAIT = "100"

$t0 = Get-Date
$ErrorActionPreference = "Continue"   # Windows PowerShell turns a program's notes on stderr into errors when they are redirected
$out = & $Py -I (Join-Path $Root "app\accurate.py") --file $wav $heard 2>$null
$ErrorActionPreference = "Stop"
Check "accurate pass on spoken audio, your words spelled right" ("$out" -match '"used": "accurate"' -and "$out" -match "YellowForce dashboard") "($out, $([int]((Get-Date) - $t0).TotalSeconds)s)"

$out = & $Py -I (Join-Path $Root "app\punctuate.py") --text "so i tried it twice and it still did not work then i restarted the computer and now it works fine with Claude"
Check "punctuation goes into a long line" ("$out" -like "So*" -and "$out" -like "*.*") "($out)"

# --- a dictation through the helper and the paste program --------------------------------------------------------
# A second helper on a stand-in Handy log, hearing the WAV at each start instead of the mic.
$env:DICTATION_HOME = $tmp
$env:DICTATION_HANDY_LOG = Join-Path $tmp "handy.log"
[IO.File]::WriteAllText($env:DICTATION_HANDY_LOG, "")
$helper = Start-Process -FilePath $Py -ArgumentList @("-m", "dictation_helper", "--test-audio", "`"$wav`"") -PassThru -WindowStyle Hidden
for ($i = 0; $i -lt 180 -and !(Test-Path (Join-Path $tmp "helper.json")); $i++) { Start-Sleep 1 }
Check "test helper ready" (Test-Path (Join-Path $tmp "helper.json"))

$a = Start-Process notepad.exe -PassThru
$a.WaitForInputIdle(10000) | Out-Null
Start-Sleep 1
$a.Refresh()
$startWindow = [W]::GetForegroundWindow()
Write-Host "   start window: $startWindow (Notepad A: $($a.MainWindowHandle))"
Add-Content $env:DICTATION_HANDY_LOG "[2026-11-19][10:00:00][handy_app_lib::managers::audio][INFO] Microphone stream initialized in 70ms"
Start-Sleep 8   # the sentence plays in real time (6 s)
$b = Start-Process notepad.exe -PassThru
$b.WaitForInputIdle(10000) | Out-Null
Start-Sleep 1
$b.Refresh()
Add-Content $env:DICTATION_HANDY_LOG "[2026-11-19][10:00:08][handy_app_lib::managers::transcription][INFO] Live preview finalized in 300ms"
$t0 = Get-Date
$paste = Start-Process -FilePath $PasteExe -ArgumentList "`"$heard`"" -PassThru -Wait
$ms = [int]((Get-Date) - $t0).TotalMilliseconds
Start-Sleep 1
$textA = [W]::Text($a.MainWindowHandle)
$textB = [W]::Text($b.MainWindowHandle)
$front = [W]::GetForegroundWindow()
Write-Host "   Notepad A: '$textA'"
Write-Host "   Notepad B: '$textB'"
Write-Host "   the paste program took $ms ms (Whisper on this machine's processor, no graphics card)"
Check "the text lands in the window the dictation started in" ($textA -match "YellowForce dashboard") "('$textA')"
Check "nothing lands in the window you are in now" ($textB -eq "") "('$textB')"
Check "you are back where you were" ($front -eq $b.MainWindowHandle) "($front)"
Check "the words stay on the clipboard" ((Get-Clipboard) -match "dashboard")

# Without the helper: Handy's own text, where you are.
Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $tmp "helper.json") -Force -ErrorAction SilentlyContinue
$env:DICTATION_DRY = "1"
$out = & $Py -m dictation_paste "plain words"
Check "no helper: Handy's text, where you are" ("$out" -like "here | plain words | Handy's text: helper not running*") "($out)"
Remove-Item Env:\DICTATION_DRY

foreach ($f in "helper.log", "paste.log", "accurate.log") {
  $p = Join-Path $tmp "logs\$f"
  if (Test-Path $p) { Get-Content $p | ForEach-Object { Write-Host "   ${f}: $_" } }
}
$a, $b | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
if ($script:fails -eq 0) { Write-Host "all passed" -ForegroundColor Green; exit 0 }
Write-Host "$($script:fails) failed" -ForegroundColor Red
exit 1
