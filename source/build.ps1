param(
    [string]$Zig = 'zig',
    [string]$Repak = 'repak',
    [string]$GameExe = 'C:\Program Files (x86)\Steam\steamapps\common\ASTRONEER\Astro\Binaries\Win64\Astro-Win64-Shipping.exe',
    [string]$OutputDirectory,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$metadataPath = Join-Path $root 'metadata.json'
$metadataBytes = [IO.File]::ReadAllBytes($metadataPath)
if ($metadataBytes.Length -ge 3 -and $metadataBytes[0] -eq 239 -and $metadataBytes[1] -eq 187 -and $metadataBytes[2] -eq 191) {
    throw 'metadata.json must not have a UTF-8 BOM.'
}
$metadata = $utf8.GetString($metadataBytes) | ConvertFrom-Json
if ($metadata.schema_version -ne 2 -or $metadata.enable_ue4ss -ne $true) { throw 'Expected metadata v2 with enable_ue4ss=true.' }
foreach ($key in @('name','mod_id','author','description','version','game_build','sync','homepage')) {
    if ($metadata.$key -isnot [string] -or [string]::IsNullOrWhiteSpace($metadata.$key)) { throw "Missing or invalid metadata: $key" }
}
if ($metadata.mod_id -cne 'NoclipCollisionToggle') { throw 'Keep the existing NoclipCollisionToggle ID.' }
if ($metadata.mod_id -cnotmatch '^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)?$') { throw 'Invalid mod ID.' }
if ($metadata.version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must have three numeric components.' }
if ($metadata.author -cne 'yuexr') { throw 'Unexpected author.' }
if ($metadata.sync -notin @('none','client','server','serverclient')) { throw 'Invalid sync value.' }
if ($metadata.homepage -cne 'https://yuexr.github.io/astro/mods/mod.html?id=noclip') { throw 'Unexpected homepage.' }
if ($metadata.download.type -cne 'index_file' -or $metadata.download.url -cne 'https://yuexr.github.io/astro/mods/index.json') { throw 'Unexpected update index.' }
$version = $metadata.version
$modId = $metadata.mod_id
$mainPath = Join-Path $root "$modId/Scripts/main.lua"
$main = [IO.File]::ReadAllText($mainPath)
if ($main -notmatch ("local VERSION = '" + [regex]::Escape($version) + "'")) { throw 'Lua and metadata versions differ.' }

# Check the executable this native helper was built for.
$native = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'native.c'))
$game = [IO.File]::ReadAllBytes($GameExe)
$nt = [BitConverter]::ToInt32($game, 0x3c)
if ([BitConverter]::ToUInt32($game, $nt) -ne 0x4550) { throw 'Invalid game PE header.' }
$timestamp = [Convert]::ToUInt32([regex]::Match($native, 'TimeDateStamp!=0x([A-Fa-f0-9]+)').Groups[1].Value, 16)
$imageSize = [Convert]::ToUInt32([regex]::Match($native, 'SizeOfImage!=0x([A-Fa-f0-9]+)').Groups[1].Value, 16)
if ([BitConverter]::ToUInt32($game, $nt+8) -ne $timestamp -or [BitConverter]::ToUInt32($game, $nt+80) -ne $imageSize) {
    throw 'Installed game does not match the native helper. Do not relabel its target build.'
}
$buildFile = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $GameExe)))) 'build.version'
$buildVersion = ([IO.File]::ReadAllText($buildFile) -split '\s+')[0]
if ($metadata.game_build -cne $buildVersion) { throw 'game_build differs from the verified game build.' }
foreach ($match in [regex]::Matches($native, 'memcmp\(game\+0x([a-fA-F0-9]+),([a-z_]+),sizeof\(')) {
    $rva = [Convert]::ToInt32($match.Groups[1].Value, 16)
    $signatureName = $match.Groups[2].Value
    $body = [regex]::Match($native, ('\b' + $signatureName + '\[\] = \{(.*?)\};'), 'Singleline').Groups[1].Value
    $expected = @([regex]::Matches($body, '0x([a-fA-F0-9]+)') | ForEach-Object { [Convert]::ToByte($_.Groups[1].Value, 16) })
    if (!$expected.Count) { throw "Missing signature: $signatureName" }
    # Convert the RVA to a file offset using the PE section table.
    $sections = [BitConverter]::ToUInt16($game, $nt+6)
    $sectionTable = $nt+24+[BitConverter]::ToUInt16($game, $nt+20)
    $fileOffset = -1
    for ($i=0; $i -lt $sections; $i++) {
        $section = $sectionTable+$i*40
        $start = [BitConverter]::ToUInt32($game, $section+12)
        $size = [BitConverter]::ToUInt32($game, $section+16)
        if ($rva -ge $start -and $rva+$expected.Count -le $start+$size) {
            $fileOffset = $rva-$start+[BitConverter]::ToUInt32($game, $section+20)
            break
        }
    }
    if ($fileOffset -lt 0) { throw "Signature outside PE sections: $signatureName" }
    for ($i=0; $i -lt $expected.Count; $i++) {
        if ($game[$fileOffset+$i] -ne $expected[$i]) { throw "Game signature mismatch: $signatureName" }
    }
}
$game = $null

if (!$OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$pakName = "000-$modId-${version}_P.pak"
$pak = Join-Path $OutputDirectory $pakName
$zip = Join-Path $OutputDirectory "Noclip-Collision-Toggle-$version.zip"
if (!$Force -and ((Test-Path -LiteralPath $pak) -or (Test-Path -LiteralPath $zip))) { throw 'Output exists. Choose another output folder or pass -Force.' }
$build = Join-Path $root ('build/amlc-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $build 'stage'
$runtime = Join-Path $stage 'UE4SS'
$scripts = Join-Path $runtime 'Scripts'
$verify = Join-Path $build 'extracted'
$libs = Join-Path $root 'libs/minhook'
New-Item -ItemType Directory -Path $scripts,$OutputDirectory -Force | Out-Null
Copy-Item -LiteralPath $metadataPath -Destination $stage
$sources = @{
    'UE4SS/Scripts/main.lua' = $mainPath
    'UE4SS/Scripts/camera.lua' = (Join-Path $root "$modId/Scripts/camera.lua")
    'UE4SS/LICENSE' = (Join-Path $root 'LICENSE')
    'UE4SS/MinHook-LICENSE.txt' = (Join-Path $root "$modId/MinHook-LICENSE.txt")
}
foreach ($entry in $sources.GetEnumerator()) { Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $stage $entry.Key) }
$dll = Join-Path $scripts 'NoclipCollisionToggleNative.dll'
$compilerArgs = @(
    'cc','-target','x86_64-windows-gnu','-O2','-Wall','-Wextra','-Werror',
    '-I',(Join-Path $libs 'include'),'-shared',(Join-Path $PSScriptRoot 'native.c'),
    (Join-Path $libs 'src/buffer.c'),(Join-Path $libs 'src/hook.c'),
    (Join-Path $libs 'src/trampoline.c'),(Join-Path $libs 'src/hde/hde64.c'),
    '-o',$dll,'-lkernel32'
)
$oldLocal = $env:ZIG_LOCAL_CACHE_DIR
$oldGlobal = $env:ZIG_GLOBAL_CACHE_DIR
try {
    $env:ZIG_LOCAL_CACHE_DIR = Join-Path $root 'build/zig-local'
    $env:ZIG_GLOBAL_CACHE_DIR = Join-Path $root 'build/zig-global'
    & $Zig @compilerArgs
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
} finally {
    $env:ZIG_LOCAL_CACHE_DIR = $oldLocal
    $env:ZIG_GLOBAL_CACHE_DIR = $oldGlobal
}
# Only these files belong in the PAK.
$expectedPaths = @('metadata.json') + @($sources.Keys) + @('UE4SS/Scripts/NoclipCollisionToggleNative.dll')
foreach ($file in Get-ChildItem -LiteralPath $scripts -File) {
    if ($file.Name -ne 'main.lua' -and $file.Name -ne 'camera.lua' -and $file.Name -ne 'NoclipCollisionToggleNative.dll') {
        Move-Item -LiteralPath $file.FullName -Destination $build
    }
}
$actualPaths = @(Get-ChildItem -LiteralPath $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length+1).Replace('\','/') })
if (@(Compare-Object ($expectedPaths | Sort-Object) ($actualPaths | Sort-Object)).Count) { throw 'Unexpected staged files.' }
& $Repak pack $stage $pak --version V8B --mount-point '../../../'
if ($LASTEXITCODE -ne 0) { throw 'PAK build failed.' }
$listing = @(& $Repak list $pak)
if ($LASTEXITCODE -ne 0) { throw 'PAK listing failed.' }
if (@(Compare-Object ($expectedPaths | Sort-Object) ($listing | Sort-Object)).Count) { throw 'PAK paths differ from intended files.' }
& $Repak unpack $pak -o $verify -q
if ($LASTEXITCODE -ne 0) { throw 'PAK extraction failed.' }
foreach ($path in $expectedPaths) {
    if ((Get-FileHash -LiteralPath (Join-Path $stage $path)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $verify $path)).Hash) { throw "Extracted file mismatch: $path" }
}
foreach ($entry in $sources.GetEnumerator()) {
    if ((Get-FileHash -LiteralPath $entry.Value).Hash -ne (Get-FileHash -LiteralPath (Join-Path $verify $entry.Key)).Hash) { throw "Source mismatch: $($entry.Key)" }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $pak, $pakName) } finally { $archive.Dispose() }
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -cne $pakName) { throw 'ZIP must contain exactly one root-level PAK.' }
    $stream = $archive.Entries[0].Open()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $zipHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','') } finally { $stream.Dispose(); $sha.Dispose() }
    if ($zipHash -ne (Get-FileHash -LiteralPath $pak).Hash) { throw 'ZIP PAK hash differs.' }
} finally { $archive.Dispose() }
$hashes = foreach ($path in $expectedPaths) { "$((Get-FileHash -LiteralPath (Join-Path $verify $path)).Hash)  $path" }
$report = @(
    "PAK: $pakName", "Game build verified: $buildVersion", "Version: $version", "mod_id: $modId",
    "sync: $($metadata.sync)",
    'Metadata, PAK paths, extracted bytes, source hashes, and ZIP contents: PASS',
    "Expected AMLC extraction: ue4ss/Mods/$modId/Scripts/main.lua",
    'No enabled.txt; AMLC manages activation.',
    'This script checks packaging only; it does not install or run the mod.', '', $hashes
)
[IO.File]::WriteAllLines((Join-Path $build 'package-checks.txt'), [string[]]$report, $utf8)
Write-Output "Built and verified: $zip"
Write-Output 'Package checks passed.'
