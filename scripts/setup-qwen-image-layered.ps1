<#
.SYNOPSIS
    Устанавливает Qwen-Image-Layered (+ Stable-Layers LoRA) в локальный ComfyUI.

.DESCRIPTION
    Скрипт:
      1. Находит папку моделей ComfyUI (в т.ч. ComfyUI Desktop).
      2. Определяет реальные имена файлов через HuggingFace API (не хардкодит их).
      3. Скачивает DiT нужной точности, text encoder, layered VAE и LoRA Stable-Layers.
      4. Ставит custom node ComfyUI-GGUF, если выбран GGUF-квант.
    Все загрузки идут через curl.exe с докачкой (-C -), можно прерывать и запускать заново.

.PARAMETER Quant
    Точность DiT-модели. Для RTX 4090 (24 ГБ) по умолчанию q6_k.
      q4_k_m  ~13 ГБ  быстро, заметнее потери качества
      q6_k    ~17 ГБ  рекомендуется для 24 ГБ VRAM
      q8_0    ~22 ГБ  максимум качества GGUF, впритык, будет оффлоад
      fp8     ~20 ГБ  официальный fp8mixed от Comfy-Org, без custom nodes
      bf16    ~41 ГБ  полная точность, для 24 ГБ не влезет (только оффлоад в RAM)

.PARAMETER ComfyUIPath
    Корень ComfyUI (папка, внутри которой лежит models\). Если не указан — автопоиск.

.PARAMETER SkipLora
    Не скачивать LoRA Stable-Layers (только базовая модель Qwen-Image-Layered).

.PARAMETER Extras
    Доставить QoL custom nodes: экспорт слоёв в PSD и монитор VRAM в интерфейсе.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image-layered.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-qwen-image-layered.ps1 -Quant fp8 -ComfyUIPath "D:\ComfyUI"
#>

[CmdletBinding()]
param(
    [ValidateSet('q4_k_m', 'q6_k', 'q8_0', 'fp8', 'bf16')]
    [string]$Quant = 'q6_k',

    [string]$ComfyUIPath,

    [switch]$SkipLora,

    [switch]$Extras
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Репозитории HuggingFace
$RepoLayered = 'Comfy-Org/Qwen-Image-Layered_ComfyUI'   # официальные split_files для ComfyUI
$RepoQwenImg = 'Comfy-Org/Qwen-Image_ComfyUI'           # запасной источник text encoder
$RepoGGUF    = 'QuantStack/Qwen-Image-Layered-GGUF'     # GGUF-кванты
$RepoLora    = 'StabilityLabs/Stable-Layers'            # LoRA от Stability AI

function Write-Step($msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]  $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- ComfyUI path

function Find-ComfyUIRoot {
    # 1. ComfyUI Desktop пишет путь к моделям в extra_models_config.yaml
    $cfg = Join-Path $env:APPDATA 'ComfyUI\extra_models_config.yaml'
    if (Test-Path $cfg) {
        foreach ($line in Get-Content $cfg) {
            if ($line -match '^\s*base_path:\s*(.+?)\s*$') {
                $p = $Matches[1].Trim('"').Trim("'")
                if (Test-Path $p) { return (Resolve-Path $p).Path }
            }
        }
    }

    # 2. Типовые места установки
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

  powershell -ExecutionPolicy Bypass -File .\setup-qwen-image-layered.ps1 -ComfyUIPath "C:\путь\к\ComfyUI"

Нужная папка — та, внутри которой лежит подпапка models\.
'@ -ForegroundColor Red
    exit 1
}

$ModelsDir = Join-Path $ComfyUIPath 'models'
if (-not (Test-Path $ModelsDir)) {
    Write-Host "В '$ComfyUIPath' нет подпапки models\ - это не корень ComfyUI." -ForegroundColor Red
    exit 1
}
Write-Ok "ComfyUI: $ComfyUIPath"

$IsGGUF     = $Quant -in 'q4_k_m', 'q6_k', 'q8_0'
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
    # Возвращает список путей файлов в репозитории (siblings[].rfilename)
    param([string]$Repo)
    $url = "https://huggingface.co/api/models/$Repo" + '?full=true'
    try {
        $json = (& $Curl -sSL --fail --max-time 60 $url) -join ''
        if ($LASTEXITCODE -ne 0) { throw "curl exit $LASTEXITCODE" }
        return ($json | ConvertFrom-Json).siblings.rfilename
    } catch {
        Write-Warn2 "Не удалось получить список файлов $Repo ($_)"
        return @()
    }
}

function Resolve-HFFile {
    # Находит в репозитории первый файл, подходящий под один из regex-паттернов.
    # Паттерны проверяются по порядку — первый совпавший выигрывает.
    param([string[]]$Files, [string[]]$Patterns)
    foreach ($p in $Patterns) {
        $hit = $Files | Where-Object { $_ -match $p } | Sort-Object Length | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-HFDownload {
    param(
        [string]$Repo,
        [string]$RemotePath,
        [string]$DestDir,
        [string]$Label
    )
    $name = Split-Path $RemotePath -Leaf
    $dest = Join-Path $DestDir $name
    $url  = "https://huggingface.co/$Repo/resolve/main/$RemotePath" + '?download=true'

    # Размер на сервере, чтобы понять — файл уже целиком скачан или нужна докачка
    $remoteSize = 0
    $head = & $Curl -sIL --max-time 60 $url 2>$null
    foreach ($h in $head) {
        if ($h -match '^\s*[Cc]ontent-[Ll]ength:\s*(\d+)') { $remoteSize = [int64]$Matches[1] }
    }

    if (Test-Path $dest) {
        $localSize = (Get-Item $dest).Length
        if ($remoteSize -gt 0 -and $localSize -eq $remoteSize) {
            Write-Ok "$Label уже на месте ($([math]::Round($localSize/1GB,2)) ГБ): $name"
            return $dest
        }
        Write-Host "  докачиваю $name ($([math]::Round($localSize/1GB,2)) из $([math]::Round($remoteSize/1GB,2)) ГБ)"
    } else {
        $sz = if ($remoteSize -gt 0) { " ($([math]::Round($remoteSize/1GB,2)) ГБ)" } else { '' }
        Write-Host "  скачиваю $Label$sz -> $name"
    }

    & $Curl -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -o "$dest" $url
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Загрузка $name прервалась (curl $LASTEXITCODE). Запусти скрипт снова — докачает с места обрыва."
        return $null
    }
    Write-Ok "$Label готов: $name"
    return $dest
}

# -------------------------------------------------------- 1. Diffusion model

Write-Step "DiT-модель Qwen-Image-Layered ($Quant)"


if ($IsGGUF) {
    $files = Get-HFFileList $RepoGGUF
    if (-not $files) { Write-Host "Репозиторий $RepoGGUF недоступен." -ForegroundColor Red; exit 1 }
    # Имена в репо вида Qwen_Image_Layered-Q6_K.gguf
    $tag  = $Quant.ToUpper()
    $pick = Resolve-HFFile -Files $files -Patterns @("(?i)-$tag\.gguf$", "(?i)$tag.*\.gguf$")
    if (-not $pick) {
        Write-Host "Квант $tag не найден. Доступные .gguf:" -ForegroundColor Red
        $files | Where-Object { $_ -match '\.gguf$' } | ForEach-Object { Write-Host "    $_" }
        exit 1
    }
    Get-HFDownload -Repo $RepoGGUF -RemotePath $pick -DestDir $DirDiT -Label 'DiT (GGUF)' | Out-Null
} else {
    $files = Get-HFFileList $RepoLayered
    if (-not $files) { Write-Host "Репозиторий $RepoLayered недоступен." -ForegroundColor Red; exit 1 }
    if ($Quant -eq 'fp8') {
        # ВАЖНО: для Qwen-Image-Layered подходит именно fp8mixed.
        # Обычный fp8_e4m3fn для этой модели ломает вывод (артефакты/пустые слои).
        $pick = Resolve-HFFile -Files $files -Patterns @('(?i)layered.*fp8.?mixed.*\.safetensors$', '(?i)fp8.?mixed.*\.safetensors$')
    } else {
        $pick = Resolve-HFFile -Files $files -Patterns @('(?i)layered.*bf16.*\.safetensors$', '(?i)diffusion_models/.*bf16.*\.safetensors$')
    }
    if (-not $pick) {
        Write-Host "Не нашёл файл для '$Quant'. Доступные diffusion_models:" -ForegroundColor Red
        $files | Where-Object { $_ -match 'diffusion_models/' } | ForEach-Object { Write-Host "    $_" }
        exit 1
    }
    Get-HFDownload -Repo $RepoLayered -RemotePath $pick -DestDir $DirDiT -Label "DiT ($Quant)" | Out-Null
}

# ------------------------------------------------------------ 2. Text encoder

Write-Step 'Text encoder (Qwen2.5-VL 7B)'

$teRepo = $RepoLayered
$teList = Get-HFFileList $RepoLayered
$tePick = Resolve-HFFile -Files $teList -Patterns @('(?i)text_encoders/.*qwen.*2\.5.*vl.*7b.*fp8.*\.safetensors$',
                                                    '(?i)text_encoders/.*\.safetensors$')
if (-not $tePick) {
    # В layered-репо энкодера может не быть — он общий для всей линейки Qwen-Image
    $teRepo = $RepoQwenImg
    $teList = Get-HFFileList $RepoQwenImg
    $tePick = Resolve-HFFile -Files $teList -Patterns @('(?i)text_encoders/.*qwen.*2\.5.*vl.*7b.*fp8.*scaled.*\.safetensors$',
                                                        '(?i)text_encoders/.*qwen.*2\.5.*vl.*7b.*fp8.*\.safetensors$')
}
if ($tePick) {
    Get-HFDownload -Repo $teRepo -RemotePath $tePick -DestDir $DirTextEnc -Label 'Text encoder' | Out-Null
} else {
    Write-Warn2 'Text encoder не найден автоматически — скачай qwen_2.5_vl_7b_fp8_scaled.safetensors вручную в models\text_encoders\'
}

# --------------------------------------------------------------------- 3. VAE

Write-Step 'VAE (layered, с поддержкой RGBA)'

$vaeList = if ($teRepo -eq $RepoLayered) { $teList } else { Get-HFFileList $RepoLayered }
# У Qwen-Image-Layered свой VAE — обычный qwen_image_vae НЕ подойдёт, он не отдаёт альфу.
$vaePick = Resolve-HFFile -Files $vaeList -Patterns @('(?i)vae/.*layered.*\.safetensors$', '(?i)vae/.*\.safetensors$')
if ($vaePick) {
    Get-HFDownload -Repo $RepoLayered -RemotePath $vaePick -DestDir $DirVae -Label 'VAE' | Out-Null
} else {
    Write-Warn2 'VAE не найден автоматически — возьми qwen_image_layered_vae.safetensors в models\vae\'
}

# ---------------------------------------------------- 4. Stable-Layers LoRA

if (-not $SkipLora) {
    Write-Step 'LoRA Stable-Layers (Stability AI)'
    $loraList = Get-HFFileList $RepoLora
    $loraPick = Resolve-HFFile -Files $loraList -Patterns @('(?i)\.safetensors$')
    if ($loraPick) {
        Get-HFDownload -Repo $RepoLora -RemotePath $loraPick -DestDir $DirLora -Label 'LoRA Stable-Layers' | Out-Null
    } else {
        Write-Warn2 "В $RepoLora не найдено .safetensors — возможно, репозиторий gated (нужно принять лицензию на сайте) или веса лежат иначе."
        Write-Host "      Проверь вручную: https://huggingface.co/$RepoLora/tree/main"
    }
}

# ------------------------------------------------------------ 5. Custom nodes

function Install-CustomNode {
    param([string]$Name, [string]$RepoUrl, [string]$Why)

    $customNodes = Join-Path $ComfyUIPath 'custom_nodes'
    if (-not (Test-Path $customNodes)) { New-Item -ItemType Directory -Path $customNodes -Force | Out-Null }
    $target = Join-Path $customNodes $Name

    if (Test-Path $target) { Write-Ok "$Name уже установлен"; return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warn2 "git не найден — поставь '$Name' через ComfyUI Manager (Custom Nodes Manager -> поиск)"
        return
    }

    Write-Host "  $Name - $Why"
    git clone --depth 1 $RepoUrl "$target" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Name установлен"
        # requirements.txt каждой ноды ставит сам ComfyUI Desktop при следующем старте;
        # если не подхватит - Manager -> Install Missing Custom Nodes добьёт зависимости.
    } else {
        Write-Warn2 "git clone $Name не удался — поставь через ComfyUI Manager"
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
    # Главное для layered-модели: она отдаёт батч RGBA-слоёв, а ComfyUI по умолчанию
    # сохраняет их отдельными PNG. Эта нода складывает батч в один .psd со слоями.
    Install-CustomNode -Name 'ComfyUI-Layers' -RepoUrl 'https://github.com/alessandrozonta/ComfyUI-Layers' `
                       -Why 'сохранение батча слоёв в один PSD'
    # Монитор VRAM/RAM прямо в интерфейсе - полезно при подборе кванта и разрешения.
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

Дальше в ComfyUI:
  1. Перезапусти ComfyUI Desktop (нужно для подхвата новых моделей и custom node).
  2. Workflow -> Browse Templates -> найди "Qwen Image Layered".
     Шаблон приходит как Subgraph — зайди внутрь (двойной клик), чтобы менять лоадеры.
  3. Если качал GGUF: внутри Subgraph замени "Load Diffusion Model" на
     "Unet Loader (GGUF)" и выбери свой .gguf.
     Если качал fp8: просто выбери qwen_image_layered_fp8mixed в существующем лоадере.
  4. VAE должен быть layered-версии (обычный qwen_image_vae не отдаёт альфа-канал).
  5. Кол-во слоёв — виджет "layers" на ноде "Empty Qwen Image Layered Latent".
     На выходе будет layers + 1 картинок: первая - это полное изображение, а не слой.
  6. Разрешение начинай с 640 px по короткой стороне. Выше запускается,
     но разделение слоёв постепенно деградирует.
  7. LoRA Stable-Layers: нода "LoraLoaderModelOnly" между лоадером модели и
     сэмплером, strength 1.0 для старта. Работает и поверх GGUF.
  8. Если ставил -Extras: вместо "Save Image" подключи ноду сохранения из
     ComfyUI-Layers - получишь один .psd со слоями вместо россыпи PNG.
"@ -ForegroundColor Gray

if ($Quant -eq 'q4_k_m') {
    Write-Host @'
Замечание по q4_k_m: это самый агрессивный квант из разумных. Генерация быстрая,
но разделение на слои у него аккуратное не всегда - чаще попадаются полупустые
слои и остатки объекта на фоне. Если увидишь это на своих картинках, первым делом
пробуй q6_k (тот же скрипт с -Quant q6_k), он на 4090 тоже помещается.
'@ -ForegroundColor DarkYellow
}
