@echo off
REM Run unit sandbox (console build, shows logs/errors).
cd /d "%~dp0"
"D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe" --path . res://Sandbox.tscn
echo.
echo ==== exited, press any key to close ====
pause >nul
