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

## Qwen-Image-Layered для ComfyUI (`scripts/setup-qwen-image-layered.ps1`)

Ставит в локальный ComfyUI (Desktop или portable) модель
[Qwen-Image-Layered](https://comfyui-wiki.com/en/news/2025-12-19-qwen-image-layered-release) —
разбор картинки на редактируемые RGBA-слои — плюс LoRA
[Stable-Layers](https://stability-ai.github.io/stable-layers.github.io/) от Stability AI
(дообучение базовой модели через Flow-GRPO с VLM-наградой).

Скрипт сам находит папку ComfyUI, тянет имена файлов из HuggingFace API
(не хардкодит их, поэтому не ломается при переименованиях), качает через `curl`
с докачкой и ставит `ComfyUI-GGUF`, если выбран GGUF-квант.

### Запуск (Windows, PowerShell)

```powershell
# Быстрый старт: лёгкий квант + удобные ноды
powershell -ExecutionPolicy Bypass -File .\scripts\setup-qwen-image-layered.ps1 -Quant q4_k_m -Extras

# Другой квант и явный путь к ComfyUI
powershell -ExecutionPolicy Bypass -File .\scripts\setup-qwen-image-layered.ps1 -Quant fp8 -ComfyUIPath "D:\ComfyUI"
```

Ключ `-Extras` доставляет две ноды:

- [**ComfyUI-Layers**](https://github.com/alessandrozonta/ComfyUI-Layers) — складывает
  батч слоёв в один `.psd`. Без неё ComfyUI сохранит слои россыпью PNG, и собирать
  их в Photoshop придётся руками.
- [**ComfyUI-Crystools**](https://github.com/crystian/ComfyUI-Crystools) — монитор
  VRAM/RAM в интерфейсе, помогает подбирать квант и разрешение без угадывания.

### Выбор точности

| `-Quant` | Размер | Кому |
|----------|--------|------|
| `q4_k_m` | ~13 ГБ | 12–16 ГБ VRAM, быстро, качество заметно ниже |
| `q6_k`   | ~17 ГБ | **по умолчанию, оптимум для 24 ГБ** |
| `q8_0`   | ~22 ГБ | 24 ГБ впритык, будет оффлоад в RAM |
| `fp8`    | ~20 ГБ | официальный `fp8mixed`, без custom nodes |
| `bf16`   | ~41 ГБ | только для 48 ГБ+ |

Для GGUF нужен `models/unet`, для fp8/bf16 — `models/diffusion_models`;
скрипт раскладывает файлы сам.

### Что важно помнить в workflow

- У Qwen-Image-Layered **свой VAE** — обычный `qwen_image_vae` не отдаёт альфа-канал.
- Для fp8 нужен именно `fp8mixed`; обычный `fp8_e4m3fn` эту модель ломает.
- Число слоёв задаётся виджетом `layers` на ноде `Empty Qwen Image Layered Latent`.
  На выходе `layers + 1` картинок — первая это полное изображение, а не слой.
- Стартовое разрешение ~640 px по короткой стороне; выше разделение слоёв деградирует.
- LoRA Stable-Layers подключается нодой `LoraLoaderModelOnly`, работает и поверх GGUF.
