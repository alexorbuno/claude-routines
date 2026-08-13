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

## Qwen-Image для ComfyUI (`scripts/setup-qwen-image.ps1`)

Ставит в локальный ComfyUI (Desktop или portable) модели семейства Qwen-Image:

- **`-Model layered`** — [Qwen-Image-Layered](https://comfyui-wiki.com/en/news/2025-12-19-qwen-image-layered-release):
  разбирает картинку на редактируемые RGBA-слои. Плюс LoRA
  [Stable-Layers](https://stability-ai.github.io/stable-layers.github.io/) от Stability AI
  (дообучение базовой модели через Flow-GRPO с VLM-наградой).
- **`-Model edit`** — [Qwen-Image-Edit-2511](https://blog.comfy.org/p/qwen-image-edit-2511-and-qwen-image):
  правит изображение по текстовой инструкции. С `-Lightning` доедет
  [4-шаговая LoRA](https://huggingface.co/lightx2v/Qwen-Image-Edit-2511-Lightning) вместо 40 шагов.
- **`-Model base`** — [Qwen-Image-2512](https://docs.comfy.org/tutorials/image/qwen/qwen-image-2512):
  генерация с нуля. Декабрьская ревизия базовой модели — реалистичнее люди,
  детальнее текстуры и заметно точнее рендеринг текста на изображении.
- **`-Model both`** — layered + edit. **`-Model all`** — все три. Text encoder
  и VAE общие, так что каждая следующая модель докачивает только свой DiT.

Скрипт сам находит папку ComfyUI, тянет имена файлов из HuggingFace API
(не хардкодит их, поэтому не ломается при переименованиях), перебирает несколько
репозиториев-зеркал, качает через `curl` с докачкой и ставит `ComfyUI-GGUF`,
если выбран GGUF-квант.

### Запуск (Windows, PowerShell)

```powershell
# Слои: лёгкий квант + удобные ноды
powershell -ExecutionPolicy Bypass -File .\scripts\setup-qwen-image.ps1 -Model layered -Quant q4_k_m -Extras

# Редактирование с ускорением до 4 шагов
powershell -ExecutionPolicy Bypass -File .\scripts\setup-qwen-image.ps1 -Model edit -Quant q4_k_m -Lightning

# Всё сразу: три модели, ускорение, ракурсы, ControlNet, inpaint, QoL-ноды
powershell -ExecutionPolicy Bypass -File .\scripts\setup-qwen-image.ps1 -Model all -Quant q4_k_m -Lightning -Angles -ControlNet -Inpaint -Extras
```

Ключ `-Angles` (только для `edit`) ставит управление ракурсом съёмки:

- [**Multiple-Angles LoRA**](https://huggingface.co/fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA) —
  96 позиций камеры (8 азимутов × 4 высоты × 3 крупности), обучена на рендерах
  Gaussian Splatting. Именно она поворачивает сцену.
- [**ComfyUI-qwenmultiangle**](https://github.com/jtydhr88/ComfyUI-qwenmultiangle) —
  3D-вьюпорт на Three.js прямо в ноде: ракурс задаётся мышью, а на выход идёт
  готовый текстовый промпт. Без LoRA нода бесполезна — ракурс будет молча игнорироваться.

Ключ `-ControlNet` кладёт [DiffSynth ControlNet-патчи](https://huggingface.co/Comfy-Org/Qwen-Image-DiffSynth-ControlNets)
(canny, depth, inpaint) в `models/model_patches`. Важно: в ComfyUI они грузятся
нодой `ModelPatchLoader`, а не обычным `Load ControlNet Model` — тот их не увидит.
Для работы с 3D-рендерами это основной инструмент: Z-Depth и clay-проход подаются
напрямую, препроцессор не нужен.

Ключ `-Inpaint` добавляет [Easy Inpaint LoRA](https://civitai.com/models/1928341/qwen-image-edit-easy-inpaint-lora)
к edit-модели (качается с [зеркала на HF](https://huggingface.co/UnifiedHorusRA/Qwen_Image_Edit_Easy_Inpaint_LoRA)).
Механика простая до предела: закрашиваете область чёрным в любом редакторе и
начинаете промпт словами `Inpaint the black areas.` — ни масок, ни нод препроцессинга.

Ключ `-Extras` доставляет:

- [**ComfyUI-Layers**](https://github.com/alessandrozonta/ComfyUI-Layers) (только для
  `layered`) — складывает батч слоёв в один `.psd`. Без неё ComfyUI сохранит слои
  россыпью PNG, и собирать их в Photoshop придётся руками.
- [**ComfyUI-Crystools**](https://github.com/crystian/ComfyUI-Crystools) — монитор
  VRAM/RAM в интерфейсе, помогает подбирать квант и разрешение без угадывания.

### Выбор точности

| `-Quant` | Размер | Кому |
|----------|--------|------|
| `q4_k_m` | ~13 ГБ | 12–16 ГБ VRAM, быстро, качество заметно ниже |
| `q6_k`   | ~17 ГБ | **по умолчанию, оптимум для 24 ГБ** |
| `q8_0`   | ~22 ГБ | 24 ГБ впритык, будет оффлоад в RAM |
| `fp8`    | ~20 ГБ | официальные сборки Comfy-Org, без custom nodes |
| `bf16`   | ~41 ГБ | только для 48 ГБ+ |

Для GGUF нужен `models/unet`, для fp8/bf16 — `models/diffusion_models`;
скрипт раскладывает файлы сам.

### Что важно помнить в workflow

Общее:

- Для GGUF в шаблоне надо заменить `Load Diffusion Model` на `Unet Loader (GGUF)`.
  Шаблоны приходят как Subgraph — чтобы добраться до лоадеров, зайдите внутрь двойным кликом.

`layered`:

- **Свой VAE** — обычный `qwen_image_vae` не отдаёт альфа-канал.
- Для fp8 нужен именно `fp8mixed`; обычный `fp8_e4m3fn` эту модель ломает.
- Число слоёв задаётся виджетом `layers` на ноде `Empty Qwen Image Layered Latent`.
  На выходе `layers + 1` картинок — первая это полное изображение, а не слой.
- Стартовое разрешение ~640 px по короткой стороне; выше разделение слоёв деградирует.
- LoRA Stable-Layers подключается нодой `LoraLoaderModelOnly`, работает и поверх GGUF.

`edit`:

- VAE здесь **обычный** (`qwen_image_vae`), не layered.
- Исходная картинка идёт в ноду `TextEncodeQwenImageEdit` вместе с инструкцией —
  она кодирует изображение и промпт совместно, обычный `CLIP Text Encode` не подойдёт.
- Без Lightning LoRA: ~40 шагов, cfg 4.0. С Lightning: 4 шага, cfg **1.0** —
  на cfg 4.0 с 4 шагами получите пересвет и артефакты.

`base`:

- Обычный txt2img: `Empty Latent Image` → KSampler, картинка на входе не нужна.
- Lightning LoRA здесь **своя**, не та что у `edit`. Обе лежат в `loras`
  и различаются по имени — чужая даст замыленный результат.
- Надписи пишите в промпте в кавычках, так модель воспроизводит их точнее.

## InvokeAI на тех же моделях

[InvokeAI](https://invoke.ai) — отдельное приложение, не надстройка над ComfyUI.
Весной 2026 в него влили [полную поддержку Qwen-Image](https://github.com/invoke-ai/InvokeAI)
(base и edit, вместе с LoRA, GGUF и квантованием), поэтому модели, скачанные
скриптом выше, можно переиспользовать — заново качать десятки гигабайт не нужно.

### Установка

Ставить только через [Invoke Launcher](https://github.com/invoke-ai/launcher/releases) —
он сам подтягивает нужный Python и запускает Invoke как десктопное приложение.
Ручной `pip install` не нужен и создаёт проблемы с версиями.

При установке укажите корневую директорию **не на системном диске**: Invoke хранит
там модели, базу и изображения, и объём растёт быстро.

### Подключение уже скачанных моделей

`Model Manager` → `Scan Folder` → вставить путь → `Scan`. Сканировать по очереди:

```
<ComfyUI>\models\unet            GGUF-версии DiT
<ComfyUI>\models\text_encoders   Qwen2.5-VL
<ComfyUI>\models\vae
<ComfyUI>\models\loras
```

Ключевой момент — чекбокс **Inplace install** в диалоге импорта:

- **включён** — Invoke ссылается на файлы там, где они лежат. Ничего не дублируется,
  но при удалении или переносе моделей ComfyUI сломается Invoke.
- **выключен** — Invoke копирует файлы к себе. Так советует официальная документация,
  но каждая модель займёт место дважды.

При 40+ ГБ моделей разумнее включить, понимая цену.

### Чего ожидать не стоит

- **Layered-модель, скорее всего, не поддержана.** Заявлены base и edit; разбор
  на RGBA-слои — отдельная архитектура. Для слоёв остаётся ComfyUI.
- **Свой torch.** Invoke ставит собственное окружение, поэтому проблемы с версией
  torch в ComfyUI туда не переезжают — это плюс, но и обновлять их надо раздельно.
