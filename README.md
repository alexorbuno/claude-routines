# claude-routines

Автоматические рутины, запускаемые через Claude Code CLI.

## AI Дайджест (`ai-digest.sh`)

Каждый день собирает свежие новости об ИИ и создаёт красивую страницу в Notion.

**Темы:** языковые модели, генераторы изображений, World Models, OpenClaw и другие тренды.

### Запуск вручную

```bash
bash ai-digest.sh
```

### Ежедневный запуск через cron

```bash
crontab -e
```

Добавить строку (каждый день в 09:00):

```
0 9 * * * /home/user/claude-routines/ai-digest.sh
```

### Требования

- Claude Code CLI (`claude`) в PATH и авторизован
- Настроены MCP-серверы: Notion, WebSearch
