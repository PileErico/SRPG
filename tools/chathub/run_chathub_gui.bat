@echo off
chcp 65001 >nul
title ChatHub server - close this window to stop
cd /d "D:\1战棋\tools\chathub"
set CHATHUB_NO_AUTO_OPEN=1
echo ============================================================
echo   ChatHub starting...  browser will open in ~3s:
echo   http://127.0.0.1:8765
echo   (if it does not open, type that address in your browser)
echo   This window IS the server - close it to stop.
echo ============================================================
REM 用 PowerShell 延迟 3 秒后可靠地打开默认浏览器（比 Python webbrowser 稳）
start "" /b powershell -NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 3; Start-Process 'http://127.0.0.1:8765'"
py -3 gui\server.py
echo.
echo Server stopped. Press any key to close.
pause >nul
