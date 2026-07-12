# 批量跑 headless 回归测试：枚举 tools/test_*.gd 逐个 -s 运行，汇总 PASS/FAIL，全绿 → exit 0。
# 用法：pwsh -NoProfile -File tools/run_tests.ps1   （或双击项目根 run_tests.bat）
# 之前无中央 runner，测试的回归护栏全靠人工逐个跑（2026-07-05 review 发现）——本脚本操作化「N 套基线」。
# 2026-07-12（技改 §4-3）：①每套 120s 超时（SceneTree 脚本空转曾烧数小时——超时即杀进程标 TIMEOUT）；
# ②输出落临时日志，FAIL/TIMEOUT 打印日志尾部（此前 *> $null 全丢，失败只能重跑人肉看）。
# Godot 路径默认取控制台版，可用环境变量 GODOT 覆盖；TEST_TIMEOUT_S 覆盖单套超时秒数。
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe" }
$timeoutS = if ($env:TEST_TIMEOUT_S) { [int]$env:TEST_TIMEOUT_S } else { 120 }
if (-not (Test-Path $godot)) {
    Write-Host "找不到 Godot：$godot（设 GODOT 环境变量覆盖）" -ForegroundColor Red
    exit 2
}
$logDir = Join-Path ([IO.Path]::GetTempPath()) "zhanqi_tests"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$tests = Get-ChildItem -Path (Join-Path $root "tools") -Filter "test_*.gd" | Sort-Object Name
$pass = 0; $fail = 0; $failed = @()
foreach ($t in $tests) {
    $log = Join-Path $logDir ($t.BaseName + ".log")
    $errLog = Join-Path $logDir ($t.BaseName + ".err.log")
    $p = Start-Process -FilePath $godot -ArgumentList @("--headless", "--path", $root, "-s", ("res://tools/" + $t.Name)) `
        -RedirectStandardOutput $log -RedirectStandardError $errLog -PassThru -NoNewWindow
    $done = $p.WaitForExit($timeoutS * 1000)
    if (-not $done) {
        try { $p.Kill($true) } catch {}
        $fail++
        $failed += ($t.Name + " [TIMEOUT]")
        Write-Host ("  TIMEOUT  " + $t.Name + "  (>" + $timeoutS + "s，进程已杀——查空转/未 quit)") -ForegroundColor Red
        Write-Host ("    日志：" + $log) -ForegroundColor DarkGray
        Get-Content $log, $errLog -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Write-Host ("    | " + $_) -ForegroundColor DarkGray }
        continue
    }
    if ($p.ExitCode -eq 0) {
        $pass++
        Write-Host ("  PASS  " + $t.Name) -ForegroundColor Green
    } else {
        $fail++
        $failed += $t.Name
        Write-Host ("  FAIL  " + $t.Name + "  (exit " + $p.ExitCode + ")") -ForegroundColor Red
        Write-Host ("    日志：" + $log) -ForegroundColor DarkGray
        Get-Content $log, $errLog -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Write-Host ("    | " + $_) -ForegroundColor DarkGray }
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
