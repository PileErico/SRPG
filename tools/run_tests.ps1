# 批量跑 headless 回归测试：枚举 tools/test_*.gd 逐个 -s 运行，汇总 PASS/FAIL，全绿 → exit 0。
# 用法：pwsh -NoProfile -File tools/run_tests.ps1   （或双击项目根 run_tests.bat）
# 之前无中央 runner，测试的回归护栏全靠人工逐个跑（2026-07-05 review 发现）——本脚本操作化「N 套基线」。
# Godot 路径默认取控制台版，可用环境变量 GODOT 覆盖。
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe" }
if (-not (Test-Path $godot)) {
    Write-Host "找不到 Godot：$godot（设 GODOT 环境变量覆盖）" -ForegroundColor Red
    exit 2
}
$tests = Get-ChildItem -Path (Join-Path $root "tools") -Filter "test_*.gd" | Sort-Object Name
$pass = 0; $fail = 0; $failed = @()
foreach ($t in $tests) {
    & $godot --headless --path $root -s ("res://tools/" + $t.Name) *> $null
    if ($LASTEXITCODE -eq 0) {
        $pass++
        Write-Host ("  PASS  " + $t.Name) -ForegroundColor Green
    } else {
        $fail++
        $failed += $t.Name
        Write-Host ("  FAIL  " + $t.Name + "  (exit " + $LASTEXITCODE + ")") -ForegroundColor Red
    }
}
Write-Host ""
Write-Host ("汇总：PASS=$pass  FAIL=$fail  / 共 " + $tests.Count + " 套") -ForegroundColor Cyan
if ($fail -gt 0) {
    Write-Host ("失败：" + ($failed -join ", ")) -ForegroundColor Red
    exit 1
}
Write-Host "全部 PASS" -ForegroundColor Green
exit 0
