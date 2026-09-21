[CmdletBinding()]
param(
    [switch]$SkipRelease,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$RepoRoot = Split-Path $PSScriptRoot -Parent
$CacheDir = Join-Path $RepoRoot 'cache'
$DistDir = Join-Path $RepoRoot 'dist'
$OutDir = Join-Path $RepoRoot 'out'
$AppDir = Join-Path $DistDir 'Lampa-Desktop'
$WrapperDir = Join-Path $RepoRoot 'app'

$LampaOwner = 'yumata'
$LampaRepoName = 'lampa'
$ResourceHackerUrl = 'https://www.angusj.com/resourcehacker/resource_hacker.zip'

$GitHubRepo = $env:GITHUB_REPOSITORY
$GitHubEvent = $env:GITHUB_EVENT_NAME
$ForceBuild = $Force -or ($env:FORCE_BUILD -eq 'true')

if (-not $GitHubRepo -or -not $env:GITHUB_ACTIONS) {
    $SkipRelease = $true
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-GitHubHeaders {
    param([string]$Accept = 'application/vnd.github+json')

    $headers = @{
        Accept                     = $Accept
        'User-Agent'               = 'Lampa-Desktop-CI'
        'X-GitHub-Api-Version'     = '2022-11-28'
    }

    $token = $env:GITHUB_TOKEN
    if (-not $token) {
        $token = $env:GH_TOKEN
    }
    if ($token) {
        $headers.Authorization = "Bearer $token"
    }

    return $headers
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [string]$Method = 'GET',
        [string]$Accept = 'application/vnd.github+json',
        [string]$OutFile
    )

    if ($Uri -notmatch '^https?://') {
        $Uri = "https://api.github.com$Uri"
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = Get-GitHubHeaders -Accept $Accept
    }

    if ($OutFile) {
        $params.OutFile = $OutFile
    }

    return Invoke-RestMethod @params
}

function Save-WebFile {
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $directory = Split-Path -Parent $LiteralPath
    if ($directory) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $LiteralPath) {
        Write-Host "Using cache: $LiteralPath"
        return
    }

    Write-Host "Downloading $Url"
    $curlArgs = @('-L', '--fail', '-o', $LiteralPath, $Url)
    if ($env:GITHUB_ACTIONS) {
        $curlArgs = @('-L', '--fail', '-sS', '-o', $LiteralPath, $Url)
    }
    else {
        $curlArgs = @('-L', '--fail', '--progress-bar', '-o', $LiteralPath, $Url)
    }

    & curl.exe @curlArgs
    if ($LASTEXITCODE) {
        throw "Download failed ($LASTEXITCODE): $Url"
    }
}

function Expand-ArchiveSmart {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [string]$DestinationPath = $PSScriptRoot,
        [string]$Folder
    )

    $sevenZip = @(
        (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        "$env:ProgramFiles\7-Zip\7z.exe"
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    $extractPath = if ($Folder) {
        Join-Path $env:TEMP ([guid]::NewGuid())
    }
    else {
        $DestinationPath
    }

    try {
        New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

        if ($sevenZip) {
            & $sevenZip x $LiteralPath "-o$extractPath" -y | Out-Null
            if ($LASTEXITCODE) {
                throw "7-Zip extraction failed: $LASTEXITCODE"
            }
        }
        elseif (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            & tar.exe -xf $LiteralPath -C $extractPath
            if ($LASTEXITCODE) {
                throw "tar extraction failed: $LASTEXITCODE"
            }
        }
        else {
            Expand-Archive -LiteralPath $LiteralPath -DestinationPath $extractPath -Force
        }

        if ($Folder) {
            $source = Join-Path $extractPath $Folder
            if (-not (Test-Path -LiteralPath $source -PathType Container)) {
                $found = Get-ChildItem -LiteralPath $extractPath -Directory | Select-Object -First 1
                if ($found) {
                    $source = $found.FullName
                }
                else {
                    throw "Folder '$Folder' not found in archive."
                }
            }

            Get-ChildItem -LiteralPath $source -Force |
                Copy-Item -Destination $DestinationPath -Recurse -Force
        }
    }
    finally {
        if ($Folder -and (Test-Path $extractPath)) {
            Remove-Item $extractPath -Recurse -Force
        }
    }
}

function Compress-FolderZip {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$ZipPath
    )

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $parent = Split-Path -Parent $SourceDir
    $name = Split-Path -Leaf $SourceDir
    $sevenZip = @(
        (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        "$env:ProgramFiles\7-Zip\7z.exe"
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    Push-Location $parent
    try {
        if ($sevenZip) {
            & $sevenZip a -tzip -mx=7 $ZipPath $name | Out-Null
            if ($LASTEXITCODE) {
                throw "7-Zip compression failed: $LASTEXITCODE"
            }
        }
        else {
            & tar.exe -a -c -f $ZipPath $name
            if ($LASTEXITCODE) {
                throw "tar compression failed: $LASTEXITCODE"
            }
        }
    }
    finally {
        Pop-Location
    }
}

function ConvertTo-MarkdownSafe {
    param([string]$Text)

    if (-not $Text) {
        return ''
    }

    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

function Get-ShortSha {
    param([string]$Sha)

    if (-not $Sha) {
        return ''
    }
    if ($Sha.Length -lt 7) {
        return $Sha
    }
    return $Sha.Substring(0, 7)
}

function Get-WrapperHeadSha {
    if ($env:GITHUB_SHA) {
        return $env:GITHUB_SHA
    }

    Push-Location $RepoRoot
    try {
        $sha = git rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) {
            return $sha.Trim()
        }
    }
    finally {
        Pop-Location
    }

    return $null
}

function Get-PreviousBuildInfo {
    if (-not $GitHubRepo) {
        return $null
    }

    try {
        $release = Invoke-GitHubApi "/repos/$GitHubRepo/releases/latest"
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 404) {
            return $null
        }
        throw
    }

    $asset = @($release.assets) | Where-Object { $_.name -eq 'build-info.json' } | Select-Object -First 1
    if (-not $asset) {
        return $null
    }

    $tempFile = Join-Path $env:TEMP "lampa-build-info-$([guid]::NewGuid()).json"
    try {
        Invoke-WebRequest -Uri $asset.url -Headers (Get-GitHubHeaders -Accept 'application/octet-stream') -OutFile $tempFile
        return Get-Content -LiteralPath $tempFile -Raw -Encoding utf8 | ConvertFrom-Json
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function Get-RemoteCommits {
    param(
        [Parameter(Mandatory)]
        [string]$Owner,
        [Parameter(Mandatory)]
        [string]$Repo,
        [string]$FromSha,
        [Parameter(Mandatory)]
        [string]$ToSha
    )

    if ($FromSha -eq $ToSha) {
        return @()
    }

    if (-not $FromSha) {
        return @()
    }

    $items = [System.Collections.Generic.List[object]]::new()

    try {
        $compare = Invoke-GitHubApi "/repos/$Owner/$Repo/compare/${FromSha}...${ToSha}"
    }
    catch {
        Write-Warning ("Could not compare {0}/{1} {2}...{3}: {4}" -f $Owner, $Repo, $FromSha, $ToSha, $_.Exception.Message)
        return @()
    }

    foreach ($commit in @($compare.commits)) {
        $message = ($commit.commit.message -split "(`r`n|`n)")[0].Trim()
        $items.Add([pscustomobject]@{
            Sha     = [string]$commit.sha
            Url     = [string]$commit.html_url
            Message = $message
        }) | Out-Null
    }

    if ($compare.total_commits -gt $items.Count) {
        Write-Host "GitHub compare truncated: $($items.Count) of $($compare.total_commits) commits"
    }

    return $items
}

function Get-WrapperCommits {
    param(
        [string]$FromSha,
        [string]$ToSha
    )

    if (-not $ToSha -or $FromSha -eq $ToSha) {
        return @()
    }

    Push-Location $RepoRoot
    try {
        if (-not $FromSha) {
            return @()
        }

        $gitArgs = @('log', '--reverse', '--pretty=format:%H%x09%s', "$FromSha..$ToSha")
        $log = git @gitArgs 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $log) {
            return @()
        }

        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($line in @($log)) {
            if (-not $line) {
                continue
            }
            $parts = $line -split "`t", 2
            $sha = $parts[0]
            $message = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $url = if ($GitHubRepo) {
                "https://github.com/${GitHubRepo}/commit/$sha"
            }
            else {
                ''
            }
            $items.Add([pscustomobject]@{
                Sha     = $sha
                Url     = $url
                Message = $message
            }) | Out-Null
        }
        return $items
    }
    finally {
        Pop-Location
    }
}

function Get-NwjsRange {
    param(
        $VersionsJson,
        [string]$OldVersion,
        [string]$NewVersion
    )

    if (-not $OldVersion -or $OldVersion -eq $NewVersion) {
        return @()
    }

    $entries = @()
    $collect = $false
    foreach ($item in @($VersionsJson.versions)) {
        $version = $item.version.TrimStart('v')
        if ($version -eq $NewVersion) {
            $collect = $true
        }
        if ($collect) {
            if ($version -eq $OldVersion) {
                break
            }
            $entries += $item
            if ($entries.Count -ge 15) {
                break
            }
        }
    }

    return $entries
}

function Add-CommitBullet {
    param($Commit)

    $short = Get-ShortSha ([string]$Commit.Sha)
    $url = [string]$Commit.Url
    $message = ConvertTo-MarkdownSafe ([string]$Commit.Message)
    if (-not $message) {
        $message = '(без сообщения)'
    }

    if ($url -match '^https?://') {
        return ('- [' + $short + '](' + $url + ') — ' + $message)
    }

    return ('- `' + $short + '` — ' + $message)
}

function Add-CommitSection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Title,
        [string]$CompareUrl,
        $Commits,
        [int]$Limit = 50
    )

    $Lines.Add('')
    $Lines.Add("### $Title")

    $list = @($Commits | Where-Object { $_ })
    if ($CompareUrl) {
        $Lines.Add(('Сравнение: {0}' -f $CompareUrl))
        $Lines.Add('')
    }

    if ($list.Count -eq 0) {
        if ($CompareUrl) {
            $Lines.Add('- Список коммитов не получен автоматически, откройте ссылку сравнения.')
        }
        else {
            $Lines.Add('- Изменений по коммитам нет.')
        }
        return
    }

    $start = 0
    if ($list.Count -gt $Limit) {
        $hidden = $list.Count - $Limit
        $start = $hidden
        $Lines.Add(('_Показаны последние {0} из {1} коммитов, ещё {2} см. по ссылке сравнения._' -f $Limit, $list.Count, $hidden))
        $Lines.Add('')
    }

    for ($i = $start; $i -lt $list.Count; $i++) {
        $Lines.Add((Add-CommitBullet -Commit $list[$i]))
    }
}

function New-ReleaseNotes {
    param(
        $Current,
        $Previous,
        [object[]]$LampaCommits,
        [object[]]$WrapperCommits,
        $NwjsEntries,
        [bool]$IsFirstRelease
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lampaShort = Get-ShortSha $Current.lampa.sha
    $wrapperShort = Get-ShortSha $Current.wrapper.sha
    $lampaUrl = "https://github.com/$LampaOwner/$LampaRepoName/commit/$($Current.lampa.sha)"
    $wrapperUrl = if ($GitHubRepo -and $Current.wrapper.sha) {
        "https://github.com/$GitHubRepo/commit/$($Current.wrapper.sha)"
    }
    else {
        ''
    }

    $lampaLabel = if ($Current.lampa.appVersion) { [string]$Current.lampa.appVersion } else { 'yumata/lampa' }
    $lampaHash = if ($Current.lampa.hash) { [string]$Current.lampa.hash } else { '' }
    $ffmpegReleaseUrl = 'https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/tag/{0}' -f $Current.ffmpeg.version

    $lines.Add('Автоматическая сборка **Lampa Desktop** для Windows x64.')
    $lines.Add('')
    $lines.Add('## Состав сборки')
    $lines.Add(('- **NW.js:** {0} (Chromium {1}, Node.js {2})' -f $Current.nwjs.version, $Current.nwjs.chromium, $Current.nwjs.node))
    $lines.Add(('- **FFmpeg prebuilt:** [{0}]({1})' -f $Current.ffmpeg.version, $ffmpegReleaseUrl))
    if ($lampaHash) {
        $lines.Add(('- **Lampa:** {0} ([{1}]({2}), hash `{3}`)' -f $lampaLabel, $lampaShort, $lampaUrl, $lampaHash))
    }
    else {
        $lines.Add(('- **Lampa:** {0} ([{1}]({2}))' -f $lampaLabel, $lampaShort, $lampaUrl))
    }
    if ($wrapperUrl) {
        $lines.Add(('- **Оболочка:** [{0}]({1})' -f $wrapperShort, $wrapperUrl))
    }
    elseif ($wrapperShort) {
        $lines.Add(('- **Оболочка:** `{0}`' -f $wrapperShort))
    }

    $lines.Add('')
    $lines.Add('## Что обновилось')

    if ($IsFirstRelease) {
        $lines.Add('')
        $lines.Add('Первая публикация в Releases. Со следующего релиза здесь будет только разница с предыдущей сборкой: NW.js, FFmpeg, коммиты Lampa и коммиты оболочки.')
        $lines.Add('')
        $lines.Add('---')
        $lines.Add('Распакуйте архив и запустите `Lampa.exe`. Профиль Chromium хранится в папке `user` рядом с программой.')
        return ($lines -join "`n")
    }

    $anyChange = $false

    if ($Current.nwjs.changed) {
        $anyChange = $true
        $lines.Add('')
        $lines.Add('### NW.js')
        $lines.Add(('Обновлён **{0} → {1}**.' -f $Previous.nwjs.version, $Current.nwjs.version))
        $entries = @($NwjsEntries)
        if ($entries.Count -gt 0) {
            $lines.Add('')
            $lines.Add('| Версия | Дата | Chromium | Node.js |')
            $lines.Add('| --- | --- | --- | --- |')
            foreach ($item in $entries) {
                $ver = $item.version.TrimStart('v')
                $lines.Add(('| {0} | {1} | {2} | {3} |' -f $ver, $item.date, $item.components.chromium, $item.components.node))
            }
        }
        $lines.Add('')
        $lines.Add('Заметки NW.js: https://nwjs.io/blog/')
    }

    if ($Current.ffmpeg.changed) {
        $anyChange = $true
        $lines.Add('')
        $lines.Add('### FFmpeg')
        $lines.Add(('Библиотека [nwjs-ffmpeg-prebuilt](https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt) обновлена **{0} → {1}** (ставится в пару к NW.js).' -f $Previous.ffmpeg.version, $Current.ffmpeg.version))
    }

    if ($Current.lampa.changed) {
        $anyChange = $true
        $from = $Previous.lampa.sha
        $compare = 'https://github.com/{0}/{1}/compare/{2}...{3}' -f $LampaOwner, $LampaRepoName, $from, $Current.lampa.sha
        $title = 'Lampa ({0} → {1})' -f (Get-ShortSha $from), $lampaShort
        Add-CommitSection -Lines $lines -Title $title -CompareUrl $compare -Commits $LampaCommits
    }

    if ($Current.wrapper.changed) {
        $anyChange = $true
        $from = $Previous.wrapper.sha
        $compare = if ($from -and $GitHubRepo) {
            'https://github.com/{0}/compare/{1}...{2}' -f $GitHubRepo, $from, $Current.wrapper.sha
        }
        else {
            ''
        }
        $title = 'Оболочка ({0} → {1})' -f (Get-ShortSha $from), $wrapperShort
        Add-CommitSection -Lines $lines -Title $title -CompareUrl $compare -Commits $WrapperCommits
    }

    if (-not $anyChange) {
        $lines.Add('')
        $lines.Add('Lampa, NW.js и FFmpeg не изменились. Сборка опубликована из‑за коммита в этом репозитории или ручного запуска.')
    }
    else {
        $unchanged = @()
        if (-not $Current.nwjs.changed) {
            $unchanged += ('NW.js **{0}**' -f $Current.nwjs.version)
        }
        if (-not $Current.ffmpeg.changed) {
            $unchanged += ('FFmpeg **{0}**' -f $Current.ffmpeg.version)
        }
        if (-not $Current.lampa.changed) {
            $unchanged += ('Lampa [{0}]({1})' -f $lampaShort, $lampaUrl)
        }
        if (-not $Current.wrapper.changed -and $wrapperShort) {
            if ($wrapperUrl) {
                $unchanged += ('оболочка [{0}]({1})' -f $wrapperShort, $wrapperUrl)
            }
            else {
                $unchanged += ('оболочка `{0}`' -f $wrapperShort)
            }
        }
        if ($unchanged.Count -gt 0) {
            $lines.Add('')
            $lines.Add(('Без изменений: {0}.' -f ($unchanged -join ', ')))
        }
    }

    $lines.Add('')
    $lines.Add('---')
    $lines.Add('Распакуйте архив и запустите `Lampa.exe`. Профиль Chromium хранится в папке `user` рядом с программой.')

    return ($lines -join "`n")
}

function Get-NextReleaseTag {
    $date = Get-Date -Format 'yyyy.MM.dd'
    $base = "v$date"

    if (-not $GitHubRepo) {
        return $base
    }

    $releases = @()
    try {
        $releases = @(Invoke-GitHubApi "/repos/$GitHubRepo/releases?per_page=50")
    }
    catch {
        return $base
    }

    $names = @($releases | ForEach-Object { $_.tag_name })
    if ($names -notcontains $base) {
        return $base
    }

    $n = 2
    while ($names -contains "$base-$n") {
        $n++
    }
    return "$base-$n"
}

function Publish-GitHubRelease {
    param(
        [Parameter(Mandatory)]
        [string]$Tag,
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string]$NotesPath,
        [Parameter(Mandatory)]
        [string[]]$Files
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required to publish a release.'
    }

    $env:GH_TOKEN = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }

    & gh release create $Tag @Files --title $Title --notes-file $NotesPath --latest
    if ($LASTEXITCODE) {
        throw "gh release create failed: $LASTEXITCODE"
    }
}

Write-Step 'Reading current versions'

$nwjsJson = Invoke-RestMethod 'https://nwjs.io/versions.json'
$nwjsVersion = $nwjsJson.stable.TrimStart('v')
$nwjsInfo = @($nwjsJson.versions) | Where-Object { $_.version.TrimStart('v') -eq $nwjsVersion } | Select-Object -First 1
if (-not $nwjsInfo) {
    throw "NW.js $nwjsVersion was not found in versions.json"
}

$lampaHead = Invoke-GitHubApi "/repos/$LampaOwner/$LampaRepoName/commits/main"
$lampaSha = $lampaHead.sha

try {
    $assembly = Invoke-RestMethod "https://raw.githubusercontent.com/$LampaOwner/$LampaRepoName/$lampaSha/assembly.json"
}
catch {
    $assembly = $null
}

$wrapperSha = Get-WrapperHeadSha
$previous = Get-PreviousBuildInfo
$isFirstRelease = -not $previous

$nwjsChanged = $isFirstRelease -or ($previous.nwjs.version -ne $nwjsVersion)
$lampaChanged = $isFirstRelease -or ($previous.lampa.sha -ne $lampaSha)
if (-not $wrapperSha) {
    $wrapperChanged = $false
}
elseif ($isFirstRelease -or -not $previous.wrapper.sha) {
    $wrapperChanged = $true
}
else {
    $wrapperChanged = $previous.wrapper.sha -ne $wrapperSha
}
$ffmpegChanged = $nwjsChanged

$current = [pscustomobject]@{
    builtAt = [DateTime]::UtcNow.ToString('o')
    nwjs    = [pscustomobject]@{
        version   = $nwjsVersion
        chromium  = $nwjsInfo.components.chromium
        node      = $nwjsInfo.components.node
        changed   = [bool]$nwjsChanged
    }
    ffmpeg  = [pscustomobject]@{
        version = $nwjsVersion
        source  = 'nwjs-ffmpeg-prebuilt'
        changed = [bool]$ffmpegChanged
    }
    lampa   = [pscustomobject]@{
        repo       = "$LampaOwner/$LampaRepoName"
        sha        = $lampaSha
        appVersion = if ($assembly) { $assembly.app_version } else { '' }
        hash       = if ($assembly) { $assembly.hash } else { '' }
        changed    = [bool]$lampaChanged
    }
    wrapper = [pscustomobject]@{
        sha     = $wrapperSha
        changed = [bool]$wrapperChanged
    }
}

Write-Host "NW.js:  $nwjsVersion $(if ($nwjsChanged) { '(updated)' } else { '(same)' })"
Write-Host "Lampa:  $(Get-ShortSha $lampaSha) $(if ($lampaChanged) { '(updated)' } else { '(same)' })"
Write-Host "Wrapper: $(Get-ShortSha $wrapperSha) $(if ($wrapperChanged) { '(updated)' } else { '(same)' })"

$isSchedule = $GitHubEvent -eq 'schedule'
$shouldBuild = $ForceBuild -or -not $isSchedule -or $nwjsChanged -or $lampaChanged

if (-not $shouldBuild) {
    Write-Step 'No Lampa or NW.js updates, skipping scheduled build'
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '## Пропуск сборки'
            'По расписанию новых версий Lampa и NW.js нет. Релиз не создавался.'
        ) -join "`n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
    }
    exit 0
}

Write-Step 'Collecting changelog'

$lampaCommits = @()
if ($lampaChanged) {
    $fromSha = if ($previous) { $previous.lampa.sha } else { $null }
    $lampaCommits = @(Get-RemoteCommits -Owner $LampaOwner -Repo $LampaRepoName -FromSha $fromSha -ToSha $lampaSha)
}

$wrapperCommits = @()
if ($wrapperChanged) {
    $fromSha = if ($previous) { $previous.wrapper.sha } else { $null }
    $wrapperCommits = @(Get-WrapperCommits -FromSha $fromSha -ToSha $wrapperSha)
}

$nwjsEntries = if ($nwjsChanged) {
    @(Get-NwjsRange -VersionsJson $nwjsJson -OldVersion $(if ($previous) { $previous.nwjs.version } else { $null }) -NewVersion $nwjsVersion)
}
else {
    @()
}

if ($nwjsChanged -and $nwjsEntries.Count -eq 0) {
    $nwjsEntries = @($nwjsInfo)
}

$notes = New-ReleaseNotes -Current $current -Previous $previous -LampaCommits $lampaCommits -WrapperCommits $wrapperCommits -NwjsEntries $nwjsEntries -IsFirstRelease $isFirstRelease

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$notesPath = Join-Path $OutDir 'release-notes.md'
$infoPath = Join-Path $OutDir 'build-info.json'
[System.IO.File]::WriteAllText($notesPath, $notes, [System.Text.UTF8Encoding]::new($false))
$current | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $infoPath -Encoding utf8

if ($env:GITHUB_STEP_SUMMARY) {
    $notes | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

Write-Step 'Preparing output folders'
if (Test-Path -LiteralPath $DistDir) {
    Remove-Item -LiteralPath $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Path $AppDir, $CacheDir -Force | Out-Null

Write-Step 'Download NW.js'
$nwjsFileName = "nwjs-v$nwjsVersion-win-x64"
$nwjsFile = Join-Path $CacheDir "$nwjsFileName.zip"
Save-WebFile -Url "https://dl.nwjs.io/v$nwjsVersion/$nwjsFileName.zip" -LiteralPath $nwjsFile
Expand-ArchiveSmart -LiteralPath $nwjsFile -DestinationPath $AppDir -Folder $nwjsFileName

Write-Step 'Download FFmpeg'
$ffmpegFile = Join-Path $CacheDir "$nwjsVersion-win-x64-ffmpeg.zip"
Save-WebFile -Url "https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/$nwjsVersion/$nwjsVersion-win-x64.zip" -LiteralPath $ffmpegFile
Expand-ArchiveSmart -LiteralPath $ffmpegFile -DestinationPath $AppDir

Write-Step 'Download Lampa source'
$lampaFile = Join-Path $CacheDir "lampa-$lampaSha.zip"
Save-WebFile -Url "https://github.com/$LampaOwner/$LampaRepoName/archive/$lampaSha.zip" -LiteralPath $lampaFile
Expand-ArchiveSmart -LiteralPath $lampaFile -DestinationPath $AppDir -Folder "lampa-$lampaSha"

Write-Step 'Copy desktop wrapper'
Copy-Item -Path (Join-Path $WrapperDir '*') -Destination $AppDir -Recurse -Force
foreach ($junk in @('Dockerfile', '.dockerignore')) {
    $junkPath = Join-Path $AppDir $junk
    if (Test-Path -LiteralPath $junkPath) {
        Remove-Item -LiteralPath $junkPath -Force
    }
}

Write-Step 'Prepare Resource Hacker'
$resourceHackerArchive = Join-Path $CacheDir 'resource_hacker.zip'
$resourceHackerDir = Join-Path $CacheDir 'resource-hacker'
$resourceHackerFile = Join-Path $resourceHackerDir 'ResourceHacker.exe'
Save-WebFile -Url $ResourceHackerUrl -LiteralPath $resourceHackerArchive
if (-not (Test-Path -LiteralPath $resourceHackerFile -PathType Leaf)) {
    Expand-ArchiveSmart -LiteralPath $resourceHackerArchive -DestinationPath $resourceHackerDir
}

$nwExe = Join-Path $AppDir 'nw.exe'
$nwDll = Join-Path $AppDir 'nw.dll'
$iconFile = Join-Path $AppDir 'frame\icon.ico'
$lampaExe = Join-Path $AppDir 'Lampa.exe'

foreach ($file in @($nwExe, $nwDll, $iconFile, $resourceHackerFile)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "File not found: $file"
    }
}

function Invoke-ResourceHacker {
    param([string[]]$Arguments, [string]$LogFile)

    if (Test-Path -LiteralPath $LogFile) {
        Remove-Item -LiteralPath $LogFile -Force
    }
    $arguments += @('-log', "`"$LogFile`"")
    # Resource Hacker is a GUI executable: wait until it finishes writing the binary.
    $process = Start-Process -FilePath $resourceHackerFile -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    $log = if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Raw -Encoding Unicode } else { '' }
    # Logs are UTF-16 without BOM. "Success!" alone is not enough: a no-op still exits 0.
    $didWork = $log -match '(?m)^\s*(?:Modified|Added|Compiling):'
    if ($process.ExitCode -ne 0 -or $log -notmatch '(?m)^Success!' -or -not $didWork) {
        throw "Resource Hacker failed (exit $($process.ExitCode)). See ${LogFile}:`n$log"
    }
}

Write-Step 'Set NW.js application properties and icons'
$fileVersion = (Get-Date).ToString('yyyy.M.d.0')
$productVersion = [version]$nwjsVersion
$productVersionNumbers = '{0},{1},{2},{3}' -f $productVersion.Major, $productVersion.Minor, [Math]::Max(0, $productVersion.Build), [Math]::Max(0, $productVersion.Revision)
$iconTargets = @(
    @{ Path = $nwExe; Group = 'IDR_MAINFRAME'; OriginalFilename = 'Lampa.exe'; FileType = 1 }
    @{ Path = $nwDll; Group = '101'; OriginalFilename = 'nw.dll'; FileType = 2 }
)
foreach ($target in $iconTargets) {
    $binary = $target.Path
    $logFile = Join-Path $CacheDir ((Split-Path $binary -Leaf) + '.resource-hacker.log')
    $versionScript = Join-Path $CacheDir ((Split-Path $binary -Leaf) + '.version.rc')
    $versionResource = [System.IO.Path]::ChangeExtension($versionScript, '.res')
    @"
1 VERSIONINFO
FILEVERSION $($fileVersion.Replace('.', ','))
PRODUCTVERSION $productVersionNumbers
FILEFLAGSMASK 0x3f
FILEFLAGS 0x0
FILEOS 0x40004
FILETYPE $($target.FileType)
FILESUBTYPE 0x0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904b0"
        BEGIN
            VALUE "CompanyName", "Lampa Desktop"
            VALUE "FileDescription", "Lampa"
            VALUE "FileVersion", "$fileVersion"
            VALUE "OriginalFilename", "$($target.OriginalFilename)"
            VALUE "ProductName", "Lampa Desktop"
            VALUE "ProductVersion", "$nwjsVersion"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0409, 1200
    END
END
"@ | Set-Content -LiteralPath $versionScript -Encoding Unicode
    Invoke-ResourceHacker -Arguments @(
        '-open', "`"$versionScript`"", '-save', "`"$versionResource`"", '-action', 'compile'
    ) -LogFile $logFile
    Invoke-ResourceHacker -Arguments @(
        '-open', "`"$binary`"", '-save', "`"$binary`"", '-action', 'addoverwrite',
        '-res', "`"$versionResource`"", '-mask', 'VERSIONINFO,1,'
    ) -LogFile $logFile
    Invoke-ResourceHacker -Arguments @(
        '-open', "`"$binary`"",
        '-save', "`"$binary`"",
        '-action', 'addoverwrite',
        '-res', "`"$iconFile`"",
        '-mask', "ICONGROUP,$($target.Group),"
    ) -LogFile $logFile
}

Move-Item -LiteralPath $nwExe -Destination $lampaExe -Force

Write-Step 'Pack zip'
$zipPath = Join-Path $OutDir 'Lampa-Desktop-win-x64.zip'
Compress-FolderZip -SourceDir $AppDir -ZipPath $zipPath
Write-Host "Created $zipPath"

if ($SkipRelease) {
    Write-Step 'Skip GitHub release (local build or missing repository context)'
    Write-Host $notes
    exit 0
}

$tag = Get-NextReleaseTag
$title = "Lampa Desktop $($tag.TrimStart('v'))"
Write-Step "Publish GitHub release $tag"
Publish-GitHubRelease -Tag $tag -Title $title -NotesPath $notesPath -Files @($zipPath, $infoPath)
Write-Host "Release $tag published."
