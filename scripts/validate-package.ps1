[CmdletBinding()]
param(
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$skillRoot = Join-Path $repoRoot 'codex\cms-paired-post'
$checker = Join-Path $skillRoot 'scripts\check_caption.py'

$required = @(
    'README.md',
    '.gitignore',
    '.gitattributes',
    'codex\cms-paired-post\SKILL.md',
    'codex\cms-paired-post\references\voice-card.md',
    'codex\cms-paired-post\references\media-router.md',
    'codex\cms-paired-post\scripts\check_caption.py',
    'grok\cms-paired-post\SKILL.md',
    'tests\evaluation.md',
    'tests\fixtures\why-isnt-everyone-source.txt',
    'scripts\build-package.ps1',
    'scripts\validate-package.ps1'
)

foreach ($relativePath in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath))) {
        throw "Missing required file: $relativePath"
    }
}

$mediaFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $_.FullName -notlike "$(Join-Path $repoRoot '.git')*" -and
    $_.Extension -match '(?i)^\.(png|jpe?g|gif|webp|mp4|mov)$'
}
if ($mediaFiles) {
    throw "Creator or generated media must not ship in the portable repository: $($mediaFiles.FullName -join ', ')"
}

$portableText = @(
    (Join-Path $repoRoot 'README.md'),
    (Join-Path $repoRoot 'codex'),
    (Join-Path $repoRoot 'grok'),
    (Join-Path $repoRoot 'tests')
)
$textFiles = foreach ($path in $portableText) {
    if ((Get-Item -LiteralPath $path).PSIsContainer) {
        Get-ChildItem -LiteralPath $path -Recurse -File
    } else {
        Get-Item -LiteralPath $path
    }
}

$forbiddenContent = @(
    '(?i)[A-Z]:\\Users\\',
    '(?i)\bAdamdesgns\b',
    "(?i)\bAdam(?:'s|’s)?\b",
    '(?i)private CMS research',
    '(?i)research-import',
    '(?i)x-poster-adam-api'
)
foreach ($file in $textFiles) {
    $content = Get-Content -Raw -LiteralPath $file.FullName
    foreach ($pattern in $forbiddenContent) {
        if ($content -match $pattern) {
            throw "Non-portable content in $($file.FullName): $pattern"
        }
    }
}

$grokText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'grok\cms-paired-post\SKILL.md')
$codexText = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'codex\cms-paired-post\SKILL.md')
foreach ($requiredPhrase in @('MEDIA:', 'FOLLOW', 'Comment YES', '280', 'Never post')) {
    if (($grokText -notmatch [regex]::Escape($requiredPhrase)) -and ($codexText -notmatch [regex]::Escape($requiredPhrase))) {
        throw "The skills are missing a required control phrase: $requiredPhrase"
    }
}

$pythonArgs = @()
if ($PythonPath) {
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        throw "Python executable does not exist: $PythonPath"
    }
    $pythonExecutable = (Resolve-Path -LiteralPath $PythonPath).Path
} else {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        $pythonCommand = Get-Command py -ErrorAction SilentlyContinue
        $pythonArgs = @('-3')
    }
    if ($pythonCommand) {
        $pythonExecutable = $pythonCommand.Source
    }
}
if (-not $pythonExecutable) {
    throw 'Python 3 is required to validate the portable caption checker. Pass -PythonPath when it is not on PATH.'
}

$passOutput = & $pythonExecutable @pythonArgs $checker --caption 'This chart has become emotionally expensive. $GPRO' 2>&1
if ($LASTEXITCODE -ne 0 -or ($passOutput -join "`n") -notmatch 'overlap check skipped') {
    throw "Expected clean caption to pass with an explicit skipped-overlap notice: $($passOutput -join ' ')"
}

$savedErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $failOutput = & $pythonExecutable @pythonArgs $checker --caption 'Comment YES and I will make you rich.' 2>&1
    $failExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedErrorPreference
}
if ($failExitCode -eq 0 -or ($failOutput -join "`n") -notmatch 'Comment YES') {
    throw "Expected forbidden CTA test to fail: $($failOutput -join ' ')"
}

$temporaryCorpus = Join-Path ([System.IO.Path]::GetTempPath()) ("cms-paired-post-corpus-" + [System.Guid]::NewGuid().ToString('N') + '.jsonl')
try {
    [System.IO.File]::WriteAllText($temporaryCorpus, "{`"item`":1,`"exact_text`":`"one two three four five six seven`"}`n", [System.Text.UTF8Encoding]::new($false))
    try {
        $ErrorActionPreference = 'Continue'
        $overlapOutput = & $pythonExecutable @pythonArgs $checker --caption 'Zero one two three four five six.' --corpus $temporaryCorpus 2>&1
        $overlapExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    if ($overlapExitCode -eq 0 -or ($overlapOutput -join "`n") -notmatch 'Six-word source overlap') {
        throw "Expected overlap test to fail: $($overlapOutput -join ' ')"
    }
}
finally {
    $ErrorActionPreference = $savedErrorPreference
    if (Test-Path -LiteralPath $temporaryCorpus) {
        Remove-Item -LiteralPath $temporaryCorpus -Force
    }
}

Write-Output 'PASS: portable package files, boundaries, and caption checker validated.'
