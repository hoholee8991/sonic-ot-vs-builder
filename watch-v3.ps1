# watch-v3.ps1 - V3 build auto-babysitter (ASCII only for PS 5.1)
# Detects WSL disconnect (A4: 0x8007274c) -> recovers -> resumes build.sh full
# Stops when build logs EXIT=0 (success) or a real failure.
$LogFile = "$env:USERPROFILE\watch-v3.log"
function Log($m) { Add-Content -Path $LogFile -Value ("{0} {1}" -f (Get-Date -Format 'MM-dd HH:mm:ss'), $m) }

Log "=== watcher started ==="
while ($true) {
  $status = ""
  try {
    $r = wsl -d Ubuntu-26.04 -- bash -c 'tail -1 /home/user/sonic-buildimage-v2/make-build.log 2>/dev/null'
    if ($LASTEXITCODE -ne 0 -or -not $r) { throw "wsl unreachable" }
    $status = "$r"
    if ($status -match "EXIT=0") { Log "BUILD SUCCESS: $status"; break }
    if ($status -match "EXIT=[1-9]") { Log "BUILD FAILED: $status"; break }
    Log "ok: $status"
  } catch {
    Log "WSL down - recovering (last: $status)"
    wsl --shutdown
    Start-Sleep -Seconds 25
    $d = wsl -d Ubuntu-26.04 -- bash -c 'systemctl is-active docker && docker rm -f ot-vs-build >/dev/null 2>&1; cd /home/user/sonic-buildimage-v2 && SRC=/home/user/sonic-buildimage-v2 /home/user/builder/build.sh full | tail -1' 2>&1
    Log "relaunch: $d"
    Start-Sleep -Seconds 60
    continue
  }
  Start-Sleep -Seconds 300
}
Log "=== watcher ended ==="
