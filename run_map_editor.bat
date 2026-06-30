@echo off
REM Run map editor (MapEditor.tscn, console build).
cd /d "%~dp0"
"D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe" --path . res://MapEditor.tscn
echo.
echo ==== exited, press any key to close ====
pause >nul
