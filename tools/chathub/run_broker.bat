@echo off
REM ChatHub 一键启动（watch 模式）：轮询 docs/chathub.md，Erico 发言即自动召集三席。
REM 前置（一次性）：
REM   1) npm i -g @anthropic-ai/claude-code  且 claude auth 登录（Max 订阅）
REM   2) npm/npx 可用（GPT 走 npx @openai/codex，走 ChatGPT 登录）
REM   3) 设好用户环境变量 DEEPSEEK_API_KEY（本脚本不内嵌 key，从环境继承）
REM   4) py -3 -m pip install -r requirements.txt
chcp 65001 >nul
cd /d "%~dp0"
echo [ChatHub] watch 启动中……在 chathub.md 里以 Erico 身份发言即自动召集。Ctrl-C 退出。
py -3 broker.py --watch
