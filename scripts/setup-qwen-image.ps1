<#
.SYNOPSIS
    Ставит модели семейства Qwen-Image в локальный ComfyUI: layered (разбор на
    RGBA-слои) или edit (редактирование по текстовой инструкции).

.DESCRIPTION
    Скрипт:
      1. Находит папку моделей ComfyUI (в т.ч. ComfyUI Desktop).
      2. Определяет реальные имена файлов через HuggingFace API (не хардкодит их),
         перебирая несколько репозиториев-источников.
      3. Скачивает DiT нужной точности, text encoder, нужный VAE и LoRA.
      4. Ставит custom node ComfyUI-GGUF, если выбран GGUF-квант.
    Загрузки идут через curl.exe с докачкой (-C -) - можно прерывать и запускать заново.
    Text encoder общий для обеих моделей, поэтому второй прогон скачает заметно меньше.

.PARAMETER Model
    layered - Qwen-Image-Layered: раскладывает картинку на редактируемые RGBA-слои.
    edit    - Qwen-Image-Edit-2511: правит картинку по текстовой инструкции.
    base    - Qwen-Image-2512: генерация с нуля, сильный рендеринг текста.
    both    - layered + edit.
    all     - все три.

.PARAMETER Quant
    Точность DiT. Ориентиры по размеру даны для 20B-модели.
      q4_k_m  ~13 ГБ  быстро, заметнее потери качества
      q6_k    ~17 ГБ  оптимум для 24 ГБ VRAM
      q8_0    ~22 ГБ  максимум качества GGUF, на 24 ГБ впритык
      fp8     ~20 ГБ  официальный fp8 от Comfy-Org, без custom nodes
      bf16    ~41 ГБ  полная точность, нужно 48 ГБ+

.PARAMETER ComfyUIPath
    Корень ComfyUI (папка, внутри которой лежит models\). Если не указан - автопоиск.

.PARAMETER Lightning
    Скачать Lightning LoRA - дистилляция до 4 шагов вместо 40 (cfg ставить 1.0).
    Есть только для edit; для layered официальной сборки нет.

.PARAMETER SkipLora
    Не качать LoRA Stable-Layers для layered-модели.

.PARAMETER Extras
    Доставить QoL custom nodes: экспорт слоёв в PSD и монитор VRAM в интерфейсе.

.PARAMETER Angles
    Управление ракурсом для edit: LoRA Multiple-Angles плюс нода с 3D-вьюпортом,
    в которой ракурс задаётся мышью, а не текстом.

.PARAMETER ControlNet
    DiffSynth ControlNet-патчи (canny, depth, inpaint) в models\model_patches.
    Управление композицией по карте глубины или контурам - для работы с рендерами.

.PARAMETER Inpaint
    Easy Inpaint LoRA к edit-модели: закрашиваешь область чёрным, промпт начинаешь
    со слов "Inpaint the black areas." - без масок и нод препроцессинга.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model layered -Quant q4_k_m -Extras

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model edit -Quant q4_k_m -Lightning

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model both -Quant q4_k_m -Lightning -Extras
#>

[CmdletBinding()]
param(
    [ValidateSet('layered', 'edit', 'base', 'both', 'all')]
    [string]$Model = 'layered',

    [ValidateSet('q4_k_m', 'q6_k', 'q8_0', 'fp8', 'bf16')]
    [string]$Quant = 'q6_k',

    [string]$ComfyUIPath,

    [switch]$Lightning,

    [switch]$SkipLora,

    [switch]$Extras,

    [switch]$Angles,

    [switch]$ControlNet,

    [switch]$Inpaint
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 по умолчанию печатает в консоль в кодировке кодовой страницы
# (866/1251), из-за чего кириллица в выводе рассыпается. Сам файл сохранён с UTF-8 BOM,
# чтобы парсер прочитал его верно; здесь дополнительно выравниваем вывод консоли.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Не критично: в некоторых хостах (ISE, редиректы) консоль недоступна.
}

$IsGGUF = $Quant -in 'q4_k_m', 'q6_k', 'q8_0'

# Общий для всей линейки Qwen-Image: text encoder и обычный VAE лежат тут.
$RepoQwenImg = 'Comfy-Org/Qwen-Image_ComfyUI'

# --- Источники DiT. Списками, потому что зеркала GGUF появляются и исчезают
#     независимо от официальных сборок Comfy-Org: берётся первый доступный.
if ($IsGGUF) {
    $LayeredDitRepos = @('QuantStack/Qwen-Image-Layered-GGUF', 'unsloth/Qwen-Image-Layered-GGUF')
    $EditDitRepos    = @('QuantStack/Qwen-Image-Edit-2511-GGUF',
                         'unsloth/Qwen-Image-Edit-2511-GGUF',
                         'QuantStack/Qwen-Image-Edit-GGUF')
    $BaseDitRepos    = @('unsloth/Qwen-Image-2512-GGUF',
                         'byteshape/Qwen-Image-2512-GGUF',
                         'QuantStack/Qwen-Image-GGUF',
                         'city96/Qwen-Image-gguf')
} else {
    $LayeredDitRepos = @('Comfy-Org/Qwen-Image-Layered_ComfyUI')
    $EditDitRepos    = @('Comfy-Org/Qwen-Image-Edit_ComfyUI')
    $BaseDitRepos    = @('Comfy-Org/Qwen-Image_ComfyUI')
}

# --- Паттерны имён файлов. {0} подставляется как тег кванта (Q4_K_M и т.п.).
if ($IsGGUF) {
    $LayeredDitPatterns = @('(?i)layered.*-{0}\.gguf$', '(?i)-{0}\.gguf$', '(?i){0}.*\.gguf$')
    $EditDitPatterns    = @('(?i)2511.*-{0}\.gguf$', '(?i)-{0}\.gguf$', '(?i){0}.*\.gguf$')
    # 2512 - свежая ревизия базовой модели; старые репозитории отдадут первую версию,
    # поэтому сначала ищем по номеру ревизии и только потом по любому совпадению.
    $BaseDitPatterns    = @('(?i)2512.*-{0}\.gguf$', '(?i)-{0}\.gguf$', '(?i){0}.*\.gguf$')
} elseif ($Quant -eq 'fp8') {
    # Для layered годится ТОЛЬКО fp8mixed: обычный fp8_e4m3fn ломает вывод.
    $LayeredDitPatterns = @('(?i)layered.*fp8.?mixed.*\.safetensors$', '(?i)fp8.?mixed.*\.safetensors$')
    $EditDitPatterns    = @('(?i)edit.*2511.*fp8.*\.safetensors$', '(?i)edit.*fp8.*\.safetensors$')
    $BaseDitPatterns    = @('(?i)qwen_image_2512.*fp8.*\.safetensors$',
                            '(?i)diffusion_models/qwen_image_fp8.*\.safetensors$')
} else {
    $LayeredDitPatterns = @('(?i)layered.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
    $EditDitPatterns    = @('(?i)edit.*2511.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
    $BaseDitPatterns    = @('(?i)qwen_image_2512.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
}

# --- LoRA. Список: у edit их может быть несколько сразу (ускорение + ракурсы),
#     они не конфликтуют и вешаются цепочкой.
$LayeredLoras = @()
if (-not $SkipLora) {
    $LayeredLoras += @{
        Repos    = @('StabilityLabs/Stable-Layers')
        Patterns = @('(?i)\.safetensors$')
        Label    = 'LoRA Stable-Layers'
        Prefix   = 'stable-layers'
    }
}

$EditLoras = @()
if ($Lightning) {
    $EditLoras += @{
        Repos    = @('lightx2v/Qwen-Image-Edit-2511-Lightning')
        # 4 шага - самый выгодный размен; bf16-вариант работает и поверх GGUF.
        Patterns = @('(?i)4steps.*bf16.*\.safetensors$', '(?i)4steps.*\.safetensors$',
                     '(?i)8steps.*\.safetensors$', '(?i)\.safetensors$')
        Label    = 'Lightning LoRA (4 шага)'
        Prefix   = 'qwen-image-edit-2511-lightning'
    }
}
if ($Angles) {
    $EditLoras += @{
        # Вариант под 2509 - запасной: он для предыдущей версии модели, качество
        # на 2511 ниже, но лучше чем ничего, если основной репозиторий недоступен.
        Repos    = @('fal/Qwen-Image-Edit-2511-Multiple-Angles-LoRA',
                     'dx8152/Qwen-Edit-2509-Multiple-angles')
        Patterns = @('(?i)\.safetensors$')
        Label    = 'Multiple-Angles LoRA (управление ракурсом)'
        Prefix   = 'qwen-image-edit-multiple-angles'
    }
}
if ($Inpaint) {
    $EditLoras += @{
        # UnifiedHorusRA - зеркало Civitai на HF. Запасной ostris работает иначе:
        # там закрашивают зелёным, а не чёрным, и промпт формулируется по-другому.
        Repos    = @('UnifiedHorusRA/Qwen_Image_Edit_Easy_Inpaint_LoRA',
                     'ostris/qwen_image_edit_inpainting')
        Patterns = @('(?i)\.safetensors$')
        Label    = 'Easy Inpaint LoRA'
        Prefix   = 'qwen-image-edit-easy-inpaint'
    }
}

# Базовая модель ускоряется своей Lightning LoRA - не той, что у edit.
$BaseLoras = @()
if ($Lightning) {
    $BaseLoras += @{
        Repos    = @('lightx2v/Qwen-Image-Lightning')
        Patterns = @('(?i)4steps.*V2.*\.safetensors$', '(?i)4steps.*\.safetensors$',
                     '(?i)8steps.*\.safetensors$')
        Label    = 'Lightning LoRA для базовой модели'
        Prefix   = 'qwen-image-lightning'
    }
}

$ModelSpecs = @{
    layered = @{
        Title        = 'Qwen-Image-Layered (разбор на RGBA-слои)'
        DitRepos     = $LayeredDitRepos
        DitPatterns  = $LayeredDitPatterns
        # У layered свой VAE, умеющий альфа-канал. Обычный qwen_image_vae не подойдёт.
        VaeRepos     = @('Comfy-Org/Qwen-Image-Layered_ComfyUI')
        VaePatterns  = @('(?i)vae/.*layered.*\.safetensors$', '(?i)vae/.*\.safetensors$')
        Loras        = $LayeredLoras
    }
    edit = @{
        Title        = 'Qwen-Image-Edit-2511 (правка по инструкции)'
        DitRepos     = $EditDitRepos
        DitPatterns  = $EditDitPatterns
        # Edit работает на обычном VAE линейки Qwen-Image.
        VaeRepos     = @('Comfy-Org/Qwen-Image_ComfyUI', 'Comfy-Org/Qwen-Image-Edit_ComfyUI')
        VaePatterns  = @('(?i)vae/qwen_image_vae\.safetensors$', '(?i)vae/.*\.safetensors$')
        Loras        = $EditLoras
    }
    base = @{
        Title        = 'Qwen-Image-2512 (генерация с нуля)'
        DitRepos     = $BaseDitRepos
        DitPatterns  = $BaseDitPatterns
        VaeRepos     = @('Comfy-Org/Qwen-Image_ComfyUI')
        VaePatterns  = @('(?i)vae/qwen_image_vae\.safetensors$', '(?i)vae/.*\.safetensors$')
        Loras        = $BaseLoras
    }
}

$Targets = switch ($Model) {
    'both'  { @('layered', 'edit') }
    'all'   { @('layered', 'edit', 'base') }
    default { @($Model) }
}

function Write-Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]  $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- ComfyUI path

function Find-ComfyUIRoots {
    # Возвращает ВСЕ найденные установки с пометкой, откуда взялся путь.
    # Молча выбирать первую нельзя: на одной машине часто стоят и portable, и Desktop,
    # а Desktop к тому же умеет ссылаться на папку моделей от portable.
    $found = @()

    # ComfyUI Desktop держит путь к моделям в extra_models_config.yaml.
    # Секций с base_path в файле может быть несколько - собираем все.
    $cfg = Join-Path $env:APPDATA 'ComfyUI\extra_models_config.yaml'
    if (Test-Path $cfg) {
        $section = ''
        foreach ($line in Get-Content $cfg) {
            if ($line -match '^(\S+):\s*$') { $section = $Matches[1]; continue }
            if ($line -match '^\s*base_path:\s*(.+?)\s*$') {
                $p = $Matches[1].Trim('"').Trim("'")
                if (Test-Path (Join-Path $p 'models')) {
                    $found += [pscustomobject]@{
                        Path   = (Resolve-Path $p).Path
                        Source = "extra_models_config.yaml, секция '$section'"
                    }
                }
            }
        }
    }

    foreach ($c in @(
        (Join-Path $env:USERPROFILE 'Documents\ComfyUI'),
        (Join-Path $env:USERPROFILE 'ComfyUI'),
        'C:\ComfyUI',
        'D:\ComfyUI'
    )) {
        if (Test-Path (Join-Path $c 'models')) {
            $found += [pscustomobject]@{ Path = (Resolve-Path $c).Path; Source = 'типовой путь установки' }
        }
    }

    # Уникальные пути, порядок сохраняем: конфиг Desktop важнее догадок.
    return $found | Group-Object Path | ForEach-Object { $_.Group[0] }
}

Write-Step 'Поиск ComfyUI'
if (-not $ComfyUIPath) {
    $roots = @(Find-ComfyUIRoots)

    if ($roots.Count -eq 0) {
        Write-Host @'
Не удалось найти ComfyUI автоматически.

Открой ComfyUI Desktop -> Settings (шестерёнка) -> About / Server-Config,
там указана директория установки. Затем запусти скрипт с этим путём:

  powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -ComfyUIPath "C:\путь\к\ComfyUI"

Нужная папка - та, внутри которой лежит подпапка models\.
'@ -ForegroundColor Red
        exit 1
    }

    if ($roots.Count -gt 1) {
        # Несколько установок - выбор за пользователем, 37 ГБ не туда это дорого.
        Write-Host "`nНайдено несколько установок ComfyUI:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $roots.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $roots[$i].Path)
            Write-Host ("      источник: {0}" -f $roots[$i].Source) -ForegroundColor DarkGray
        }
        Write-Host ''
        $answer = Read-Host "Куда ставить модели? Номер 1-$($roots.Count), или Enter для отмены"
        $idx = 0
        if (-not [int]::TryParse($answer, [ref]$idx) -or $idx -lt 1 -or $idx -gt $roots.Count) {
            Write-Host 'Отменено. Запусти снова с явным -ComfyUIPath "путь".' -ForegroundColor Red
            exit 1
        }
        $ComfyUIPath = $roots[$idx - 1].Path
    } else {
        $ComfyUIPath = $roots[0].Path
        Write-Host ("  источник пути: {0}" -f $roots[0].Source) -ForegroundColor DarkGray
    }
}

$ModelsDir = Join-Path $ComfyUIPath 'models'
if (-not (Test-Path $ModelsDir)) {
    Write-Host "В '$ComfyUIPath' нет подпапки models\ - это не корень ComfyUI." -ForegroundColor Red
    exit 1
}
Write-Ok "ComfyUI: $ComfyUIPath"

# GGUF ComfyUI ищет в models\unet, safetensors - в models\diffusion_models
$DirDiT     = Join-Path $ModelsDir $(if ($IsGGUF) { 'unet' } else { 'diffusion_models' })
$DirTextEnc = Join-Path $ModelsDir 'text_encoders'
$DirVae     = Join-Path $ModelsDir 'vae'
$DirLora    = Join-Path $ModelsDir 'loras'
# DiffSynth ControlNet в ComfyUI грузится не как ControlNet, а как патч модели
# (нода ModelPatchLoader), и лежит в отдельной папке.
$DirPatches = Join-Path $ModelsDir 'model_patches'
foreach ($d in @($DirDiT, $DirTextEnc, $DirVae, $DirLora, $DirPatches)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ------------------------------------------------------------------- curl.exe

$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $Curl)) {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { $Curl = $c.Source } else {
        Write-Host 'curl.exe не найден. Нужна Windows 10 1803+ или установленный curl.' -ForegroundColor Red
        exit 1
    }
}

# --------------------------------------------------------------- HF API utils

function Get-HFFileList {
    # HF периодически отвечает 401/429 при частых запросах, плюс бывают обрывы связи.
    # Три попытки с нарастающей паузой отсекают почти все такие ложные "репозиторий недоступен".
    param([string]$Repo)
    $url = "https://huggingface.co/api/models/$Repo" + '?full=true'
    foreach ($attempt in 1..3) {
        try {
            $json = (& $Curl -sSL --fail --max-time 60 $url) -join ''
            if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
            $names = ($json | ConvertFrom-Json).siblings.rfilename
            if ($names) { return $names }
        } catch {
            # разбираться не в чем: любая неудача лечится повтором или переходом к зеркалу
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
    }
    return @()
}

function Resolve-HFFile {
    # Первый файл, подходящий под один из паттернов. Порядок паттернов = приоритет.
    # {0} в паттерне подставляется как $Token (тег кванта).
    param([string[]]$Files, [string[]]$Patterns, [string]$Token)
    foreach ($p in $Patterns) {
        $rx = if ($Token) { $p -f [regex]::Escape($Token) } else { $p }
        $hit = $Files | Where-Object { $_ -match $rx } | Sort-Object Length | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Find-InRepos {
    # Перебирает репозитории по порядку, возвращает первый, где нашёлся нужный файл.
    param([string[]]$Repos, [string[]]$Patterns, [string]$Token)
    foreach ($repo in $Repos) {
        $files = Get-HFFileList $repo
        if (-not $files) { Write-Warn2 "репозиторий $repo недоступен, пробую следующий"; continue }
        $pick = Resolve-HFFile -Files $files -Patterns $Patterns -Token $Token
        if ($pick) { return [pscustomobject]@{ Repo = $repo; Path = $pick; Files = $files } }
        Write-Warn2 "в $repo нет подходящего файла, пробую следующий"
    }
    return $null
}

# Итоговый отчёт: что доехало, а что нет. Заполняется по ходу дела.
$script:Done    = @()
$script:Missing = @()

function Get-RemoteSize {
    # HEAD у HF иногда не отдаёт Content-Length (редирект на CDN, троттлинг).
    # Без размера нельзя отличить целый файл от оборванного, поэтому пробуем трижды.
    param([string]$Url)
    foreach ($attempt in 1..3) {
        $head = & $Curl -sIL --max-time 60 $Url 2>$null
        $size = 0
        foreach ($h in $head) {
            if ($h -match '^\s*[Cc]ontent-[Ll]ength:\s*(\d+)') { $size = [int64]$Matches[1] }
        }
        if ($size -gt 0) { return $size }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    return 0
}

function Find-AllInRepos {
    # Как Find-InRepos, но возвращает ВСЕ совпадения из первого доступного
    # репозитория: у ControlNet-патчей нужен не один файл, а весь набор.
    param([string[]]$Repos, [string]$Pattern)
    foreach ($repo in $Repos) {
        $files = Get-HFFileList $repo
        if (-not $files) { Write-Warn2 "репозиторий $repo недоступен, пробую следующий"; continue }
        $hits = @($files | Where-Object { $_ -match $Pattern })
        if ($hits.Count -gt 0) { return [pscustomobject]@{ Repo = $repo; Paths = $hits } }
        Write-Warn2 "в $repo нет подходящих файлов, пробую следующий"
    }
    return $null
}

function Get-HFDownload {
    # SaveAs - переименование при сохранении: в некоторых репозиториях веса лежат
    # под безликим именем вроде adapter_model.safetensors, и в общей папке loras
    # такое опознать невозможно.
    param([string]$Repo, [string]$RemotePath, [string]$DestDir, [string]$Label, [string]$SaveAs)

    $name = if ($SaveAs) { $SaveAs } else { Split-Path $RemotePath -Leaf }
    $dest = Join-Path $DestDir $name
    $url  = "https://huggingface.co/$Repo/resolve/main/$RemotePath" + '?download=true'

    $remoteSize = Get-RemoteSize $url

    if (Test-Path $dest) {
        $localSize = (Get-Item $dest).Length
        if ($remoteSize -gt 0 -and $localSize -eq $remoteSize) {
            Write-Ok "$Label уже на месте ($([math]::Round($localSize/1GB,2)) ГБ): $name"
            $script:Done += $Label
            return
        }
        if ($remoteSize -eq 0) {
            # Размер неизвестен: докачка вслепую может испортить целый файл, поэтому
            # оставляем как есть и говорим об этом прямо.
            Write-Warn2 "$Label уже есть, но размер на сервере не читается - оставляю как есть: $name"
            $script:Done += $Label
            return
        }
        Write-Host "  докачиваю $name ($([math]::Round($localSize/1GB,2)) из $([math]::Round($remoteSize/1GB,2)) ГБ)"
    } else {
        $sz = if ($remoteSize -gt 0) { " ($([math]::Round($remoteSize/1GB,2)) ГБ)" } else { '' }
        Write-Host "  скачиваю $Label$sz -> $name"
    }

    & $Curl -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -o "$dest" $url
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Загрузка $name прервалась (curl $LASTEXITCODE) - запусти скрипт снова, докачает с места обрыва."
        $script:Missing += "$Label (оборвалась загрузка)"
        return
    }
    Write-Ok "$Label готов: $name"
    $script:Done += $Label
}

# --------------------------------------------- Text encoder (общий, один раз)

Write-Step 'Text encoder Qwen2.5-VL 7B (общий для layered и edit)'
$te = Find-InRepos -Repos @($RepoQwenImg) -Patterns @(
    '(?i)text_encoders/.*qwen.*2\.5.*vl.*7b.*fp8.*scaled.*\.safetensors$',
    '(?i)text_encoders/.*qwen.*2\.5.*vl.*7b.*fp8.*\.safetensors$'
)
if ($te) {
    Get-HFDownload -Repo $te.Repo -RemotePath $te.Path -DestDir $DirTextEnc -Label 'Text encoder'
} else {
    Write-Warn2 'Text encoder не найден - скорее всего временный сбой сети. Перезапусти скрипт.'
    $script:Missing += 'Text encoder (без него не работает ни одна из моделей)'
}

# ------------------------------------------------------- Модели по очереди

$QuantTag = if ($IsGGUF) { $Quant.ToUpper() } else { $null }

foreach ($target in $Targets) {
    $spec = $ModelSpecs[$target]
    Write-Step "$($spec.Title) - $Quant"

    # DiT
    $dit = Find-InRepos -Repos $spec.DitRepos -Patterns $spec.DitPatterns -Token $QuantTag
    if ($dit) {
        Get-HFDownload -Repo $dit.Repo -RemotePath $dit.Path -DestDir $DirDiT -Label "DiT $target ($Quant)"
    } else {
        Write-Warn2 "DiT для '$target' в точности '$Quant' не найден ни в одном источнике."
        Write-Host  "      Проверь вручную: https://huggingface.co/$($spec.DitRepos[0])/tree/main"
        $script:Missing += "DiT $target"
        continue
    }

    # VAE
    $vae = Find-InRepos -Repos $spec.VaeRepos -Patterns $spec.VaePatterns
    if ($vae) {
        Get-HFDownload -Repo $vae.Repo -RemotePath $vae.Path -DestDir $DirVae -Label "VAE $target"
    } else {
        Write-Warn2 "VAE для '$target' не найден автоматически."
        $script:Missing += "VAE $target"
    }

    # LoRA - их может быть несколько
    foreach ($ld in $spec.Loras) {
        $lora = Find-InRepos -Repos $ld.Repos -Patterns $ld.Patterns
        if ($lora) {
            # Безликие имена (adapter_model.safetensors и подобные) в общей папке loras
            # опознать нельзя - сохраняем под именем, говорящим что это за LoRA.
            $leaf   = Split-Path $lora.Path -Leaf
            $saveAs = if ($leaf -match '^adapter_model|^pytorch_lora_weights') {
                          "$($ld.Prefix)-$leaf"
                      } else { $null }
            Get-HFDownload -Repo $lora.Repo -RemotePath $lora.Path -DestDir $DirLora `
                           -Label $ld.Label -SaveAs $saveAs
        } else {
            Write-Warn2 "$($ld.Label) не найдена - возможно, репозиторий gated (нужно принять лицензию на HF)."
            Write-Host  "      Проверь вручную: https://huggingface.co/$($ld.Repos[0])/tree/main"
            $script:Missing += $ld.Label
        }
    }
}

# ------------------------------------------------------- ControlNet-патчи

if ($ControlNet) {
    Write-Step 'DiffSynth ControlNet (canny / depth / inpaint)'
    $cn = Find-AllInRepos -Repos @('Comfy-Org/Qwen-Image-DiffSynth-ControlNets') `
                          -Pattern '(?i)model_patches/.*\.safetensors$'
    if ($cn) {
        foreach ($path in $cn.Paths) {
            $kind = if ((Split-Path $path -Leaf) -match '(canny|depth|inpaint)') { $Matches[1] } else { 'patch' }
            Get-HFDownload -Repo $cn.Repo -RemotePath $path -DestDir $DirPatches -Label "ControlNet $kind"
        }
    } else {
        Write-Warn2 'ControlNet-патчи не найдены.'
        Write-Host  '      Проверь вручную: https://huggingface.co/Comfy-Org/Qwen-Image-DiffSynth-ControlNets/tree/main'
        $script:Missing += 'DiffSynth ControlNet'
    }
}

# ------------------------------------------------------------- Custom nodes

function Install-CustomNode {
    param([string]$Name, [string]$RepoUrl, [string]$Why)

    $customNodes = Join-Path $ComfyUIPath 'custom_nodes'
    if (-not (Test-Path $customNodes)) { New-Item -ItemType Directory -Path $customNodes -Force | Out-Null }
    $target = Join-Path $customNodes $Name

    if (Test-Path $target) { Write-Ok "$Name уже установлен"; return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn2 "git не найден - поставь '$Name' через ComfyUI Manager (Custom Nodes Manager -> поиск)"
        return
    }

    Write-Host "  $Name - $Why"
    # git пишет прогресс в stderr, а при $ErrorActionPreference='Stop' PowerShell
    # превращает любую строку stderr нативной команды в терминирующий NativeCommandError
    # и валит весь скрипт на успешном клоне. Ослабляем режим только на время вызова.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git clone --depth 1 --quiet $RepoUrl "$target" 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -eq 0) {
        # requirements.txt ComfyUI Desktop доставит сам при следующем старте;
        # если не подхватит - Manager -> Install Missing Custom Nodes добьёт.
        Write-Ok "$Name установлен"
    } else {
        Write-Warn2 "git clone $Name не удался (код $LASTEXITCODE) - поставь через ComfyUI Manager"
    }
}

if ($IsGGUF) {
    Write-Step 'Custom node ComfyUI-GGUF (обязателен для .gguf)'
    Install-CustomNode -Name 'ComfyUI-GGUF' -RepoUrl 'https://github.com/city96/ComfyUI-GGUF' `
                       -Why 'лоадер GGUF-моделей'
    Write-Warn2 'Нужна python-зависимость gguf. Если ComfyUI не подхватит сам: Manager -> Install Missing Custom Nodes'
}

if ($Angles -and $Targets -contains 'edit') {
    Write-Step 'Нода управления ракурсом (-Angles)'
    # Нода сама картинку не поворачивает: она даёт 3D-вьюпорт и собирает из него
    # текстовый промпт с формулировками ракурса. Поворот делает LoRA Multiple-Angles.
    Install-CustomNode -Name 'ComfyUI-qwenmultiangle' -RepoUrl 'https://github.com/jtydhr88/ComfyUI-qwenmultiangle' `
                       -Why '3D-вьюпорт: ракурс мышью вместо текста'
}

if ($Extras) {
    Write-Step 'Дополнительные ноды (-Extras)'
    if ($Targets -contains 'layered') {
        # layered отдаёт батч RGBA-слоёв, ComfyUI по умолчанию пишет их отдельными PNG.
        Install-CustomNode -Name 'ComfyUI-Layers' -RepoUrl 'https://github.com/alessandrozonta/ComfyUI-Layers' `
                           -Why 'сохранение батча слоёв в один PSD'
    }
    Install-CustomNode -Name 'ComfyUI-Crystools' -RepoUrl 'https://github.com/crystian/ComfyUI-Crystools' `
                       -Why 'монитор VRAM/RAM/GPU в интерфейсе'
}

# ------------------------------------------------------------------- Итог

Write-Step 'Итог загрузки'
foreach ($d in $script:Done) { Write-Ok $d }
if ($script:Missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'НЕ ЗАГРУЖЕНО:' -ForegroundColor Red
    foreach ($m in $script:Missing) { Write-Host "  - $m" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Запусти скрипт повторно той же командой: готовые файлы он пропустит,' -ForegroundColor Yellow
    Write-Host 'оборванные догрузит с места обрыва.' -ForegroundColor Yellow
} else {
    Write-Ok 'Все файлы на месте.'
}

Write-Host @"

Файлы разложены в:
  DiT           $DirDiT
  Text encoder  $DirTextEnc
  VAE           $DirVae
  LoRA          $DirLora
  ControlNet    $DirPatches

Общее:
  * Перезапусти ComfyUI Desktop - иначе не увидит новые модели и ноды.
  * Шаблоны: Workflow -> Browse Templates -> поиск по "Qwen Image".
    Шаблоны приходят как Subgraph: чтобы менять лоадеры, зайди внутрь двойным кликом.
  * Для GGUF замени "Load Diffusion Model" на "Unet Loader (GGUF)".
"@ -ForegroundColor Gray

if ($Targets -contains 'layered') {
    Write-Host @"

Qwen-Image-Layered:
  * VAE обязательно layered-версии - обычный qwen_image_vae не отдаёт альфа-канал.
  * Число слоёв - виджет "layers" на ноде "Empty Qwen Image Layered Latent".
    На выходе layers + 1 картинок: первая это полная композиция, а не слой.
  * Начинай с 640 px по короткой стороне; выше разделение слоёв деградирует.
  * LoRA Stable-Layers: нода "LoraLoaderModelOnly", strength 1.0. Работает поверх GGUF.
"@ -ForegroundColor Gray
}

if ($Targets -contains 'edit') {
    Write-Host @"

Qwen-Image-Edit-2511:
  * VAE здесь обычный (qwen_image_vae), не layered.
  * Картинка-источник подаётся в ноду "TextEncodeQwenImageEdit" вместе с инструкцией -
    именно она кодирует изображение и промпт вместе, обычный CLIP Text Encode не подойдёт.
  * Без Lightning LoRA: ~40 шагов, cfg 4.0.
    С Lightning LoRA: 4 шага, cfg 1.0 - иначе получишь пересвет и мусор.
"@ -ForegroundColor Gray

    if ($Angles) {
        Write-Host @"
  * Ракурс: нода "Qwen Multi Angle" даёт 3D-вьюпорт (кольца азимута, наклона
    и дистанции). Её текстовый выход идёт в "TextEncodeQwenImageEdit" вместо
    обычного промпта - или склеенным с ним, если правишь ещё что-то.
  * Сама нода изображение не поворачивает, поворот делает LoRA Multiple-Angles.
    Без LoRA получишь просто игнор ракурса, без ошибки - это сбивает с толку.
  * Две LoRA (Lightning + Angles) вешаются цепочкой: LoraLoaderModelOnly подряд.
    Если ракурс перестанет слушаться, снижай strength у Lightning, а не у Angles.
  * Готовый шаблон: Workflow -> Browse Templates -> "Qwen Multiangle".
"@ -ForegroundColor Gray
    }
}

if ($Targets -contains 'base') {
    Write-Host @"

Qwen-Image-2512 (генерация с нуля):
  * Обычный txt2img: "Empty Latent Image" -> KSampler, картинка на входе не нужна.
  * Сильная сторона - текст на изображении: вывески, упаковка, надписи. Пиши
    нужную надпись в промпте в кавычках, тогда модель воспроизведёт её точнее.
  * Lightning LoRA здесь СВОЯ, не та что у edit. Обе лежат в loras и различаются
    по имени - не перепутай, чужая даст замыленный результат.
"@ -ForegroundColor Gray
}

if ($ControlNet) {
    Write-Host @"

ControlNet (DiffSynth-патчи):
  * Грузятся нодой "ModelPatchLoader" из models\model_patches - это НЕ обычный
    "Load ControlNet Model", тот их не увидит.
  * Шаблон: Workflow -> Browse Templates -> "Qwen Image ControlNet Model Patch".
  * depth и canny работают с готовыми картами: если рендеришь в 3D-пакете,
    Z-Depth и clay-проход можно отдать напрямую, препроцессор не нужен.
  * Патч inpaint частично дублирует Easy Inpaint LoRA - это разные механизмы,
    выбирай по результату, одновременно вешать смысла нет.
"@ -ForegroundColor Gray
}

if ($Inpaint) {
    Write-Host @"

Easy Inpaint LoRA:
  * Закрась область ЧЁРНЫМ в любом редакторе и начни промпт словами
    "Inpaint the black areas." - дальше обычная инструкция что нарисовать.
  * Маски и ноды препроцессинга не нужны, вход - обычная картинка.
  * Если скачался запасной вариант от ostris - там закрашивают ЗЕЛЁНЫМ,
    формулировка промпта другая, смотри карточку модели.
"@ -ForegroundColor Gray
}

if ($Quant -eq 'q4_k_m') {
    Write-Host @'

Замечание по q4_k_m: самый агрессивный квант из разумных. Для edit разница почти
незаметна, а вот у layered чаще попадаются полупустые слои и остатки объекта на фоне.
Если увидишь это - перезапусти с -Quant q6_k, он на 4090 тоже помещается
и докачает только DiT, остальное останется на месте.
'@ -ForegroundColor DarkYellow
}
