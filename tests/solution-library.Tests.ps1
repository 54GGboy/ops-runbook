$scriptPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\solution-library.ps1'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function New-TestContext {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ops-runbook-tests-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($root)
    return [pscustomobject]@{
        Root = $root
        Library = Join-Path $root 'library.md'
    }
}

function Remove-TestContext {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = [System.IO.Path]::GetFullPath($Path)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolved).StartsWith('ops-runbook-tests-', [System.StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-TestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ExtraAfterRisk,
        [switch]$FieldsInsideCode,
        [string]$SecretLine
    )

    $fence = -join (([string][char]96) * 3)
    if ($FieldsInsideCode) {
        $metadata = ''
        $currentBody = @"
- 状态：未验证
- 环境：Windows 11、PowerShell 7
- 权限：普通用户
"@
    }
    else {
        $metadata = @"
- 状态：未验证
- 环境：Windows 11、PowerShell 7
- 权限：普通用户
"@
        $currentBody = 'Get-Date'
    }
    $text = @"
## $Title

**问题现象：** 用于验证个人运维方案库行为。

$metadata
### 当前案例

${fence}powershell
$currentBody
$fence

### 通用命令模块

${fence}powershell
# 变量
`$format = 'o'
# 安全检查
Get-Command Get-Date
# 执行
Get-Date -Format `$format
# 验证
Get-Date
# 回滚：只读命令，无需回滚
$SecretLine
$fence

> 仅用于隔离测试。
$ExtraAfterRisk
"@.Trim()
    [System.IO.File]::WriteAllText($Path, $text, $utf8NoBom)
}

function Invoke-Runbook {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & pwsh.exe -NoProfile -File $scriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output -join "`n")
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch {}
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
        Json = $json
    }
}

function Get-ConflictCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Library,
        [Parameter(Mandatory = $true)][string]$Entry
    )

    return Invoke-Runbook -Arguments @(
        '-Action', 'CheckConflicts',
        '-LibraryPath', $Library,
        '-EntryPath', $Entry,
        '-AllowAlternatePath'
    )
}

function Add-TestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Library,
        [Parameter(Mandatory = $true)][string]$Entry,
        [switch]$AllowSimilar
    )

    $check = Get-ConflictCheck -Library $Library -Entry $Entry
    if ($check.ExitCode -ne 0) { return $check }
    $arguments = @(
        '-Action', 'AppendSection',
        '-LibraryPath', $Library,
        '-EntryPath', $Entry,
        '-ExpectedLibraryHash', $check.Json.libraryHash,
        '-AllowAlternatePath'
    )
    if ($AllowSimilar) { $arguments += '-AllowSimilarTitle' }
    return Invoke-Runbook -Arguments $arguments
}

Describe 'ops-runbook solution library' {
    BeforeEach {
        $script:context = New-TestContext
    }

    AfterEach {
        Remove-TestContext -Path $script:context.Root
    }

    It 'accepts the canonical format and rejects misplaced structure' {
        $valid = Join-Path $script:context.Root 'valid.md'
        Write-TestEntry -Path $valid -Title '[Windows][PowerShell] 检查 Swap 状态'
        $validResult = Invoke-Runbook -Arguments @('-Action','ValidateEntry','-LibraryPath',$script:context.Library,'-EntryPath',$valid,'-AllowAlternatePath')
        $validResult.ExitCode | Should Be 0
        $validResult.Json.valid | Should Be $true

        $trailing = Join-Path $script:context.Root 'trailing.md'
        Write-TestEntry -Path $trailing -Title '[Windows][PowerShell] 风险位置测试' -ExtraAfterRisk '不允许的尾部正文'
        $trailingResult = Invoke-Runbook -Arguments @('-Action','ValidateEntry','-LibraryPath',$script:context.Library,'-EntryPath',$trailing,'-AllowAlternatePath')
        $trailingResult.ExitCode | Should Be 1
        $trailingResult.Json.errorCode | Should Be 'InvalidEntryFormat'

        $insideCode = Join-Path $script:context.Root 'inside-code.md'
        Write-TestEntry -Path $insideCode -Title '[Windows][PowerShell] 元数据位置测试' -FieldsInsideCode
        $insideResult = Invoke-Runbook -Arguments @('-Action','ValidateEntry','-LibraryPath',$script:context.Library,'-EntryPath',$insideCode,'-AllowAlternatePath')
        $insideResult.ExitCode | Should Be 1
        $insideResult.Json.errorCode | Should Be 'InvalidEntryFormat'
    }

    It 'requires a user decision for similar titles and can keep both' {
        $first = Join-Path $script:context.Root 'first.md'
        $second = Join-Path $script:context.Root 'second.md'
        Write-TestEntry -Path $first -Title '[Windows][PowerShell] 检查 Swap 状态'
        Write-TestEntry -Path $second -Title '[Windows][PowerShell] 检查 Swap 使用状态'
        (Add-TestEntry -Library $script:context.Library -Entry $first).ExitCode | Should Be 0

        $check = Get-ConflictCheck -Library $script:context.Library -Entry $second
        @($check.Json.similarTitles).Count | Should Be 1
        $blocked = Invoke-Runbook -Arguments @('-Action','AppendSection','-LibraryPath',$script:context.Library,'-EntryPath',$second,'-ExpectedLibraryHash',$check.Json.libraryHash,'-AllowAlternatePath')
        $blocked.Json.errorCode | Should Be 'SimilarTitleDecisionRequired'

        $allowed = Add-TestEntry -Library $script:context.Library -Entry $second -AllowSimilar
        $allowed.ExitCode | Should Be 0
        (Test-Path -LiteralPath $allowed.Json.backupPath) | Should Be $true
    }

    It 'updates an existing entry and allows its title to change' {
        $first = Join-Path $script:context.Root 'first.md'
        $updated = Join-Path $script:context.Root 'updated.md'
        $oldTitle = '[Windows][PowerShell] 检查 Swap 状态'
        $newTitle = '[Windows][PowerShell] 查看 Swap 使用情况'
        Write-TestEntry -Path $first -Title $oldTitle
        Write-TestEntry -Path $updated -Title $newTitle
        (Add-TestEntry -Library $script:context.Library -Entry $first).ExitCode | Should Be 0

        $read = Invoke-Runbook -Arguments @('-Action','ReadSection','-LibraryPath',$script:context.Library,'-Title',$oldTitle,'-AllowAlternatePath')
        $result = Invoke-Runbook -Arguments @('-Action','UpdateSection','-LibraryPath',$script:context.Library,'-Title',$oldTitle,'-EntryPath',$updated,'-ExpectedLibraryHash',$read.Json.libraryHash,'-ConfirmUpdate','-AllowAlternatePath')
        $result.ExitCode | Should Be 0
        $result.Json.titleChanged | Should Be $true
        (Test-Path -LiteralPath $result.Json.backupPath) | Should Be $true

        $list = Invoke-Runbook -Arguments @('-Action','ListTitles','-LibraryPath',$script:context.Library,'-AllowAlternatePath')
        $list.Json.count | Should Be 1
        $list.Json.titles[0] | Should Be $newTitle
    }

    It 'rejects stale library hashes and exact duplicate titles' {
        $first = Join-Path $script:context.Root 'first.md'
        $second = Join-Path $script:context.Root 'second.md'
        Write-TestEntry -Path $first -Title '[Windows][PowerShell] 检查 Swap 状态'
        Write-TestEntry -Path $second -Title '[Linux][Bash] 检查 Swap 状态'
        $firstCheck = Get-ConflictCheck -Library $script:context.Library -Entry $first
        (Add-TestEntry -Library $script:context.Library -Entry $first).ExitCode | Should Be 0

        $stale = Invoke-Runbook -Arguments @('-Action','AppendSection','-LibraryPath',$script:context.Library,'-EntryPath',$second,'-ExpectedLibraryHash',$firstCheck.Json.libraryHash,'-AllowAlternatePath')
        $stale.Json.errorCode | Should Be 'LibraryChanged'

        $duplicateCheck = Get-ConflictCheck -Library $script:context.Library -Entry $first
        @($duplicateCheck.Json.duplicateTitles).Count | Should Be 1
    }

    It 'rejects common credential material' {
        $entry = Join-Path $script:context.Root 'secret.md'
        Write-TestEntry -Path $entry -Title '[Windows][PowerShell] Token 测试' -SecretLine 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456'
        $result = Invoke-Runbook -Arguments @('-Action','ValidateEntry','-LibraryPath',$script:context.Library,'-EntryPath',$entry,'-AllowAlternatePath')
        $result.ExitCode | Should Be 1
        $result.Json.errorCode | Should Be 'SecretDetected'
    }
}
