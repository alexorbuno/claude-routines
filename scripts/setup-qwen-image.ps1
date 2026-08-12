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
    both    - поставить обе.

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

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model layered -Quant q4_k_m -Extras

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model edit -Quant q4_k_m -Lightning

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -Model both -Quant q4_k_m -Lightning -Extras
#>

[CmdletBinding()]
param(
    [ValidateSet('layered', 'edit', 'both')]
    [string]$Model = 'layered',

    [ValidateSet('q4_k_m', 'q6_k', 'q8_0', 'fp8', 'bf16')]
    [string]$Quant = 'q6_k',

    [string]$ComfyUIPath,

    [switch]$Lightning,

    [switch]$SkipLora,

    [switch]$Extras
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
} else {
    $LayeredDitRepos = @('Comfy-Org/Qwen-Image-Layered_ComfyUI')
    $EditDitRepos    = @('Comfy-Org/Qwen-Image-Edit_ComfyUI')
}

# --- Паттерны имён файлов. {0} подставляется как тег кванта (Q4_K_M и т.п.).
if ($IsGGUF) {
    $LayeredDitPatterns = @('(?i)layered.*-{0}\.gguf$', '(?i)-{0}\.gguf$', '(?i){0}.*\.gguf$')
    $EditDitPatterns    = @('(?i)2511.*-{0}\.gguf$', '(?i)-{0}\.gguf$', '(?i){0}.*\.gguf$')
} elseif ($Quant -eq 'fp8') {
    # Для layered годится ТОЛЬКО fp8mixed: обычный fp8_e4m3fn ломает вывод.
    $LayeredDitPatterns = @('(?i)layered.*fp8.?mixed.*\.safetensors$', '(?i)fp8.?mixed.*\.safetensors$')
    $EditDitPatterns    = @('(?i)edit.*2511.*fp8.*\.safetensors$', '(?i)edit.*fp8.*\.safetensors$')
} else {
    $LayeredDitPatterns = @('(?i)layered.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
    $EditDitPatterns    = @('(?i)edit.*2511.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
}

$LayeredLoraRepos = if ($SkipLora)  { @() } else { @('StabilityLabs/Stable-Layers') }
$EditLoraRepos    = if ($Lightning) { @('lightx2v/Qwen-Image-Edit-2511-Lightning') } else { @() }

$ModelSpecs = @{
    layered = @{
        Title        = 'Qwen-Image-Layered (разбор на RGBA-слои)'
        DitRepos     = $LayeredDitRepos
        DitPatterns  = $LayeredDitPatterns
        # У layered свой VAE, умеющий альфа-канал. Обычный qwen_image_vae не подойдёт.
        VaeRepos     = @('Comfy-Org/Qwen-Image-Layered_ComfyUI')
        VaePatterns  = @('(?i)vae/.*layered.*\.safetensors$', '(?i)vae/.*\.safetensors$')
        LoraRepos    = $LayeredLoraRepos
        LoraPatterns = @('(?i)\.safetensors$')
        LoraLabel    = 'LoRA Stable-Layers'
    }
    edit = @{
        Title        = 'Qwen-Image-Edit-2511 (правка по инструкции)'
        DitRepos     = $EditDitRepos
        DitPatterns  = $EditDitPatterns
        # Edit работает на обычном VAE линейки Qwen-Image.
        VaeRepos     = @('Comfy-Org/Qwen-Image_ComfyUI', 'Comfy-Org/Qwen-Image-Edit_ComfyUI')
        VaePatterns  = @('(?i)vae/qwen_image_vae\.safetensors$', '(?i)vae/.*\.safetensors$')
        LoraRepos    = $EditLoraRepos
        # 4 шага - самый выгодный размен; bf16-вариант LoRA работает и поверх GGUF.
        LoraPatterns = @('(?i)4steps.*bf16.*\.safetensors$', '(?i)4steps.*\.safetensors$',
                         '(?i)8steps.*\.safetensors$', '(?i)\.safetensors$')
        LoraLabel    = 'Lightning LoRA (4 шага)'
    }
}

$Targets = if ($Model -eq 'both') { @('layered', 'edit') } else { @($Model) }

function Write-Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]  $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- ComfyUI path

function Find-ComfyUIRoot {
    # ComfyUI Desktop пишет путь к моделям в extra_models_config.yaml
    $cfg = Join-Path $env:APPDATA 'ComfyUI\extra_models_config.yaml'
    if (Test-Path $cfg) {
        foreach ($line in Get-Content $cfg) {
            if ($line -match '^\s*base_path:\s*(.+?)\s*$') {
                $p = $Matches[1].Trim('"').Trim("'")
                if (Test-Path $p) { return (Resolve-Path $p).Path }
            }
        }
    }
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Documents\ComfyUI'),
        (Join-Path $env:USERPROFILE 'ComfyUI'),
        'C:\ComfyUI',
        'D:\ComfyUI',
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\@comfyorgcomfyui-electron\resources\ComfyUI')
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'models')) { return (Resolve-Path $c).Path }
    }
    return $null
}

Write-Step 'Поиск ComfyUI'
if (-not $ComfyUIPath) { $ComfyUIPath = Find-ComfyUIRoot }
if (-not $ComfyUIPath) {
    Write-Host @'
Не удалось найти ComfyUI автоматически.

Открой ComfyUI Desktop -> Settings (шестерёнка) -> Server-Config / About,
там указан путь установки. Затем запусти скрипт с этим путём:

  powershell -ExecutionPolicy Bypass -File .\setup-qwen-image.ps1 -ComfyUIPath "C:\путь\к\ComfyUI"

Нужная папка - та, внутри которой лежит подпапка models\.
'@ -ForegroundColor Red
    exit 1
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
foreach ($d in @($DirDiT, $DirTextEnc, $DirVae, $DirLora)) {
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
    param([string]$Repo)
    $url = "https://huggingface.co/api/models/$Repo" + '?full=true'
    try {
        $json = (& $Curl -sSL --fail --max-time 60 $url) -join ''
        if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
        return ($json | ConvertFrom-Json).siblings.rfilename
    } catch {
        return @()
    }
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

function Get-HFDownload {
    param([string]$Repo, [string]$RemotePath, [string]$DestDir, [string]$Label)

    $name = Split-Path $RemotePath -Leaf
    $dest = Join-Path $DestDir $name
    $url  = "https://huggingface.co/$Repo/resolve/main/$RemotePath" + '?download=true'

    # Размер на сервере: отличить «уже скачано» от «нужна докачка»
    $remoteSize = 0
    $head = & $Curl -sIL --max-time 60 $url 2>$null
    foreach ($h in $head) {
        if ($h -match '^\s*[Cc]ontent-[Ll]ength:\s*(\d+)') { $remoteSize = [int64]$Matches[1] }
    }

    if (Test-Path $dest) {
        $localSize = (Get-Item $dest).Length
        if ($remoteSize -gt 0 -and $localSize -eq $remoteSize) {
            Write-Ok "$Label уже на месте ($([math]::Round($localSize/1GB,2)) ГБ): $name"
            return
        }
        Write-Host "  докачиваю $name ($([math]::Round($localSize/1GB,2)) из $([math]::Round($remoteSize/1GB,2)) ГБ)"
    } else {
        $sz = if ($remoteSize -gt 0) { " ($([math]::Round($remoteSize/1GB,2)) ГБ)" } else { '' }
        Write-Host "  скачиваю $Label$sz -> $name"
    }

    & $Curl -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -o "$dest" $url
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Загрузка $name прервалась (curl $LASTEXITCODE). Запусти скрипт снова - докачает с места обрыва."
        return
    }
    Write-Ok "$Label готов: $name"
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
    Write-Warn2 'Text encoder не найден - скачай qwen_2.5_vl_7b_fp8_scaled.safetensors в models\text_encoders\'
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
        continue
    }

    # VAE
    $vae = Find-InRepos -Repos $spec.VaeRepos -Patterns $spec.VaePatterns
    if ($vae) {
        Get-HFDownload -Repo $vae.Repo -RemotePath $vae.Path -DestDir $DirVae -Label "VAE $target"
    } else {
        Write-Warn2 "VAE для '$target' не найден автоматически."
    }

    # LoRA
    if ($spec.LoraRepos.Count -gt 0) {
        $lora = Find-InRepos -Repos $spec.LoraRepos -Patterns $spec.LoraPatterns
        if ($lora) {
            Get-HFDownload -Repo $lora.Repo -RemotePath $lora.Path -DestDir $DirLora -Label $spec.LoraLabel
        } else {
            Write-Warn2 "$($spec.LoraLabel) не найдена - возможно, репозиторий gated (нужно принять лицензию на HF)."
            Write-Host  "      Проверь вручную: https://huggingface.co/$($spec.LoraRepos[0])/tree/main"
        }
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
    git clone --depth 1 $RepoUrl "$target" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        # requirements.txt ComfyUI Desktop доставит сам при следующем старте;
        # если не подхватит - Manager -> Install Missing Custom Nodes добьёт.
        Write-Ok "$Name установлен"
    } else {
        Write-Warn2 "git clone $Name не удался - поставь через ComfyUI Manager"
    }
}

if ($IsGGUF) {
    Write-Step 'Custom node ComfyUI-GGUF (обязателен для .gguf)'
    Install-CustomNode -Name 'ComfyUI-GGUF' -RepoUrl 'https://github.com/city96/ComfyUI-GGUF' `
                       -Why 'лоадер GGUF-моделей'
    Write-Warn2 'Нужна python-зависимость gguf. Если ComfyUI не подхватит сам: Manager -> Install Missing Custom Nodes'
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

Write-Step 'Готово'
Write-Host @"
Файлы разложены в:
  DiT           $DirDiT
  Text encoder  $DirTextEnc
  VAE           $DirVae
  LoRA          $DirLora

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
}

if ($Quant -eq 'q4_k_m') {
    Write-Host @'

Замечание по q4_k_m: самый агрессивный квант из разумных. Для edit разница почти
незаметна, а вот у layered чаще попадаются полупустые слои и остатки объекта на фоне.
Если увидишь это - перезапусти с -Quant q6_k, он на 4090 тоже помещается
и докачает только DiT, остальное останется на месте.
'@ -ForegroundColor DarkYellow
}
