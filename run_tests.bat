@echo off
REM 批量跑所有 headless 回归测试（tools/test_*.gd）。全绿 exit 0、有失败 exit 1。
cd /d "%~dp0"
pwsh -NoProfile -File "%~dp0tools\run_tests.ps1"
echo.
echo ==== exited, press any key to close ====
pause >nul
