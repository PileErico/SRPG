@echo off
REM 打开游戏（主菜单 StartMenu = 正式入口；console build，能看日志/报错）。
cd /d "%~dp0"
"D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe" --path . res://StartMenu.tscn
echo.
echo ==== exited, press any key to close ====
pause >nul
