param(
    [Parameter(Mandatory = $true)]
    [string]$PromptPath,

    [string]$SourcePath,

    [int]$Episode,

    [switch]$PartialScope,

    [string]$ExpectedStylePrefix,

    [string[]]$ExpectedEntity,

    [string[]]$AllowedExtraEntity,

    [switch]$StrictEntityAudit,

    [string[]]$ExpectedAbsentShotId,

    [switch]$AllowLegacyMetadata,

    [Parameter(Mandatory = $true)]
    [ValidateSet(15, 30)]
    [int]$MaxSegmentSeconds,

    [Parameter(Mandatory = $true)]
    [ValidateSet('9:16', '16:9')]
    [string]$AspectRatio,

    [string]$ExpectedDialoguePath
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

function Split-EntityInputs([string[]]$Values) {
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Values)) {
        if ($null -eq $item) { continue }
        foreach ($part in ($item -split '[,，\s]+')) {
            $norm = Normalize-Entity $part
            if ($norm) { $result.Add($norm) }
        }
    }
    return $result.ToArray()
}

function Strip-EntitySuffix([string]$Value) {
    if (-not $Value) { return '' }
    $stripped = $Value -replace '的(?:(?:左|右)?(?:手|眼|眼睛|脸|脸颊|肩|肩膀|头|背影|背|衣袖|袖|嘴唇|唇|眉头|眉|声音|身旁|面前|方向|左侧|右侧|手指|指))?$', ''
    return $stripped
}

function Test-IgnoredEntity([string]$Value, [string[]]$IgnoredList) {
    if (-not $Value) { return $true }
    if ($IgnoredList -contains $Value) { return $true }
    if ($Value -match '^(?:第.{1,6}[集场幕回章]|人物定位|场景名称|主要人物|剧情用途)$') { return $true }
    return $false
}

function Get-EntitySet([string]$Text, [bool]$IncludeSpeakerLabels, [string[]]$KnownEntity) {
    $entities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $ignored = @(
        '场景', '人物', '时间', '地点', '镜头', '时长', '台词', '对白', '旁白',
        '画面', '动作', '表情', '机位', '运镜', '光影', '音效', '衔接', '备注', '参考图',
        '提示词', '提示词编号', '来源', '连续性限制', '天气', '内景', '外景', '环境', '角色', '道具',
        '人物定位', '摄影机调度', '整体画面', '绝对主体与物理动势', '环境场与情绪光影', '时间轴与状态演变',
        '美学介质与底层渲染', '表情与口型', '整体风格', '画面内容', '人物动作', '人物表情', '镜头编号',
        '镜头衔接', '主要人物', '剧情定位', '人物性格', '场景关键特征', '画外音', '字幕', '声音', '集数'
    )

    $knownPool = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($known in @(Split-EntityInputs $KnownEntity)) {
        if (-not (Test-IgnoredEntity $known $ignored)) { $null = $knownPool.Add($known) }
    }

    $knownValues = @($knownPool | Select-Object -Unique | Sort-Object Length -Descending)

    foreach ($value in $knownValues) {
        if ($Text -and $Text.Contains("@$value")) {
            $null = $entities.Add($value)
        }
    }

    $promptEntityPattern = '@([A-Za-z0-9\p{IsCJKUnifiedIdeographs}·_-]{1,16})'
    foreach ($match in [regex]::Matches($Text, $promptEntityPattern)) {
        $rawValue = Normalize-Entity $match.Groups[1].Value
        $isKnownPrefix = @($knownValues | Where-Object {
            ($rawValue.Length -ge $_.Length) -and $rawValue.StartsWith($_, [System.StringComparison]::Ordinal)
        }).Count -gt 0
        if ($isKnownPrefix) { continue }

        $value = Strip-EntitySuffix $rawValue
        if (-not (Test-IgnoredEntity $value $ignored)) {
            $null = $entities.Add($value)
        }
    }

    if ($IncludeSpeakerLabels) {
        $speakerPattern = '(?m)^\s*@?([A-Za-z0-9\p{IsCJKUnifiedIdeographs}·_-]{1,12})(?:[（(][^）)\r\n]{1,16}[）)])?\s*[：:]'
        foreach ($match in [regex]::Matches($Text, $speakerPattern)) {
            $value = Normalize-Entity $match.Groups[1].Value
            if (-not (Test-IgnoredEntity $value $ignored)) {
                $null = $entities.Add($value)
            }
        }
    }

    return ,$entities
}

function Get-ShotDialogue([object]$ShotRecord) {
    $block = $ShotRecord.Block
    $targetText = $block
    if ($ShotRecord.Format -eq 'FIVE_LINE') {
        $line = [regex]::Match($block, '(?m)^台词：[^\r\n]*').Value
        $targetText = $line
    }
    elseif ($ShotRecord.Format -eq 'CINEMATIC_6') {
        $line = [regex]::Match($block, '(?m)^时间轴与状态演变：[^\r\n]*').Value
        $targetText = $line
    }
    if (-not $targetText) { return @() }
    $cursor = 0
    foreach ($quote in [regex]::Matches($targetText, '「([^」]+)」')) {
        $cue = $targetText.Substring($cursor, $quote.Index - $cursor)
        $cursor = $quote.Index + $quote.Length
        $tag = [regex]::Match($cue, '@(?<role>[\p{L}\p{N}·_.-]+)(?<delivery>[ \t]*(?:[（(][^）)\r\n]*[）)])?[ \t]*)$')
        $kind = '对白'
        if ($tag.Success) {
            $typePrefix = [regex]::Match($cue.Substring(0, $tag.Index), '(?<kind>对白|OS|旁白|画外音|画外声)[：:][ \t]*$')
            $typeDelivery = [regex]::Match($tag.Groups['delivery'].Value, '[(（][ \t]*(?<kind>OS|旁白|画外音|画外声)(?=[，,、\s)）])')
            if ($typePrefix.Success) { $kind = $typePrefix.Groups['kind'].Value }
            if ($typeDelivery.Success) { $kind = $typeDelivery.Groups['kind'].Value }
            if ($kind -eq '画外声') { $kind = '画外音' }
        }
        [pscustomobject]@{
            Role = $tag.Groups['role'].Value
            Kind = $kind
            Text = $quote.Groups[1].Value
        }
    }
}

function Test-DialogueContract([string]$Path, [object[]]$Actual) {
    $contract = ConvertFrom-Json -InputObject (Read-StrictUtf8 $Path)
    if ($contract.dialogue_free -isnot [bool] -or $contract.utterances -isnot [array]) {
        throw 'Expected dialogue requires boolean dialogue_free and an utterances array.'
    }
    $expected = $contract.utterances
    if ($contract.dialogue_free -ne ($expected.Count -eq 0)) {
        throw 'dialogue_free must be true exactly when utterances is empty.'
    }
    foreach ($line in $expected) {
        if ([string]::IsNullOrWhiteSpace($line.role) -or [string]::IsNullOrWhiteSpace($line.text) -or
            $line.kind -cnotin @('对白', 'OS', '旁白', '画外音')) {
            throw 'Each expected utterance requires role, kind and text.'
        }
    }

    $index = 0
    $offset = 0
    foreach ($fragment in $Actual) {
        if ($index -ge $expected.Count) {
            Add-Failure "Unexpected dialogue after the expected scope: $($fragment.Text)"
            return
        }
        $line = $expected[$index]
        if ($fragment.Role -cne $line.role -or $fragment.Kind -cne $line.kind) {
            Add-Failure "Dialogue speaker or kind mismatch at line $($index + 1): expected $($line.role)/$($line.kind), got $($fragment.Role)/$($fragment.Kind)."
            return
        }
        if (-not $line.text.Substring($offset).StartsWith($fragment.Text, [StringComparison]::Ordinal)) {
            Add-Failure "Dialogue text mismatch at line $($index + 1): $($fragment.Text)"
            return
        }
        $offset += $fragment.Text.Length
        if ($offset -eq $line.text.Length) {
            $index++
            $offset = 0
        }
    }
    if ($index -ne $expected.Count) {
        Add-Failure "Dialogue missing or incomplete at expected line $($index + 1)."
    }
}

try {
    $prompt = Read-StrictUtf8 $PromptPath
}
catch {
    Write-Output "FAIL UTF8_OR_READ: $($_.Exception.Message)"
    exit 1
}

$segmentPattern = '(?m)^#{2,3}[ \t]+(?<episode>\d+)-S(?<sequence>\d+)(?<suffix>[A-Z]*)(?<attributes>.*?)｜(?<seconds>\d+(?:\.\d+)?)秒[ \t]*\r?$'
$shotPattern = '(?m)^(?<detailed>\*\*)?(?<start>\d+(?:\.\d+)?)-(?<end>\d+(?:\.\d+)?)秒(?(detailed)｜(?<id>[^*\r\n]+?)\*\*[ \t]*\r?$|(?:｜(?<id>[^：:\r\n]+))?[：:][^\r\n]+)'
$cinematicFields = @(
    '整体画面：',
    '绝对主体与物理动势：',
    '环境场与情绪光影：',
    '摄影机调度：',
    '时间轴与状态演变：',
    '美学介质与底层渲染：'
)
$fiveFields = @('画面：', '运镜：', '光影：', '台词：', '音效：')

$segmentMatches = [regex]::Matches($prompt, $segmentPattern)
$shotMatches = [regex]::Matches($prompt, $shotPattern)

if ($segmentMatches.Count -eq 0) {
    Add-Failure 'No generation segment headings found.'
}
if ($shotMatches.Count -eq 0) {
    Add-Failure 'No timed shot headings found.'
}

$segmentRanges = [System.Collections.Generic.List[object]]::new()
$segmentsBuilder = [System.Text.StringBuilder]::new()
for ($segmentIndex = 0; $segmentIndex -lt $segmentMatches.Count; $segmentIndex++) {
    $segMatch = $segmentMatches[$segmentIndex]
    $searchStart = $segMatch.Index + $segMatch.Length
    $nextHeading = [regex]::Match($prompt.Substring($searchStart), '(?m)^#{1,3}[ \t]+')
    $segEnd = if ($nextHeading.Success) { $searchStart + $nextHeading.Index } else { $prompt.Length }
    $slice = $prompt.Substring($segMatch.Index, $segEnd - $segMatch.Index)
    $null = $segmentsBuilder.AppendLine($slice)
    $segmentRanges.Add([pscustomobject]@{
        Match = $segMatch
        Start = $segMatch.Index
        End   = $segEnd
        Slice = $slice
    })
}
$promptBodyText = if ($segmentRanges.Count -gt 0) { $segmentsBuilder.ToString() } else { $prompt }

$entityAuditStatus = 'SKIPPED_NO_SOURCE'
$textStateStatus = 'NOT_APPLICABLE'
$lightingLayerStatus = 'NOT_APPLICABLE'
$stylePhysicalStatus = 'NOT_APPLICABLE'
$timeGranularityStatus = 'NOT_APPLICABLE'
$detectedFormats = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

$textObjectPattern = '标签|药瓶|屏幕|纸张|门牌|招牌|手机|电脑|通知|界面'
$textStatePattern = '无可读文字|完整可读|部分可读|模糊不可辨|不可辨|不可读|磨损|字迹.*模糊|文字.*模糊|仅保留.*纹理|图形纹理'
if ($promptBodyText -match $textObjectPattern) {
    if ($promptBodyText -match $textStatePattern) {
        $textStateStatus = 'PRESENT'
    }
    else {
        $textStateStatus = 'MISSING'
        Add-Warning 'TEXT_STATE_MISSING: Prompt mentions a text-bearing object but does not state its visible text/readability state.'
    }
}

$lightingPattern = '主光|辅光|轮廓光|侧逆光|逆光|顶光|侧光|实用光|伦勃朗光|柔光|硬光|环境光|明暗对比|窗光|天光|冷光|暖光'
$globalLightingPattern = '全局光线基线|全局光线|整体光线基线|场景光线基线|全局保持'
$localLightingPattern = '镜头局部光线|局部布光|局部光线|局部调整|镜头局部'
$sceneBlocksText = ([regex]::Matches($promptBodyText, '(?m)^【场景】[^\r\n]*(?:\r?\n(?![【#*]).+)*') | ForEach-Object { $_.Value }) -join "`n"
$localLightLinesText = ([regex]::Matches($promptBodyText, '(?m)^(?:光影：|环境场与情绪光影：|\d+(?:\.\d+)?-\d+(?:\.\d+)?秒(?:｜[^：:\r\n]+)?[：:])[^\r\n]*') | ForEach-Object { $_.Value }) -join "`n"

if ($promptBodyText -match $lightingPattern) {
    $hasGlobalLighting = ($promptBodyText -match $globalLightingPattern) -or ($sceneBlocksText -match "$lightingPattern|色调|暗调|亮调|明暗")
    $hasLocalLighting = ($promptBodyText -match $localLightingPattern) -or ($localLightLinesText -match "$lightingPattern|阴影|提亮|暗沉|泛光")
    if ($hasGlobalLighting -and $hasLocalLighting) {
        $lightingLayerStatus = 'PRESENT'
    }
    else {
        $lightingLayerStatus = 'INCOMPLETE'
        if (-not $hasGlobalLighting) {
            Add-Warning 'LIGHTING_GLOBAL_LAYER_MISSING: Prompt uses lighting terms but does not identify the continuous-scene global lighting baseline in 【场景】.'
        }
        if (-not $hasLocalLighting) {
            Add-Warning 'LIGHTING_LOCAL_LAYER_MISSING: Prompt uses lighting terms but does not identify shot-level local lighting.'
        }
    }
}

$liveActionPattern = '真人|实拍|live[ -]?action|纪录片质感|Alexa'
$cgPattern = '3D|CG|三维|动画|模型|光线追踪|ray tracing|render'
$digitalCapturePattern = 'Alexa|数字摄影|数字摄像|大画幅数字'
$filmTexturePattern = 'Kodak|5219|35mm|胶片颗粒|Film Grain|电影胶片'
$hasLiveAction = $promptBodyText -match $liveActionPattern
$hasCG = $promptBodyText -match $cgPattern
$hasDigitalCapture = $promptBodyText -match $digitalCapturePattern
$hasFilmTexture = $promptBodyText -match $filmTexturePattern
$hasPhysicalBridge = $promptBodyText -match '后期|模拟|仿|风格化|物理可行|physically plausible|不混用|仅作质感'
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

for ($segmentIndex = 0; $segmentIndex -lt $segmentRanges.Count; $segmentIndex++) {
    $segRange = $segmentRanges[$segmentIndex]
    $segmentMatch = $segRange.Match
    $segmentId = $segmentMatch.Value.Trim()
    $segmentEndIndex = $segRange.End
    $attributes = $segmentMatch.Groups['attributes'].Value
    $versions = [regex]::Matches($attributes, '｜[ \t]*(?<value>15|30)秒版(?=[ \t]*(?:｜|$))')
    $ratios = [regex]::Matches($attributes, '｜[ \t]*(?<value>9:16|16:9)(?<orientation>竖屏|横屏)?(?=[ \t]*(?:｜|$))')
    foreach ($check in @(
        @{ Name = 'duration version'; Matches = $versions; Expected = "$MaxSegmentSeconds" },
        @{ Name = 'aspect ratio'; Matches = $ratios; Expected = $AspectRatio }
    )) {
        if ($check.Matches.Count -eq 0 -and $AllowLegacyMetadata) {
            Add-Warning "Legacy heading lacks $($check.Name): $segmentId"
        }
        elseif ($check.Matches.Count -ne 1 -or $check.Matches[0].Groups['value'].Value -ne $check.Expected) {
            Add-Failure "Heading $($check.Name) must specify $($check.Expected): $segmentId"
        }
    }

    if ($ratios.Count -eq 1) {
        $orientation = $ratios[0].Groups['orientation'].Value
        $expectedOrientation = if ($AspectRatio -eq '9:16') { '竖屏' } else { '横屏' }
        if ($orientation -and $orientation -ne $expectedOrientation) {
            Add-Failure "Heading orientation must match the aspect ratio: $segmentId"
        }
    }

    $secondsText = $segmentMatch.Groups['seconds'].Value
    $seconds = [double]$secondsText
    if ($timeGranularityStatus -eq 'NOT_APPLICABLE') { $timeGranularityStatus = 'PASS' }
    if (-not (Test-IntegerSecond $seconds) -or $secondsText.Contains('.')) {
        $timeGranularityStatus = 'FAIL'
        Add-Failure "Generation segment $segmentId total must be written as an integer number of seconds: $secondsText"
    }
    $segmentTotal += $seconds
    if ($seconds -gt $maxSegment) { $maxSegment = $seconds }
    if ($seconds -gt $MaxSegmentSeconds) {
        Add-Failure "Segment exceeds selected maximum of $MaxSegmentSeconds seconds: $seconds"
    }

    $segmentBody = $prompt.Substring($segmentMatch.Index + $segmentMatch.Length, $segmentEndIndex - $segmentMatch.Index - $segmentMatch.Length)
    $prefixMatchInSeg = [regex]::Match($segmentBody, '(?m)^整段视频(?:默认)?无文字无字幕')
    $preamble = if ($prefixMatchInSeg.Success) { $segmentBody.Substring(0, $prefixMatchInSeg.Index) } else { $segmentBody }

    $numberLines = [regex]::Matches($segmentBody, '(?m)^提示词编号[：:][^\r\n]*')
    $expectedNumber = '{0}-{1}{2}' -f $segmentMatch.Groups['episode'].Value, [int]$segmentMatch.Groups['sequence'].Value, $segmentMatch.Groups['suffix'].Value
    $numberPattern = '(?m)^[ \t]*提示词编号：[ \t]*' + [regex]::Escape($expectedNumber) + '(?:[ \t]*[｜|][ \t]*来源：[^\r\n]+)?[ \t]*\r?$'
    if ($numberLines.Count -eq 0 -and $AllowLegacyMetadata) {
        Add-Warning "Legacy segment lacks prompt number: $segmentId"
    }
    elseif ($numberLines.Count -ne 1 -or $preamble -notmatch $numberPattern) {
        Add-Failure "Expected one prompt number before the no-subtitle line: 提示词编号：$expectedNumber"
    }

    $segmentShots = @($shotMatches | Where-Object {
        $_.Index -gt $segmentMatch.Index -and $_.Index -lt $segmentEndIndex
    })
    if ($segmentShots.Count -eq 0) {
        Add-Failure "No timed shots found in segment $segmentId."
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
        $shotLabel = if ($rawId) { $rawId } else { "$start-$end" }
        $blockEnd = $segmentEndIndex
        if ($shotIndex + 1 -lt $segmentShots.Count) {
            $blockEnd = $segmentShots[$shotIndex + 1].Index
        }
        $block = $prompt.Substring($match.Index, $blockEnd - $match.Index)
        $block = ($block -split '(?m)^【(?:音效|连续性限制)】', 2)[0]

        $shotFormat = 'COMPACT'
        if ($match.Groups['detailed'].Success) {
            $hasCinematicField = $block -match '(?m)^(?:整体画面|绝对主体与物理动势|环境场与情绪光影|摄影机调度|时间轴与状态演变|美学介质与底层渲染)：'
            $shotFormat = if ($hasCinematicField) { 'CINEMATIC_6' } else { 'FIVE_LINE' }
            $fields = if ($hasCinematicField) { $cinematicFields } else { $fiveFields }
            foreach ($field in $fields) {
                $count = [regex]::Matches($block, "(?m)^$([regex]::Escape($field))").Count
                if ($count -ne 1) {
                    Add-Failure "Field count mismatch for $field in ${shotLabel}: expected 1, got $count."
                }
            }
            if (-not $hasCinematicField) {
                $soundLine = [regex]::Match($block, '(?m)^音效：[^\r\n]*').Value
                foreach ($timeMatch in [regex]::Matches($soundLine, '(?<![\d.])(?<time>\d+(?:\.\d+)?)(?:s|秒)(?=[ \t]*\+)')) {
                    $soundTime = [double]$timeMatch.Groups['time'].Value
                    if (-not (Test-HalfSecond $soundTime)) {
                        $timeGranularityStatus = 'FAIL'
                        Add-Failure "Sound timecode must use 0.5-second increments in ${shotLabel}: $($timeMatch.Value)"
                    }
                    if ($soundTime -lt $start -or $soundTime -ge $end) {
                        Add-Failure "Sound timecode must start within shot ${shotLabel}: $($timeMatch.Value)"
                    }
                }
            }
        }
        elseif (-not $baseId -and $ExpectedAbsentShotId) {
            Add-Failure "Compact shot has no ID for checking expected absent shots: $shotLabel"
        }
        $cameraText = if ($shotFormat -eq 'COMPACT') {
            $block
        } else {
            [regex]::Match($block, '(?m)^(?:运镜|摄影机调度)：[^\r\n]*').Value
        }
        $cameraText = $cameraText -replace '「[^」]*」', ''
        foreach ($cut in [regex]::Matches($cameraText, '(?<![\d.])(?<from>\d+(?:\.\d+)?)[ \t]*[-–—][ \t]*(?<to>\d+(?:\.\d+)?)秒[：:]')) {
            $cutFrom = [double]$cut.Groups['from'].Value
            $cutTo = [double]$cut.Groups['to'].Value
            if (-not (Test-HalfSecond $cutFrom) -or -not (Test-HalfSecond $cutTo)) {
                $timeGranularityStatus = 'FAIL'
                Add-Failure "Camera cut time must use 0.5-second increments in ${shotLabel}: $($cut.Value)"
            }
            if ($cutFrom -lt $start -or $cutTo -gt $end -or $cutTo -le $cutFrom) {
                Add-Failure "Camera cut range must stay within shot ${shotLabel}: $($cut.Value)"
            }
        }
        $null = $detectedFormats.Add($shotFormat)

        $shotDuration = $end - $start
        if (-not (Test-HalfSecond $start) -or -not (Test-HalfSecond $end) -or -not (Test-HalfSecond $shotDuration)) {
            $timeGranularityStatus = 'FAIL'
            Add-Failure "Shot time must use 0.5-second increments for $($match.Value.Trim())"
        }

        if ($end -le $start) {
            Add-Failure "Invalid shot time range: $($match.Value.Trim())"
        }
        if ($shotIndex -eq 0 -and [math]::Abs($start) -gt 0.01) {
            Add-Failure "Segment $segmentId does not start at 0 seconds: $rawId"
        }
        if ($shotIndex -gt 0 -and [math]::Abs($start - $previousEnd) -gt 0.01) {
            Add-Failure "Timeline gap or overlap in $segmentId before ${rawId}: previous end $previousEnd, next start $start."
        }

        $segmentTimeline += ($end - $start)
        $previousEnd = $end
        if ($baseId) { $shotIds.Add($baseId) }
        $shotRecords.Add([pscustomobject]@{
            Label    = $shotLabel
            Duration = $shotDuration
            Block    = $block
            BaseId   = $baseId
            Format   = $shotFormat
        })
    }

    $timelineTotal += $segmentTimeline
    if (-not (Test-IntegerSecond $segmentTimeline) -or -not (Test-IntegerSecond $previousEnd)) {
        $timeGranularityStatus = 'FAIL'
        Add-Failure "Generation segment $segmentId timeline must end at an integer second; got $previousEnd"
    }
    if ([math]::Abs($segmentTimeline - $seconds) -gt 0.01 -or [math]::Abs($previousEnd - $seconds) -gt 0.01) {
        Add-Failure "Segment $segmentId duration $seconds does not match its local timeline total $segmentTimeline or final time $previousEnd."
    }
}

if ([math]::Abs($segmentTotal - $timelineTotal) -gt 0.01) {
    Add-Failure "Segment total $segmentTotal does not match timeline total $timelineTotal."
}

$soundSectionPattern = '(?ms)^【音效】(?<body>.*?)(?=^【连续性限制】|^#{1,3}\s+|\z)'
foreach ($soundSection in [regex]::Matches($promptBodyText, $soundSectionPattern)) {
    foreach ($timeMatch in [regex]::Matches($soundSection.Groups['body'].Value, '(?<![\w.])(?<time>\d+(?:\.\d+)?)(?:s|秒)')) {
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

$canonicalPrefix = [regex]::Matches($promptBodyText, '(?m)^整段视频默认无文字无字幕；剧本明确要求的剧情内文字除外。\s*$').Count
$legacyPrefix = [regex]::Matches($promptBodyText, '(?m)^整段视频无文字无字幕。\s*$').Count
$prefixCount = $canonicalPrefix + $legacyPrefix
if ($prefixCount -ne $segmentMatches.Count) {
    Add-Failure "No-subtitle prefix count expected $($segmentMatches.Count), got $prefixCount."
}
if ($legacyPrefix -gt 0) {
    Add-Warning "Legacy no-subtitle prefix found in $legacyPrefix segment(s); new files should use the canonical prefix."
}

if ($promptBodyText.Contains('`r`n')) {
    Add-Failure 'Literal PowerShell newline escape found: `r`n'
}

$compactLinePattern = '^\d+(?:\.\d+)?-\d+(?:\.\d+)?秒(?:｜[^：:]+)?[：:]'
$relativePattern = '承接上一镜|保持上一段状态|同上|位置不变|继续前一动作|供下一段续接'
$continuityConstraintRelativePattern = '承接上一镜|保持上一段状态|同上|继续前一动作|供下一段续接'
$bodyCheckLines = $promptBodyText -split "`r?`n" | Where-Object {
    $_ -match $compactLinePattern -or $_ -match '^(?:【场景】|【人物】|@[^\r\n]+|整体画面：|绝对主体与物理动势：|环境场与情绪光影：|摄影机调度：|时间轴与状态演变：|美学介质与底层渲染：|画面：|运镜：|光影：|台词：|音效：)'
}
foreach ($line in $bodyCheckLines) {
    if ($line -match $relativePattern) {
        Add-Failure "Relative continuity instruction found: $line"
    }
}
$continuityLines = $promptBodyText -split "`r?`n" | Where-Object { $_ -match '^【连续性限制】' }
foreach ($line in $continuityLines) {
    if ($line -match $continuityConstraintRelativePattern) {
        Add-Failure "Relative continuity instruction found: $line"
    }
}

$cameraLines = $bodyCheckLines | Where-Object { $_ -match '^(?:摄影机调度|运镜|画面|整体画面)：' -or $_ -match $compactLinePattern }
foreach ($line in $cameraLines) {
    $mentionsOverShoulder = ($line -match '过肩|肩后')
    $explicitlyNoOverShoulder = ($line -match '不设置.*过肩|无肩前景|不设置前景过肩|非过肩')
    if ($mentionsOverShoulder -and (-not $explicitlyNoOverShoulder) -and ($line -notmatch '左肩|右肩|左后肩|右后肩')) {
        Add-Warning "Over-shoulder camera line does not name left/right shoulder: $line"
    }
}

$segmentRosterEntities = @(
    [regex]::Matches($promptBodyText, '(?m)^@([A-Za-z0-9\p{IsCJKUnifiedIdeographs}·_-]{1,12})(?=[（(：:\s]|$)') |
        ForEach-Object { Strip-EntitySuffix (Normalize-Entity $_.Groups[1].Value) }
)
$knownActorList = @(@(Split-EntityInputs $ExpectedEntity) + @($segmentRosterEntities) | Where-Object { $_ } | Select-Object -Unique | Sort-Object Length -Descending)

$promptDialogueList = [System.Collections.Generic.List[string]]::new()
$promptDialogueRecords = [System.Collections.Generic.List[object]]::new()
foreach ($shot in $shotRecords) {
    $records = @(Get-ShotDialogue $shot)
    $spoken = @($records | ForEach-Object { $_.Text })
    foreach ($record in $records) { $promptDialogueRecords.Add($record) }
    foreach ($line in $spoken) { $promptDialogueList.Add($line) }
    if ($spoken.Count -gt 0) {
        $spokenText = $spoken -join ''
        $hanCount = [regex]::Matches($spokenText, '[\p{IsCJKUnifiedIdeographs}]').Count
        $duration = $shot.Duration
        if ($duration -gt 0) {
            $rate = $hanCount / $duration
            if ($rate -gt 6.0) {
                Add-Warning "Dialogue rate above 6 chars/s in $($shot.Label): $([math]::Round($rate, 2))"
            }
        }
    }

    if ($AspectRatio -eq '9:16') {
        $visualText = $shot.Block
        if ($shot.Format -eq 'FIVE_LINE') {
            $visualText = [regex]::Match($shot.Block, '(?m)^画面：[^\r\n]*').Value
        }
        elseif ($shot.Format -eq 'CINEMATIC_6') {
            $visualText = (([regex]::Matches($shot.Block, '(?m)^(?:整体画面|绝对主体与物理动势|时间轴与状态演变)：[^\r\n]*') | ForEach-Object { $_.Value }) -join "`n")
        }

        $isEmptyOrPropShot = ($shot.Block -match '本镜头无人物|画面无人物|空镜|纯手部|道具特写')
        if (($spoken.Count -gt 0) -and (-not $isEmptyOrPropShot) -and ($shot.Block -notmatch '【表情与口型】')) {
            Add-Warning "FACIAL_LIPSYNC_MISSING_9X16: 9:16 dialogue shot $($shot.Label) is missing 【表情与口型】."
        }

        $isWideShot = ($shot.Block -match '全景|大全景')
        $isOverShoulder = ($shot.Block -match '过肩|左肩后方|右肩后方')
        $hasTimecodedCutaway = ($shot.Block -match '(?:^|[^*])\d+(?:\.\d+)?-\d+(?:\.\d+)?秒[：:]')
        $explicitlySingleFace = ($shot.Block -match '仅1张清晰人脸|一张清晰人脸|不露脸|不含脸|背影|肩背|单人反应|单人近景|单人中近景|单人特写')
        if ((-not $isWideShot) -and (-not $isOverShoulder) -and (-not $isEmptyOrPropShot) -and (-not $explicitlySingleFace) -and (-not $hasTimecodedCutaway)) {
            $onScreenText = $visualText -replace '[（(][^）)\r\n]*(?:不出画|未入画|画外)[^）)\r\n]*[）)]', ''
            $onScreenText = $onScreenText -replace '画外(?:的|方向)?@[A-Za-z0-9\p{IsCJKUnifiedIdeographs}·_-]+', ''
            $onScreenText = $onScreenText -replace '(?m)^台词：[^\r\n]*', ''
            $visualActorSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($actorMatch in [regex]::Matches($onScreenText, '@([A-Za-z0-9\p{IsCJKUnifiedIdeographs}·_-]{1,12})')) {
                $rawActor = Normalize-Entity $actorMatch.Groups[1].Value
                $matchedKnown = @($knownActorList | Where-Object { $rawActor.StartsWith($_, [System.StringComparison]::Ordinal) } | Select-Object -First 1)
                $canonActor = if ($matchedKnown.Count -gt 0) { $matchedKnown[0] } else { Strip-EntitySuffix $rawActor }
                if ($canonActor) { $null = $visualActorSet.Add($canonActor) }
            }
            if ($visualActorSet.Count -gt 1) {
                Add-Warning "MULTI_FACE_RISK_9X16: Non-wide non-OTS 9:16 shot $($shot.Label) mentions multiple on-screen @entities ($($visualActorSet -join ', ')); verify only 1 clear face appears."
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
    $escapedStyle = [regex]::Escape($ExpectedStylePrefix) -replace '\\r\\n|\\n|\\r', '\r?\n'
    $styleCount = [regex]::Matches($promptBodyText, $escapedStyle).Count
    if ($styleCount -ne $segmentMatches.Count) {
        Add-Failure "Explicit style prefix count expected $($segmentMatches.Count), got $styleCount."
    }
}

$entityBaselineText = ''
if ($SourcePath) {
    try {
        $source = Read-StrictUtf8 $SourcePath
        if ($Episode -gt 0) {
            $episodePattern = "(?s)#{1,3}[ \t]*第[ \t]*$Episode[ \t]*集.*?(?=\r?\n#{1,3}[ \t]*第[ \t]*\d+[ \t]*集|\r?\n#{1,2}[ \t]+(?:附录|人物|场景|总结)|\z)"
            $episodeMatch = [regex]::Match($source, $episodePattern)
            if (-not $episodeMatch.Success) {
                Add-Failure "Episode $Episode not found in source."
            }
            else {
                $source = $episodeMatch.Value
            }
        }

        $entityBaselineText = $source

        $sourceDialogue = @([regex]::Matches($source, '「([^」]+)」') | ForEach-Object { $_.Groups[1].Value })
        if ($PartialScope -and -not $ExpectedDialoguePath) {
            Add-Warning 'PartialScope with SourcePath alone checks only order and text. Use ExpectedDialoguePath for completeness and speaker/type checks.'
            if ($sourceDialogue.Count -gt 0 -and $promptDialogueList.Count -eq 0) {
                Add-Failure 'No prompt dialogue in partial scope; provide an ExpectedDialoguePath declaring a dialogue-free range if intentional.'
            }
            $searchPos = 0
            for ($pIndex = 0; $pIndex -lt $promptDialogueList.Count; $pIndex++) {
                $line = $promptDialogueList[$pIndex]
                $found = $false
                for ($sIndex = $searchPos; $sIndex -lt $sourceDialogue.Count; $sIndex++) {
                    if ($sourceDialogue[$sIndex] -ceq $line) {
                        $searchPos = $sIndex + 1
                        $found = $true
                        break
                    }
                }
                if (-not $found) {
                    Add-Failure "Partial-scope dialogue mismatch or out-of-order at prompt line $($pIndex + 1): $line"
                    break
                }
            }
        }
        elseif (-not $ExpectedDialoguePath) {
            if ($promptDialogueList.Count -ne $sourceDialogue.Count) {
                Add-Failure "Dialogue count expected $($sourceDialogue.Count), got $($promptDialogueList.Count)."
            }
            else {
                for ($index = 0; $index -lt $sourceDialogue.Count; $index++) {
                    if ($promptDialogueList[$index] -cne $sourceDialogue[$index]) {
                        Add-Failure "Dialogue mismatch at index $($index + 1)."
                        break
                    }
                }
            }
        }
    }
    catch {
        Add-Failure "Source read or dialogue audit failed: $($_.Exception.Message)"
    }
}

if ($ExpectedDialoguePath) {
    try {
        Test-DialogueContract $ExpectedDialoguePath $promptDialogueRecords.ToArray()
    }
    catch {
        Add-Failure "Structured dialogue audit failed: $($_.Exception.Message)"
    }
}
elseif ($SourcePath -and -not $PartialScope) {
    Add-Warning 'SourcePath alone compares quoted text. Use ExpectedDialoguePath for speaker and voice-kind checks.'
}

if ($entityBaselineText -or $ExpectedEntity) {
    $splitExpected = @(Split-EntityInputs $ExpectedEntity)
    $sourceEntities = Get-EntitySet $entityBaselineText $true $splitExpected
    foreach ($value in $splitExpected) {
        if ($value) { $null = $sourceEntities.Add($value) }
    }

    $promptEntities = Get-EntitySet $promptBodyText $false @($sourceEntities)
    $allowedExtras = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($value in @(Split-EntityInputs $AllowedExtraEntity)) {
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

$formatLabel = if ($detectedFormats.Count -eq 1) { @($detectedFormats)[0] } elseif ($detectedFormats.Count -gt 1) { 'MIXED' } else { 'UNKNOWN' }
Write-Output "SEGMENTS=$($segmentMatches.Count) FORMAT=$formatLabel MAX_SEGMENT=$maxSegment SELECTED_MAX=$MaxSegmentSeconds ASPECT_RATIO=$AspectRatio TOTAL=$segmentTotal"
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
