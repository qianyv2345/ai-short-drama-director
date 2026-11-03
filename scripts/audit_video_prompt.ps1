param(
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,

    [string]$SourcePath,

    [int]$Episode,

    [string]$ExpectedStylePrefix,

    [string[]]$ExpectedEntity,

    [string[]]$AllowedExtraEntity,

    [switch]$StrictEntityAudit,

    [string[]]$ExpectedAbsentShotId,

    [Parameter(Mandatory = $true)]
    [ValidateSet(15, 30)]
    [int]$MaxSegmentSeconds,

    [Parameter(Mandatory = $true)]
    [ValidateSet('9:16', '16:9')]
    [string]$AspectRatio
)

$ErrorActionPreference = 'Stop'
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Read-StrictUtf8([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found: $Path"
    }
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $strictUtf8)
}

function Add-Failure([string]$Message) {
    $failures.Add($Message)
}

function Add-Warning([string]$Message) {
    $warnings.Add($Message)
}

function Test-HalfSecond([double]$Value) {
    $scaled = $Value * 2.0
    return ([math]::Abs($scaled - [math]::Round($scaled)) -le 0.0001)
}

function Test-IntegerSecond([double]$Value) {
    return ([math]::Abs($Value - [math]::Round($Value)) -le 0.0001)
}

function Normalize-Entity([string]$Value) {
    if ($null -eq $Value) { return '' }
    return ($Value.Trim() -replace '^@', '')
}

function Get-EntitySet([string]$Text, [bool]$IncludeSpeakerLabels, [string[]]$KnownEntity) {
    $entities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $ignored = @(
        '场景', '人物', '时间', '地点', '镜头', '时长', '台词', '对白', '旁白',
        '画面', '动作', '表情', '机位', '运镜', '音效', '衔接', '备注', '参考图',
        '提示词', '连续性限制', '天气', '内景', '外景', '环境', '角色', '道具',
        '人物定位', '摄影机调度', '整体画面', '环境场与情绪光影', '时间轴与状态演变',
        '美学介质与底层渲染'
    )

    $knownValues = @(
        foreach ($known in @($KnownEntity)) {
            $value = Normalize-Entity $known
            if ($value -and ($ignored -notcontains $value)) { $value }
        }
    )

    $promptEntityPattern = '@([\p{IsCJKUnifiedIdeographs}]{2,4})(?=[（(「」：:，,。；;\s]|$)'
    foreach ($match in [regex]::Matches($Text, $promptEntityPattern)) {
        $value = Normalize-Entity $match.Groups[1].Value
        $isKnownPrefix = @($knownValues | Where-Object {
            ($value.Length -gt $_.Length) -and $value.StartsWith($_, [System.StringComparison]::Ordinal)
        }).Count -gt 0
        if ($value -and ($ignored -notcontains $value) -and (-not $isKnownPrefix)) {
            $null = $entities.Add($value)
        }
    }

    foreach ($value in $knownValues) {
        if ($Text -and $Text.Contains("@$value")) {
            $null = $entities.Add($value)
        }
    }

    if ($IncludeSpeakerLabels) {
        $speakerPattern = '(?m)^\s*@?([\p{IsCJKUnifiedIdeographs}]{2,12})\s*[：:]'
        foreach ($match in [regex]::Matches($Text, $speakerPattern)) {
            $value = Normalize-Entity $match.Groups[1].Value
            if ($value -and ($ignored -notcontains $value)) { $null = $entities.Add($value) }
        }
    }

    return ,$entities
}

try {
    $prompt = Read-StrictUtf8 $PromptPath
}
catch {
    Write-Output "FAIL UTF8_OR_READ: $($_.Exception.Message)"
    exit 1
}

$segmentPattern = '(?m)^#{2,3}\s+(?<id>\d+-S\d+[A-Z]*).*?｜(?<seconds>\d+(?:\.\d+)?)秒\s*$'
$shotPattern = '(?m)^\*\*(?<start>\d+(?:\.\d+)?)-(?<end>\d+(?:\.\d+)?)秒｜(?<id>[^*]+?)\*\*\s*$'
$segmentMatches = [regex]::Matches($prompt, $segmentPattern)
$shotMatches = [regex]::Matches($prompt, $shotPattern)

if ($segmentMatches.Count -eq 0) {
    Add-Failure 'No generation segment headings found.'
}
if ($shotMatches.Count -eq 0) {
    Add-Failure 'No timed shot headings found.'
}

$entityAuditStatus = 'SKIPPED_NO_SOURCE'
$textStateStatus = 'NOT_APPLICABLE'
$lightingLayerStatus = 'NOT_APPLICABLE'
$stylePhysicalStatus = 'NOT_APPLICABLE'
$timeGranularityStatus = 'NOT_APPLICABLE'

$textObjectPattern = '标签|药瓶|屏幕|纸张|门牌|招牌|手机|电脑|通知|界面'
$textStatePattern = '无可读文字|完整可读|部分可读|模糊不可辨|不可辨|不可读|磨损|字迹.*模糊|文字.*模糊|仅保留.*纹理|图形纹理'
if ($prompt -match $textObjectPattern) {
    if ($prompt -match $textStatePattern) {
        $textStateStatus = 'PRESENT'
    }
    else {
        $textStateStatus = 'MISSING'
        Add-Warning 'TEXT_STATE_MISSING: Prompt mentions a text-bearing object but does not state its visible text/readability state.'
    }
}

$lightingPattern = '主光|辅光|轮廓光|侧逆光|逆光|顶光|侧光|实用光|伦勃朗光|柔光|硬光|环境光|明暗对比'
$globalLightingPattern = '全局光线基线|全局光线|整体光线基线|场景光线基线|全局保持'
$localLightingPattern = '镜头局部光线|局部布光|局部光线|局部调整|镜头局部'
if ($prompt -match $lightingPattern) {
    $hasGlobalLighting = $prompt -match $globalLightingPattern
    $hasLocalLighting = $prompt -match $localLightingPattern
    if ($hasGlobalLighting -and $hasLocalLighting) {
        $lightingLayerStatus = 'PRESENT'
    }
    else {
        $lightingLayerStatus = 'INCOMPLETE'
        if (-not $hasGlobalLighting) {
            Add-Warning 'LIGHTING_GLOBAL_LAYER_MISSING: Prompt uses lighting terms but does not identify the continuous-scene global lighting baseline.'
        }
        if (-not $hasLocalLighting) {
            Add-Warning 'LIGHTING_LOCAL_LAYER_MISSING: Prompt uses lighting terms but does not identify the shot-level local lighting adjustment.'
        }
    }
}

$liveActionPattern = '真人|实拍|live[ -]?action|纪录片质感|Alexa'
$cgPattern = '3D|CG|三维|动画|模型|光线追踪|ray tracing|render'
$digitalCapturePattern = 'Alexa|数字摄影|数字摄像|大画幅数字'
$filmTexturePattern = 'Kodak|5219|35mm|胶片颗粒|Film Grain|电影胶片'
$hasLiveAction = $prompt -match $liveActionPattern
$hasCG = $prompt -match $cgPattern
$hasDigitalCapture = $prompt -match $digitalCapturePattern
$hasFilmTexture = $prompt -match $filmTexturePattern
$hasPhysicalBridge = $prompt -match '后期|模拟|仿|风格化|物理可行|physically plausible|不混用|仅作质感'
if (($hasLiveAction -and $hasCG -and -not $hasPhysicalBridge) -or ($hasDigitalCapture -and $hasFilmTexture -and -not $hasPhysicalBridge)) {
    $stylePhysicalStatus = 'RISK'
    Add-Warning 'STYLE_PHYSICAL_MIX: Check live-action, CG/rendering, digital-capture, and film-texture terms; distinguish capture source from simulated post texture and do not silently rewrite user-fixed style words.'
}
elseif ($hasLiveAction -or $hasCG -or $hasDigitalCapture -or $hasFilmTexture) {
    $stylePhysicalStatus = 'CHECKED'
}

$segmentTotal = 0.0
$timelineTotal = 0.0
$maxSegment = 0.0
$shotIds = [System.Collections.Generic.List[string]]::new()
$shotRecords = [System.Collections.Generic.List[object]]::new()

for ($segmentIndex = 0; $segmentIndex -lt $segmentMatches.Count; $segmentIndex++) {
    $segmentMatch = $segmentMatches[$segmentIndex]
    $secondsText = $segmentMatch.Groups['seconds'].Value
    $seconds = [double]$secondsText
    if ($timeGranularityStatus -eq 'NOT_APPLICABLE') { $timeGranularityStatus = 'PASS' }
    if (-not (Test-IntegerSecond $seconds) -or $secondsText.Contains('.')) {
        $timeGranularityStatus = 'FAIL'
        Add-Failure "Generation segment $($segmentMatch.Groups['id'].Value) total must be written as an integer number of seconds: $secondsText"
    }
    $segmentTotal += $seconds
    if ($seconds -gt $maxSegment) { $maxSegment = $seconds }
    if ($seconds -gt $MaxSegmentSeconds) {
        Add-Failure "Segment exceeds selected maximum of $MaxSegmentSeconds seconds: $seconds"
    }

    $segmentEndIndex = $prompt.Length
    if ($segmentIndex + 1 -lt $segmentMatches.Count) {
        $segmentEndIndex = $segmentMatches[$segmentIndex + 1].Index
    }

    $segmentShots = @($shotMatches | Where-Object {
        $_.Index -gt $segmentMatch.Index -and $_.Index -lt $segmentEndIndex
    })
    if ($segmentShots.Count -eq 0) {
        Add-Failure "No timed shots found in segment $($segmentMatch.Groups['id'].Value)."
        continue
    }

    $previousEnd = 0.0
    $segmentTimeline = 0.0
    for ($shotIndex = 0; $shotIndex -lt $segmentShots.Count; $shotIndex++) {
        $match = $segmentShots[$shotIndex]
        $start = [double]$match.Groups['start'].Value
        $end = [double]$match.Groups['end'].Value
        $rawId = $match.Groups['id'].Value.Trim()
        $baseId = ($rawId -split '[｜（(]')[0].Trim()
        $shotDuration = $end - $start
        if (-not (Test-HalfSecond $start) -or -not (Test-HalfSecond $end) -or -not (Test-HalfSecond $shotDuration)) {
            $timeGranularityStatus = 'FAIL'
            Add-Failure "Shot time must use 0.5-second increments for $($match.Value.Trim())"
        }

        if ($end -le $start) {
            Add-Failure "Invalid shot time range: $($match.Value.Trim())"
        }
        if ($shotIndex -eq 0 -and [math]::Abs($start) -gt 0.01) {
            Add-Failure "Segment $($segmentMatch.Groups['id'].Value) does not start at 0 seconds: $rawId"
        }
        if ($shotIndex -gt 0 -and [math]::Abs($start - $previousEnd) -gt 0.01) {
            Add-Failure "Timeline gap or overlap in $($segmentMatch.Groups['id'].Value) before ${rawId}: previous end $previousEnd, next start $start."
        }

        $segmentTimeline += ($end - $start)
        $previousEnd = $end
        $shotIds.Add($baseId)
        $shotRecords.Add([pscustomobject]@{
            SegmentId = $segmentMatch.Groups['id'].Value
            Match = $match
            BaseId = $baseId
        })
    }

    $timelineTotal += $segmentTimeline
    if (-not (Test-IntegerSecond $segmentTimeline) -or -not (Test-IntegerSecond $previousEnd)) {
        $timeGranularityStatus = 'FAIL'
        Add-Failure "Generation segment $($segmentMatch.Groups['id'].Value) timeline must end at an integer second; got $previousEnd"
    }
    if ([math]::Abs($segmentTimeline - $seconds) -gt 0.01 -or [math]::Abs($previousEnd - $seconds) -gt 0.01) {
        Add-Failure "Segment $($segmentMatch.Groups['id'].Value) duration $seconds does not match its local timeline total $segmentTimeline or final time $previousEnd."
    }
}

if ([math]::Abs($segmentTotal - $timelineTotal) -gt 0.01) {
    Add-Failure "Segment total $segmentTotal does not match timeline total $timelineTotal."
}

$soundSectionPattern = '(?ms)^【音效】(?<body>.*?)(?=^【连续性限制】|^#{2,3}\s+|\z)'
foreach ($soundSection in [regex]::Matches($prompt, $soundSectionPattern)) {
    foreach ($timeMatch in [regex]::Matches($soundSection.Groups['body'].Value, '(?<![\w.])(?<time>\d+(?:\.\d+)?)s')) {
        $soundTime = [double]$timeMatch.Groups['time'].Value
        if (-not (Test-HalfSecond $soundTime)) {
            $timeGranularityStatus = 'FAIL'
            Add-Failure "Sound timecode must use 0.5-second increments: $($timeMatch.Value)"
        }
    }
}

$duplicateShots = $shotIds | Group-Object | Where-Object Count -gt 1
foreach ($duplicate in $duplicateShots) {
    Add-Failure "Duplicate shot id: $($duplicate.Name)"
}

$requiredFields = @(
    '整体画面：',
    '绝对主体与物理动势：',
    '环境场与情绪光影：',
    '摄影机调度：',
    '时间轴与状态演变：',
    '美学介质与底层渲染：'
)

foreach ($field in $requiredFields) {
    $count = [regex]::Matches($prompt, "(?m)^$([regex]::Escape($field))").Count
    if ($count -ne $shotMatches.Count) {
        Add-Failure "Field count mismatch for $field expected $($shotMatches.Count), got $count."
    }
}

$canonicalPrefix = [regex]::Matches($prompt, '(?m)^整段视频默认无文字无字幕；剧本明确要求的剧情内文字除外。\s*$').Count
$legacyPrefix = [regex]::Matches($prompt, '(?m)^整段视频无文字无字幕。\s*$').Count
$prefixCount = $canonicalPrefix + $legacyPrefix
if ($prefixCount -ne $segmentMatches.Count) {
    Add-Failure "No-subtitle prefix count expected $($segmentMatches.Count), got $prefixCount."
}
if ($legacyPrefix -gt 0) {
    Add-Warning "Legacy no-subtitle prefix found in $legacyPrefix segment(s); new files should use the canonical prefix."
}

if ($prompt.Contains('`r`n')) {
    Add-Failure 'Literal PowerShell newline escape found: `r`n'
}

$executionLines = $prompt -split "`r?`n" | Where-Object {
    $_ -match '^(整体画面：|绝对主体与物理动势：|环境场与情绪光影：|摄影机调度：|时间轴与状态演变：|美学介质与底层渲染：)'
}
$relativePattern = '承接上一镜|保持上一段状态|同上|位置不变|继续前一动作|供下一段续接'
foreach ($line in $executionLines) {
    if ($line -match $relativePattern) {
        Add-Failure "Relative continuity instruction found: $line"
    }
}

$cameraLines = $executionLines | Where-Object { $_ -match '^摄影机调度：' }
foreach ($line in $cameraLines) {
    $mentionsOverShoulder = ($line -match '过肩|肩后')
    $explicitlyNoOverShoulder = ($line -match '不设置.*过肩|无肩前景|不设置前景过肩')
    if ($mentionsOverShoulder -and (-not $explicitlyNoOverShoulder) -and ($line -notmatch '左肩|右肩|左后肩|右后肩')) {
        Add-Warning "Over-shoulder camera line does not name left/right shoulder: $line"
    }
}

for ($index = 0; $index -lt $shotMatches.Count; $index++) {
    $match = $shotMatches[$index]
    $blockStart = $match.Index
    if ($index + 1 -lt $shotMatches.Count) {
        $blockLength = $shotMatches[$index + 1].Index - $blockStart
    }
    else {
        $blockLength = $prompt.Length - $blockStart
    }
    $block = $prompt.Substring($blockStart, $blockLength)
    $spoken = [regex]::Matches($block, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value }
    if ($spoken.Count -gt 0) {
        $spokenText = $spoken -join ''
        $hanCount = [regex]::Matches($spokenText, '[\p{IsCJKUnifiedIdeographs}]').Count
        $duration = [double]$match.Groups['end'].Value - [double]$match.Groups['start'].Value
        if ($duration -gt 0) {
            $rate = $hanCount / $duration
            if ($rate -gt 6.0) {
                Add-Warning "Dialogue rate above 6 chars/s in $($match.Groups['id'].Value.Trim()): $([math]::Round($rate, 2))"
            }
        }
    }
}

foreach ($expectedAbsent in @($ExpectedAbsentShotId)) {
    if ($null -eq $expectedAbsent) { continue }
    $absentId = $expectedAbsent.Trim()
    if (-not $absentId) { continue }
    $present = @($shotRecords | Where-Object { $_.BaseId -eq $absentId })
    if ($present.Count -gt 0) {
        Add-Failure "Expected shot id is still present: $absentId"
    }
}

if ($ExpectedStylePrefix) {
    $styleCount = [regex]::Matches($prompt, [regex]::Escape($ExpectedStylePrefix)).Count
    if ($styleCount -ne $segmentMatches.Count) {
        Add-Failure "Explicit style prefix count expected $($segmentMatches.Count), got $styleCount."
    }
}

$entityBaselineText = ''
if ($SourcePath) {
    try {
        $source = Read-StrictUtf8 $SourcePath
        if ($Episode -gt 0) {
            $episodePattern = "(?s)##\s*第$Episode集.*?(?=\r?\n##\s*第$($Episode + 1)集|\z)"
            $episodeMatch = [regex]::Match($source, $episodePattern)
            if (-not $episodeMatch.Success) {
                Add-Failure "Episode $Episode not found in source."
            }
            else {
                $source = $episodeMatch.Value
            }
        }

        $entityBaselineText = $source

        $promptDialogue = [regex]::Matches($prompt, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value }
        $sourceDialogue = [regex]::Matches($source, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value }
        if ($promptDialogue.Count -ne $sourceDialogue.Count) {
            Add-Failure "Dialogue count expected $($sourceDialogue.Count), got $($promptDialogue.Count)."
        }
        else {
            for ($index = 0; $index -lt $sourceDialogue.Count; $index++) {
                if ($promptDialogue[$index] -cne $sourceDialogue[$index]) {
                    Add-Failure "Dialogue mismatch at index $($index + 1)."
                    break
                }
            }
        }
    }
    catch {
        Add-Failure "Source read or dialogue audit failed: $($_.Exception.Message)"
    }
}

if ($entityBaselineText -or $ExpectedEntity) {
    $sourceEntities = Get-EntitySet $entityBaselineText $true
    foreach ($expected in @($ExpectedEntity)) {
        $value = Normalize-Entity $expected
        if ($value) { $null = $sourceEntities.Add($value) }
    }

    $promptEntities = Get-EntitySet $prompt $false @($sourceEntities)
    $allowedExtras = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($allowed in @($AllowedExtraEntity)) {
        $value = Normalize-Entity $allowed
        if ($value) { $null = $allowedExtras.Add($value) }
    }

    $extraEntities = @($promptEntities | Where-Object {
        (-not $sourceEntities.Contains($_)) -and (-not $allowedExtras.Contains($_))
    } | Sort-Object)
    $missingEntities = @($sourceEntities | Where-Object { -not $promptEntities.Contains($_) } | Sort-Object)
    $entityAuditStatus = 'PASS'
    if ($missingEntities.Count -gt 0) { $entityAuditStatus = 'SCOPE_REVIEW' }
    if ($extraEntities.Count -gt 0) {
        $entityAuditStatus = 'REVIEW'
        $message = "ENTITY_EXTRA: Prompt contains entities not found in the supplied source or ExpectedEntity list: $($extraEntities -join ', ')"
        if ($StrictEntityAudit) {
            Add-Failure $message
        }
        else {
            Add-Warning $message
        }
    }
    $entityAuditStatus = "$entityAuditStatus|extra=$($extraEntities -join ',')|missing=$($missingEntities -join ',')"
}

Write-Output "SEGMENTS=$($segmentMatches.Count) MAX_SEGMENT=$maxSegment SELECTED_MAX=$MaxSegmentSeconds ASPECT_RATIO=$AspectRatio TOTAL=$segmentTotal"
Write-Output "SHOTS=$($shotMatches.Count) TIMELINE_TOTAL=$timelineTotal PREFIXES=$prefixCount CANONICAL_PREFIXES=$canonicalPrefix LEGACY_PREFIXES=$legacyPrefix TIME_GRANULARITY=$timeGranularityStatus ENTITY_AUDIT=$entityAuditStatus TEXT_STATE=$textStateStatus LIGHTING_LAYERS=$lightingLayerStatus STYLE_PHYSICAL=$stylePhysicalStatus"

foreach ($warning in $warnings) {
    Write-Output "WARN $warning"
}
foreach ($failure in $failures) {
    Write-Output "FAIL $failure"
}

if ($failures.Count -gt 0) {
    exit 1
}

Write-Output "PASS warnings=$($warnings.Count)"
exit 0
