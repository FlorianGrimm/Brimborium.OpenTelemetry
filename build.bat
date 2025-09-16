cd /D %~dp0
pwsh -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 %*