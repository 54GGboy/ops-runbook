[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ListTitles', 'SearchTitle', 'ReadSection', 'ValidateEntry', 'CheckConflicts', 'AppendSection', 'UpdateSection', 'ReplaceSection')]
    [string]$Action,

    [string]$LibraryPath = 'C:\Users\49533\Desktop\解决方案命令.md',
    [string]$Query,
    [string]$Title,
    [string]$EntryPath,
    [string]$ExpectedLibraryHash,
    [switch]$AllowSimilarTitle,
    [switch]$ConfirmUpdate,
    [switch]$ConfirmReplace,
    [switch]$AllowAlternatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DefaultLibraryPath = 'C:\Users\49533\Desktop\解决方案命令.md'
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false, $true)
$script:NewLine = "`r`n"
$script:SimilarityThreshold = 0.58

function Stop-RunbookOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Details
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['ErrorCode'] = $Code
    if ($null -ne $Details) {
        $exception.Data['Details'] = $Details
    }
    throw $exception
}

function Write-JsonResult {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Data)

    $result = [ordered]@{ ok = $true }
    foreach ($key in $Data.Keys) {
        $result[$key] = $Data[$key]
    }
    Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
}

function Get-NormalizedTitle {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return ([regex]::Replace($Value.Trim(), '^##[ \t]+', '')).Trim()
}

function Get-CanonicalText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    $normalized = $Value.Normalize([System.Text.NormalizationForm]::FormKC).ToLowerInvariant()
    return ([regex]::Replace($normalized, '\s+', ' ')).Trim()
}

function Test-TitleEquals {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [string]::Equals(
        (Get-CanonicalText -Value (Get-NormalizedTitle -Value $Left)),
        (Get-CanonicalText -Value (Get-NormalizedTitle -Value $Right)),
        [System.StringComparison]::Ordinal
    )
}

function Get-TitleParts {
    param([Parameter(Mandatory = $true)][string]$Value)

    $title = Get-NormalizedTitle -Value $Value
    if ($title -notmatch '^\[(?<system>[^\]\r\n]+)\]\[(?<tool>[^\]\r\n]+)\][ \t]+(?<subject>\S.*)$') {
        return $null
    }
    return [pscustomobject]@{
        System = Get-CanonicalText -Value $Matches['system']
        Tool = Get-CanonicalText -Value $Matches['tool']
        Subject = Get-CanonicalText -Value $Matches['subject']
    }
}

function Get-CompactComparableText {
    param([string]$Value)

    return [regex]::Replace((Get-CanonicalText -Value $Value), '[^\p{L}\p{Nd}]+', '')
}

function Get-BigramCounts {
    param([Parameter(Mandatory = $true)][string]$Value)

    $counts = @{}
    if ($Value.Length -lt 2) {
        if ($Value.Length -eq 1) { $counts[$Value] = 1 }
        return $counts
    }
    for ($index = 0; $index -lt $Value.Length - 1; $index++) {
        $gram = $Value.Substring($index, 2)
        if ($counts.ContainsKey($gram)) { $counts[$gram]++ } else { $counts[$gram] = 1 }
    }
    return $counts
}

function Get-DiceCoefficient {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    if ($Left -eq $Right) { return 1.0 }
    if ($Left.Length -eq 0 -or $Right.Length -eq 0) { return 0.0 }
    $leftCounts = Get-BigramCounts -Value $Left
    $rightCounts = Get-BigramCounts -Value $Right
    $leftTotal = 0
    $rightTotal = 0
    foreach ($value in $leftCounts.Values) { $leftTotal += $value }
    foreach ($value in $rightCounts.Values) { $rightTotal += $value }
    if (($leftTotal + $rightTotal) -eq 0) { return 0.0 }
    $overlap = 0
    foreach ($key in $leftCounts.Keys) {
        if ($rightCounts.ContainsKey($key)) {
            $overlap += [Math]::Min($leftCounts[$key], $rightCounts[$key])
        }
    }
    return (2.0 * $overlap) / ($leftTotal + $rightTotal)
}

function Get-TitleSimilarity {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftParts = Get-TitleParts -Value $Left
    $rightParts = Get-TitleParts -Value $Right
    if ($null -eq $leftParts -or $null -eq $rightParts) { return 0.0 }
    if ($leftParts.System -ne $rightParts.System -or $leftParts.Tool -ne $rightParts.Tool) { return 0.0 }
    $leftSubject = Get-CompactComparableText -Value $leftParts.Subject
    $rightSubject = Get-CompactComparableText -Value $rightParts.Subject
    if ($leftSubject -eq $rightSubject) { return 1.0 }
    $shorterLength = [Math]::Min($leftSubject.Length, $rightSubject.Length)
    if ($shorterLength -ge 4 -and ($leftSubject.Contains($rightSubject) -or $rightSubject.Contains($leftSubject))) {
        return 0.85
    }
    return Get-DiceCoefficient -Left $leftSubject -Right $rightSubject
}

function Get-TitleConflicts {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ExistingTitles,
        [Parameter(Mandatory = $true)][string]$CandidateTitle
    )

    $duplicates = [System.Collections.Generic.List[string]]::new()
    $similar = [System.Collections.Generic.List[string]]::new()
    foreach ($existingTitle in $ExistingTitles) {
        if (Test-TitleEquals -Left $existingTitle -Right $CandidateTitle) {
            [void]$duplicates.Add($existingTitle)
            continue
        }
        if ((Get-TitleSimilarity -Left $existingTitle -Right $CandidateTitle) -ge $script:SimilarityThreshold) {
            [void]$similar.Add($existingTitle)
        }
    }
    return [pscustomobject]@{
        DuplicateTitles = $duplicates.ToArray()
        SimilarTitles = $similar.ToArray()
    }
}

function Assert-LibraryPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $defaultResolved = [System.IO.Path]::GetFullPath($script:DefaultLibraryPath)
    if (-not $AllowAlternatePath -and
        -not [string]::Equals($resolved, $defaultResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-RunbookOperation -Code 'AlternatePathDenied' -Message '正式操作只允许使用固定的桌面解决方案库。'
    }
    return $resolved
}

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        Stop-RunbookOperation -Code 'FileNotFound' -Message "文件不存在：$Path"
    }
    try {
        return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
    }
    catch [System.Text.DecoderFallbackException] {
        Stop-RunbookOperation -Code 'InvalidUtf8' -Message "文件不是有效的 UTF-8：$Path"
    }
}

function Get-MarkdownHeadings {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content)

    $records = [System.Collections.Generic.List[object]]::new()
    $insideFence = $false
    $linePattern = '(?m)^[^\r\n]*(?:\r\n|\n|\r|$)'
    foreach ($lineMatch in [regex]::Matches($Content, $linePattern)) {
        if ($lineMatch.Length -eq 0) {
            continue
        }
        $line = $lineMatch.Value.TrimEnd([char[]]"`r`n")
        if ($line -match '^[ \t]*```') {
            $insideFence = -not $insideFence
            continue
        }
        if (-not $insideFence -and $line -match '^(?<marks>#{1,6})[ \t]+(?<text>.+?)[ \t]*$') {
            [void]$records.Add([pscustomobject]@{
                    Level = $Matches['marks'].Length
                    Title = $Matches['text'].Trim()
                    Start = $lineMatch.Index
                })
        }
    }
    return $records.ToArray()
}

function Get-LibraryTitles {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return @()
    }

    $titles = [System.Collections.Generic.List[string]]::new()
    $insideFence = $false
    try {
        foreach ($line in [System.IO.File]::ReadLines($Path, $script:Utf8NoBom)) {
            if ($line -match '^[ \t]*```') {
                $insideFence = -not $insideFence
                continue
            }
            if (-not $insideFence -and $line -match '^##[ \t]+(?<title>.+?)[ \t]*$') {
                [void]$titles.Add($Matches['title'].Trim())
            }
        }
    }
    catch [System.Text.DecoderFallbackException] {
        Stop-RunbookOperation -Code 'InvalidUtf8' -Message "解决方案库不是有效的 UTF-8：$Path"
    }
    return $titles.ToArray()
}

function Test-TitleQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$SearchText
    )

    $normalizedCandidate = Get-CanonicalText -Value $Candidate
    $normalizedQuery = Get-CanonicalText -Value $SearchText
    if ($normalizedCandidate.Contains($normalizedQuery)) {
        return $true
    }
    $queryWords = [regex]::Replace($normalizedQuery, '[^\p{L}\p{Nd}]+', ' ')
    $tokens = @([regex]::Split($queryWords, '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($token in $tokens) {
        if (-not $normalizedCandidate.Contains($token)) {
            return $false
        }
    }
    return ($tokens.Count -gt 0)
}

function Assert-NoSecrets {
    param([Parameter(Mandatory = $true)][string]$Content)

    $fixedSecretPatterns = @(
        '-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----',
        '(?i)\bAKIA[0-9A-Z]{16}\b',
        '(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b',
        '(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b',
        '(?i)\bBearer[ \t]+[A-Za-z0-9._~+/=-]{20,}\b',
        '(?i)\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
        '(?i)https?://[^\s/:]+:[^\s/@]+@'
    )
    foreach ($pattern in $fixedSecretPatterns) {
        if ([regex]::IsMatch($Content, $pattern)) {
            Stop-RunbookOperation -Code 'SecretDetected' -Message '候选条目疑似包含真实认证材料，请改用占位符或环境变量。'
        }
    }

    $assignmentPattern = '(?im)\b(?:password|passwd|pwd|token|api[_-]?key|secret|client[_-]?secret|account[_-]?key|cookie|connection[_-]?string)\b[ \t]*[:=][ \t]*["'']?(?<value>[^"''`\s;#]+)'
    foreach ($match in [regex]::Matches($Content, $assignmentPattern)) {
        $value = $match.Groups['value'].Value.Trim()
        $isPlaceholder =
            ($value -match '^<[^>]+>$') -or
            ($value -match '^\$\{?[A-Za-z_][A-Za-z0-9_:.-]*\}?$') -or
            ($value -match '(?i)^(?:your|example|replace|placeholder|redacted|test)[_-]') -or
            ($value -match '(?i)^(?:changeme|xxx+|redacted|placeholder)$')
        if (-not $isPlaceholder) {
            Stop-RunbookOperation -Code 'SecretDetected' -Message '候选条目疑似包含明文密码、Token、Cookie 或 API Key，请改用占位符或环境变量。'
        }
    }
}

function Get-NextNonBlankIndex {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$StartIndex
    )

    $index = $StartIndex
    while ($index -lt $Lines.Count -and [string]::IsNullOrWhiteSpace($Lines[$index])) {
        $index++
    }
    return $index
}

function Read-RequiredCodeBlock {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][int]$StartIndex,
        [Parameter(Mandatory = $true)][string]$SectionName
    )

    $openingIndex = Get-NextNonBlankIndex -Lines $Lines -StartIndex $StartIndex
    if ($openingIndex -ge $Lines.Count -or $Lines[$openingIndex] -notmatch '^```(?<language>[A-Za-z0-9_+.-]+)[ \t]*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message ("章节 [{0}] 必须包含一个带语言标识的代码块。" -f $SectionName)
    }

    $closingIndex = -1
    $hasContent = $false
    for ($index = $openingIndex + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^```[ \t]*$') {
            $closingIndex = $index
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($Lines[$index])) {
            $hasContent = $true
        }
    }
    if ($closingIndex -lt 0) {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message ("章节 [{0}] 的代码块没有正确闭合。" -f $SectionName)
    }
    if (-not $hasContent) {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message ("章节 [{0}] 的代码块不能为空。" -f $SectionName)
    }

    return [pscustomobject]@{ NextIndex = $closingIndex + 1 }
}

function Test-AndGetEntry {
    param([Parameter(Mandatory = $true)][string]$Path)

    $entry = (Read-Utf8Text -Path ([System.IO.Path]::GetFullPath($Path))).Trim()
    if ([string]::IsNullOrWhiteSpace($entry)) {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '候选条目为空。'
    }

    Assert-NoSecrets -Content $entry
    $lines = @([regex]::Split($entry, '\r\n|\n|\r'))
    if ($lines.Count -eq 0 -or $lines[0] -notmatch '^##[ \t]+(?<title>\S.*?)[ \t]*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '候选条目必须从唯一的二级标题开始。'
    }
    $entryTitle = $Matches['title'].Trim()
    if ($null -eq (Get-TitleParts -Value $entryTitle)) {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '标题必须使用“[系统][工具] 具体问题或目标”格式。'
    }

    $problemIndex = 1
    if ($problemIndex -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$problemIndex])) {
        $problemIndex++
    }
    if ($problemIndex -ge $lines.Count -or [string]::IsNullOrWhiteSpace($lines[$problemIndex]) -or
        $lines[$problemIndex] -notmatch '^\*\*问题现象：\*\*[ \t]*\S.*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '问题现象必须紧跟标题，中间最多一个空行，并用一句话说明。'
    }

    $statusIndex = Get-NextNonBlankIndex -Lines $lines -StartIndex ($problemIndex + 1)
    if ($statusIndex -ge $lines.Count -or $lines[$statusIndex] -notmatch '^- 状态：(?:未验证|已验证)[ \t]*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '问题现象后必须依次填写状态、环境和权限。'
    }
    $environmentIndex = $statusIndex + 1
    if ($environmentIndex -ge $lines.Count -or $lines[$environmentIndex] -notmatch '^- 环境：\S.*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '环境字段必须紧跟状态字段。'
    }
    $permissionIndex = $environmentIndex + 1
    if ($permissionIndex -ge $lines.Count -or $lines[$permissionIndex] -notmatch '^- 权限：\S.*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '权限字段必须紧跟环境字段。'
    }

    $currentHeadingIndex = Get-NextNonBlankIndex -Lines $lines -StartIndex ($permissionIndex + 1)
    if ($currentHeadingIndex -ge $lines.Count -or $lines[$currentHeadingIndex] -ne '### 当前案例') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '权限字段后必须是“当前案例”章节。'
    }
    $currentBlock = Read-RequiredCodeBlock -Lines $lines -StartIndex ($currentHeadingIndex + 1) -SectionName '当前案例'

    $generalHeadingIndex = Get-NextNonBlankIndex -Lines $lines -StartIndex $currentBlock.NextIndex
    if ($generalHeadingIndex -ge $lines.Count -or $lines[$generalHeadingIndex] -ne '### 通用命令模块') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '当前案例后必须是“通用命令模块”章节。'
    }
    $generalBlock = Read-RequiredCodeBlock -Lines $lines -StartIndex ($generalHeadingIndex + 1) -SectionName '通用命令模块'

    $riskIndex = Get-NextNonBlankIndex -Lines $lines -StartIndex $generalBlock.NextIndex
    if ($riskIndex -ge $lines.Count -or $lines[$riskIndex] -notmatch '^>[ \t]+\S.*$') {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '通用命令模块后必须填写一行风险提示。'
    }
    $afterRiskIndex = Get-NextNonBlankIndex -Lines $lines -StartIndex ($riskIndex + 1)
    if ($afterRiskIndex -lt $lines.Count) {
        Stop-RunbookOperation -Code 'InvalidEntryFormat' -Message '风险提示必须是候选条目的最后一个非空行。'
    }

    return [pscustomobject]@{
        Text = [string]::Join($script:NewLine, $lines)
        Title = $entryTitle
    }
}

function Save-TextAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) {
        Stop-RunbookOperation -Code 'DirectoryNotFound' -Message "目标目录不存在：$directory"
    }
    $temporaryPath = [System.IO.Path]::Combine(
        $directory,
        '.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    )
    $backupPath = $null
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $script:Utf8NoBom)
        if ([System.IO.File]::Exists($Path)) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $extension = [System.IO.Path]::GetExtension($Path)
            $backupDirectory = [System.IO.Path]::Combine($directory, $baseName + '.backups')
            [void][System.IO.Directory]::CreateDirectory($backupDirectory)
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $backupPath = [System.IO.Path]::Combine(
                $backupDirectory,
                $baseName + '.' + $stamp + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + $extension
            )
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
        return $backupPath
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Get-LibraryHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return 'MISSING'
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Assert-ExpectedLibraryHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedHash
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        Stop-RunbookOperation -Code 'MissingExpectedLibraryHash' -Message '写入前必须提供刚从 CheckConflicts 或 ReadSection 取得的 ExpectedLibraryHash。'
    }
    $currentHash = Get-LibraryHash -Path $Path
    if (-not [string]::Equals($currentHash, $ExpectedHash.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-RunbookOperation -Code 'LibraryChanged' -Message '解决方案库在检查后发生了变化，请重新查询或检查冲突。' -Details ([ordered]@{
                expectedLibraryHash = $ExpectedHash.Trim()
                currentLibraryHash = $currentHash
            })
    }
}

function Invoke-WithLibraryLock {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($directory)) {
        Stop-RunbookOperation -Code 'DirectoryNotFound' -Message "目标目录不存在：$directory"
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $pathBytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Path)).ToLowerInvariant())
        $pathHash = ([System.BitConverter]::ToString($sha256.ComputeHash($pathBytes))).Replace('-', '').Substring(0, 32)
    }
    finally {
        $sha256.Dispose()
    }
    $mutex = [System.Threading.Mutex]::new($false, 'Local\OpsRunbook_' + $pathHash)
    $lockAcquired = $false
    try {
        try {
            $lockAcquired = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockAcquired = $true
        }
        if (-not $lockAcquired) {
            Stop-RunbookOperation -Code 'LibraryBusy' -Message '解决方案库正被另一个操作占用，请稍后重试。'
        }
        & $Operation
    }
    finally {
        if ($lockAcquired) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Invoke-UpdateLibrarySection {
    param(
        [Parameter(Mandatory = $true)][string]$ActionName,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$SourceTitle,
        [string]$CandidatePath,
        [string]$ExpectedHash,
        [Parameter(Mandatory = $true)][bool]$IsConfirmed,
        [Parameter(Mandatory = $true)][bool]$AllowSimilar
    )

    if (-not $IsConfirmed) {
        Stop-RunbookOperation -Code 'UpdateNotConfirmed' -Message '更新现有方案必须显式提供 ConfirmUpdate；兼容的 ReplaceSection 可使用 ConfirmReplace。'
    }
    $normalizedSourceTitle = Get-NormalizedTitle -Value $SourceTitle
    if ([string]::IsNullOrWhiteSpace($normalizedSourceTitle) -or [string]::IsNullOrWhiteSpace($CandidatePath)) {
        Stop-RunbookOperation -Code 'MissingUpdateInput' -Message 'UpdateSection 需要完整旧标题和候选条目文件。'
    }

    Invoke-WithLibraryLock -Path $Path -Operation {
        Assert-ExpectedLibraryHash -Path $Path -ExpectedHash $ExpectedHash
        $entry = Test-AndGetEntry -Path $CandidatePath
        $content = Read-Utf8Text -Path $Path
        $records = @(Get-MarkdownHeadings -Content $content | Where-Object { $_.Level -eq 2 })
        $targetIndexes = @()
        for ($index = 0; $index -lt $records.Count; $index++) {
            if (Test-TitleEquals -Left $records[$index].Title -Right $normalizedSourceTitle) {
                $targetIndexes += $index
            }
        }
        if ($targetIndexes.Count -ne 1) {
            Stop-RunbookOperation -Code 'TitleNotUnique' -Message '更新操作要求旧标题唯一命中。'
        }

        $targetIndex = $targetIndexes[0]
        $remainingTitles = [System.Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $records.Count; $index++) {
            if ($index -ne $targetIndex) { [void]$remainingTitles.Add($records[$index].Title) }
        }
        $conflicts = Get-TitleConflicts -ExistingTitles $remainingTitles.ToArray() -CandidateTitle $entry.Title
        if ($conflicts.DuplicateTitles.Count -gt 0) {
            Stop-RunbookOperation -Code 'DuplicateTitle' -Message '更新后的标题与另一个条目完全同名，不能产生重复标题。' -Details ([ordered]@{
                    duplicateTitles = $conflicts.DuplicateTitles
                })
        }
        if ($conflicts.SimilarTitles.Count -gt 0 -and -not $AllowSimilar) {
            Stop-RunbookOperation -Code 'SimilarTitleDecisionRequired' -Message '更新后的标题与其他条目相似，请询问用户要分别保留还是合并为一个。' -Details ([ordered]@{
                    similarTitles = $conflicts.SimilarTitles
                })
        }

        $sectionEnd = if ($targetIndex + 1 -lt $records.Count) { $records[$targetIndex + 1].Start } else { $content.Length }
        $before = $content.Substring(0, $records[$targetIndex].Start).TrimEnd([char[]]"`r`n")
        $after = $content.Substring($sectionEnd).Trim([char[]]"`r`n")
        $parts = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($before)) { [void]$parts.Add($before) }
        [void]$parts.Add($entry.Text)
        if (-not [string]::IsNullOrWhiteSpace($after)) { [void]$parts.Add($after) }
        $newContent = [string]::Join($script:NewLine + $script:NewLine, $parts) + $script:NewLine
        $backupPath = Save-TextAtomically -Path $Path -Content $newContent
        $oldTitle = $records[$targetIndex].Title
        Write-JsonResult -Data ([ordered]@{
                action = $ActionName
                oldTitle = $oldTitle
                title = $entry.Title
                titleChanged = -not [string]::Equals($oldTitle, $entry.Title, [System.StringComparison]::Ordinal)
                updated = $true
                replaced = ($ActionName -eq 'ReplaceSection')
                backupPath = $backupPath
                libraryHash = Get-LibraryHash -Path $Path
            })
    }
}

try {
    $resolvedLibraryPath = Assert-LibraryPath -Path $LibraryPath

    switch ($Action) {
        'ListTitles' {
            $titles = @(Get-LibraryTitles -Path $resolvedLibraryPath)
            Write-JsonResult -Data ([ordered]@{
                    action = $Action
                    count = $titles.Count
                    titles = $titles
                    libraryHash = Get-LibraryHash -Path $resolvedLibraryPath
                })
        }

        'SearchTitle' {
            if ([string]::IsNullOrWhiteSpace($Query)) {
                Stop-RunbookOperation -Code 'MissingQuery' -Message 'SearchTitle 需要 Query。'
            }
            $matches = @(
                Get-LibraryTitles -Path $resolvedLibraryPath |
                    Where-Object { Test-TitleQuery -Candidate $_ -SearchText $Query }
            )
            Write-JsonResult -Data ([ordered]@{
                    action = $Action
                    query = $Query.Trim()
                    count = $matches.Count
                    titles = $matches
                    libraryHash = Get-LibraryHash -Path $resolvedLibraryPath
                })
        }

        'ReadSection' {
            $normalizedTitle = Get-NormalizedTitle -Value $Title
            if ([string]::IsNullOrWhiteSpace($normalizedTitle)) {
                Stop-RunbookOperation -Code 'MissingTitle' -Message 'ReadSection 需要完整标题。'
            }
            $titleMatches = @(
                Get-LibraryTitles -Path $resolvedLibraryPath |
                    Where-Object { Test-TitleEquals -Left $_ -Right $normalizedTitle }
            )
            if ($titleMatches.Count -ne 1) {
                Stop-RunbookOperation -Code 'TitleNotUnique' -Message '只有标题唯一命中时才能读取正文。'
            }

            $content = Read-Utf8Text -Path $resolvedLibraryPath
            $records = @(Get-MarkdownHeadings -Content $content | Where-Object { $_.Level -eq 2 })
            $targetIndex = -1
            for ($index = 0; $index -lt $records.Count; $index++) {
                if (Test-TitleEquals -Left $records[$index].Title -Right $normalizedTitle) {
                    $targetIndex = $index
                    break
                }
            }
            if ($targetIndex -lt 0) {
                Stop-RunbookOperation -Code 'TitleNotFound' -Message '未找到指定标题。'
            }
            $sectionEnd = if ($targetIndex + 1 -lt $records.Count) { $records[$targetIndex + 1].Start } else { $content.Length }
            $section = $content.Substring($records[$targetIndex].Start, $sectionEnd - $records[$targetIndex].Start).Trim()
            Write-JsonResult -Data ([ordered]@{
                    action = $Action
                    title = $records[$targetIndex].Title
                    section = $section
                    libraryHash = Get-LibraryHash -Path $resolvedLibraryPath
                })
        }

        'ValidateEntry' {
            if ([string]::IsNullOrWhiteSpace($EntryPath)) {
                Stop-RunbookOperation -Code 'MissingEntryPath' -Message 'ValidateEntry 需要候选条目文件。'
            }
            $entry = Test-AndGetEntry -Path $EntryPath
            Write-JsonResult -Data ([ordered]@{
                    action = $Action
                    valid = $true
                    title = $entry.Title
                })
        }

        'CheckConflicts' {
            if ([string]::IsNullOrWhiteSpace($EntryPath)) {
                Stop-RunbookOperation -Code 'MissingEntryPath' -Message 'CheckConflicts 需要候选条目文件。'
            }
            $entry = Test-AndGetEntry -Path $EntryPath
            $existingTitles = @(Get-LibraryTitles -Path $resolvedLibraryPath)
            $conflicts = Get-TitleConflicts -ExistingTitles $existingTitles -CandidateTitle $entry.Title
            Write-JsonResult -Data ([ordered]@{
                    action = $Action
                    title = $entry.Title
                    duplicateTitles = $conflicts.DuplicateTitles
                    similarTitles = $conflicts.SimilarTitles
                    decisionRequired = ($conflicts.DuplicateTitles.Count -gt 0 -or $conflicts.SimilarTitles.Count -gt 0)
                    libraryHash = Get-LibraryHash -Path $resolvedLibraryPath
                })
        }

        'AppendSection' {
            if ([string]::IsNullOrWhiteSpace($EntryPath)) {
                Stop-RunbookOperation -Code 'MissingEntryPath' -Message 'AppendSection 需要候选条目文件。'
            }
            Invoke-WithLibraryLock -Path $resolvedLibraryPath -Operation {
                Assert-ExpectedLibraryHash -Path $resolvedLibraryPath -ExpectedHash $ExpectedLibraryHash
                $entry = Test-AndGetEntry -Path $EntryPath
                $existingTitles = @(Get-LibraryTitles -Path $resolvedLibraryPath)
                $conflicts = Get-TitleConflicts -ExistingTitles $existingTitles -CandidateTitle $entry.Title
                if ($conflicts.DuplicateTitles.Count -gt 0) {
                    Stop-RunbookOperation -Code 'DuplicateTitle' -Message '已存在完全同名的标题；请询问用户是否更新该条目。' -Details ([ordered]@{
                            duplicateTitles = $conflicts.DuplicateTitles
                        })
                }
                if ($conflicts.SimilarTitles.Count -gt 0 -and -not $AllowSimilarTitle) {
                    Stop-RunbookOperation -Code 'SimilarTitleDecisionRequired' -Message '发现相似标题，请询问用户要分别保留还是合并为一个。' -Details ([ordered]@{
                            similarTitles = $conflicts.SimilarTitles
                        })
                }

                $existingContent = if ([System.IO.File]::Exists($resolvedLibraryPath)) {
                    Read-Utf8Text -Path $resolvedLibraryPath
                }
                else {
                    ''
                }
                if ([string]::IsNullOrWhiteSpace($existingContent)) {
                    $newContent = '# 常用问题解决方案' + $script:NewLine + $script:NewLine + $entry.Text + $script:NewLine
                }
                else {
                    $newContent = $existingContent.TrimEnd([char[]]"`r`n") + $script:NewLine + $script:NewLine + $entry.Text + $script:NewLine
                }
                $backupPath = Save-TextAtomically -Path $resolvedLibraryPath -Content $newContent
                Write-JsonResult -Data ([ordered]@{
                        action = $Action
                        title = $entry.Title
                        initialized = [string]::IsNullOrWhiteSpace($existingContent)
                        backupPath = $backupPath
                        libraryHash = Get-LibraryHash -Path $resolvedLibraryPath
                    })
            }
        }

        'UpdateSection' {
            Invoke-UpdateLibrarySection `
                -ActionName $Action `
                -Path $resolvedLibraryPath `
                -SourceTitle $Title `
                -CandidatePath $EntryPath `
                -ExpectedHash $ExpectedLibraryHash `
                -IsConfirmed ([bool]$ConfirmUpdate) `
                -AllowSimilar ([bool]$AllowSimilarTitle)
        }

        'ReplaceSection' {
            Invoke-UpdateLibrarySection `
                -ActionName $Action `
                -Path $resolvedLibraryPath `
                -SourceTitle $Title `
                -CandidatePath $EntryPath `
                -ExpectedHash $ExpectedLibraryHash `
                -IsConfirmed ([bool]($ConfirmReplace -or $ConfirmUpdate)) `
                -AllowSimilar ([bool]$AllowSimilarTitle)
        }
    }
}
catch {
    $errorCode = 'UnexpectedError'
    if ($null -ne $_.Exception.Data['ErrorCode']) {
        $errorCode = [string]$_.Exception.Data['ErrorCode']
    }
    $errorResult = [ordered]@{
        ok = $false
        action = $Action
        errorCode = $errorCode
        message = $_.Exception.Message
    }
    if ($null -ne $_.Exception.Data['Details']) {
        $errorResult['details'] = $_.Exception.Data['Details']
    }
    Write-Output ($errorResult | ConvertTo-Json -Depth 8 -Compress)
    exit 1
}
