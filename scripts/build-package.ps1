[CmdletBinding()]
param(
    [string]$Version = '2.3.0'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$distRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
$zipName = "cms-paired-post-skill-v$Version.zip"
$zipPath = [System.IO.Path]::GetFullPath((Join-Path $distRoot $zipName))

if (-not $zipPath.StartsWith($distRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe output path: $zipPath"
}

$allowlist = @(
    'README.md',
    '.gitignore',
    '.gitattributes',
    'codex\cms-paired-post\SKILL.md',
    'codex\cms-paired-post\references\media-router.md',
    'codex\cms-paired-post\references\voice-card.md',
    'codex\cms-paired-post\scripts\check_caption.py',
    'grok\cms-paired-post\SKILL.md',
    'tests\evaluation.md',
    'tests\fixtures\why-isnt-everyone-source.txt',
    'scripts\build-package.ps1',
    'scripts\validate-package.ps1'
)

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cms-paired-post-package-" + [System.Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $temporaryRoot 'cms-paired-post-skill'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-StreamSha256 {
    param([System.IO.Stream]$Stream)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
    }
}

try {
    New-Item -ItemType Directory -Force -Path $packageRoot, $distRoot | Out-Null

    foreach ($relativePath in $allowlist) {
        $source = Join-Path $repoRoot $relativePath
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Required package input is missing: $relativePath"
        }
        $destination = Join-Path $packageRoot $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $forbiddenFiles = Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Where-Object {
        $_.FullName -match '(?i)(^|[\\/])(\.env(?:\.|$)|research-import|x-poster|samples?|generated|previews?|artifacts?)([\\/]|$)' -or
        $_.Extension -match '(?i)^\.(png|jpe?g|gif|webp|mp4|mov|env|key|pem|p12|pfx)$'
    }
    if ($forbiddenFiles) {
        throw "Forbidden package input: $($forbiddenFiles.FullName -join ', ')"
    }

    $manifestLines = Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($packageRoot.Length + 1).Replace('\', '/')
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
            "$hash  $relative"
        }
    [System.IO.File]::WriteAllText((Join-Path $packageRoot 'MANIFEST.sha256'), (($manifestLines -join "`n") + "`n"), $utf8NoBom)

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $zipStream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $packageRoot -Recurse -File | Sort-Object FullName) {
                $relative = $file.FullName.Substring($packageRoot.Length + 1).Replace('\', '/')
                $entryName = "cms-paired-post-skill/$relative"
                $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $file.LastWriteTime
                $sourceStream = [System.IO.File]::OpenRead($file.FullName)
                $entryStream = $entry.Open()
                try {
                    $sourceStream.CopyTo($entryStream)
                }
                finally {
                    $entryStream.Dispose()
                    $sourceStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $zipStream.Dispose()
    }

    $verificationArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($verificationArchive.Entries | Where-Object { $_.Name })
        if ($entries | Where-Object { $_.FullName.Contains('\') }) {
            throw 'ZIP contains non-portable backslash entry names.'
        }

        $expectedFiles = @($allowlist) + @('MANIFEST.sha256')
        foreach ($relativePath in $expectedFiles) {
            $portableRelative = $relativePath.Replace('\', '/')
            $entryName = "cms-paired-post-skill/$portableRelative"
            $entry = $verificationArchive.GetEntry($entryName)
            if (-not $entry) {
                throw "ZIP is missing expected entry: $entryName"
            }

            $sourcePath = Join-Path $packageRoot $relativePath
            $expectedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
            $entryStream = $entry.Open()
            try {
                $actualHash = Get-StreamSha256 -Stream $entryStream
            }
            finally {
                $entryStream.Dispose()
            }
            if ($actualHash -ne $expectedHash) {
                throw "ZIP entry does not match current source: $entryName"
            }
        }

        if ($entries.Count -ne $expectedFiles.Count) {
            throw "ZIP has $($entries.Count) files; expected exactly $($expectedFiles.Count)."
        }
    }
    finally {
        $verificationArchive.Dispose()
    }

    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText((Join-Path $repoRoot 'SHA256SUMS.txt'), "$zipHash  dist/$zipName`n", $utf8NoBom)

    Write-Output "Built and source-verified: $zipPath"
    Write-Output "SHA-256: $zipHash"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
        $systemTemporary = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($systemTemporary, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTemporary) -like 'cms-paired-post-package-*') {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}
