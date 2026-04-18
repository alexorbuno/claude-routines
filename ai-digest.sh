#!/usr/bin/env bash
# Daily AI digest — runs via cron, invokes Claude Code CLI with the digest prompt
set -euo pipefail

LOG_FILE="$(dirname "$0")/ai-digest.log"
PROMPT="Каждый день собирай последние новости про ИИ, генераторы изображений, World Models, OpenClaw и всё остальное, что стоит внимания. Создавай короткую красивую страницу в Notion."

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting AI digest..." >> "$LOG_FILE"

claude --print "$PROMPT" >> "$LOG_FILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done." >> "$LOG_FILE"
