# Repo publico, sin token. Espera el tag y baja DjStudio-Installer.exe, app-release.apk y DjStudio-MacOS.zip.
# powershell -NoProfile -ExecutionPolicy Bypass -File .\pull_release.ps1 -Tag v2.0.1 -OutDir "$env:USERPROFILE\Desktop\DjStudio"

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Tag = 'v2.0.1',

    [Parameter(Position = 1)]
    [string]$OutDir = $(Join-Path $env:USERPROFILE 'Desktop\DjStudio'),

    [string]$Repo = 'GatoNegro5/DjStudio-Automix'
)

$ErrorActionPreference = 'Stop'

if ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Repo invalido: $Repo"
}
if ($Tag -notmatch '^[A-Za-z0-9_.+-]+$') {
    throw "Tag invalido: $Tag"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
    throw 'OutDir vacio.'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

Add-Type -AssemblyName System.Net.Http

$AssetNames = @(
    'DjStudio-Installer.exe',
    'app-release.apk',
    'DjStudio-MacOS.zip'
)

function Get-ResponseHeader {
    param($Headers, [string]$Name)
    if ($null -eq $Headers) { return $null }
    try {
        return [string](@($Headers.GetValues($Name)) | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Get-UnixNow {
    $epoch = New-Object System.DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [int64]([DateTime]::UtcNow - $epoch).TotalSeconds
}

function Get-PollDelaySeconds {
    param([string]$Remaining, [string]$Reset)
    $normal = 20
    $left = 0
    if (-not [int]::TryParse($Remaining, [ref]$left)) { return $normal }
    if ($left -gt 8) { return $normal }
    $resetEpoch = [int64]0
    if (-not [int64]::TryParse($Reset, [ref]$resetEpoch)) { return 90 }
    $until = [int]($resetEpoch - (Get-UnixNow) + 2)
    if ($until -lt $normal) { return $normal }
    $budget = $left - 2
    if ($budget -lt 1) { return $until }
    $spread = [int][Math]::Ceiling($until / $budget)
    if ($spread -lt $normal) { return $normal }
    return $spread
}

function Get-Release {
    param($Client, [string]$Uri)
    $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
    try {
        $status = [int]$response.StatusCode
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = $null
        if ($status -eq 200 -and -not [string]::IsNullOrWhiteSpace($body)) {
            $json = $body | ConvertFrom-Json
        }
        return @{
            StatusCode = $status
            Json       = $json
            Remaining  = (Get-ResponseHeader $response.Headers 'X-RateLimit-Remaining')
            Reset      = (Get-ResponseHeader $response.Headers 'X-RateLimit-Reset')
        }
    } finally {
        $response.Dispose()
    }
}

function Save-ReleaseAsset {
    param($Client, $Asset, [string]$Destination)
    $name = [string]$Asset.name
    $url = [string]$Asset.browser_download_url
    $parsed = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$parsed)) {
        throw "URL invalida para ${name}."
    }
    if ($parsed.Scheme -ne 'https' -or $parsed.Host -ne 'github.com') {
        throw "URL inesperada para ${name}: $url"
    }

    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    $response = $Client.GetAsync(
        $url,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    ).GetAwaiter().GetResult()
    try {
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode) al bajar $name"
        }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $file = [System.IO.File]::Create($partial)
            try {
                $stream.CopyTo($file)
            } finally {
                $file.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } finally {
        $response.Dispose()
    }

    $length = (Get-Item -LiteralPath $partial).Length
    $expected = [int64]$Asset.size
    if ($length -ne $expected) {
        Remove-Item -LiteralPath $partial -Force
        throw "Tamano de ${name}: $length bytes; el release declara $expected."
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

$api = "https://api.github.com/repos/$Repo/releases/tags/$([uri]::EscapeDataString($Tag))"
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(60)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('DjStudio-ReleasePull')
$client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')

# Descarga aparte: el Accept de la API no debe aplicarse al binario.
$downloadClient = New-Object System.Net.Http.HttpClient
$downloadClient.Timeout = [TimeSpan]::FromMinutes(30)
$downloadClient.DefaultRequestHeaders.UserAgent.ParseAdd('DjStudio-ReleasePull')

$printedUrl = $false
Write-Host "Esperando $Tag en $Repo"

try {
    while ($true) {
        $release = $null
        $delay = 20
        try {
            $result = Get-Release -Client $client -Uri $api
            $delay = Get-PollDelaySeconds -Remaining $result.Remaining -Reset $result.Reset
            if ($result.StatusCode -eq 200) {
                $release = $result.Json
            } elseif ($result.StatusCode -eq 404) {
                Write-Host "Release $Tag todavia no existe. Reintento en ${delay}s."
            } elseif ($result.StatusCode -eq 403 -or $result.StatusCode -eq 429) {
                Write-Host "Limite de la API de GitHub. Reintento en ${delay}s."
            } else {
                Write-Host "GitHub respondio HTTP $($result.StatusCode). Reintento en ${delay}s."
            }
        } catch {
            Write-Host "Error de red: $($_.Exception.Message). Reintento en ${delay}s."
        }

        if ($null -ne $release) {
            if (-not $printedUrl -and $release.html_url) {
                Write-Host "html_url: $($release.html_url)"
                $printedUrl = $true
            }

            $ready = New-Object 'System.Collections.Generic.Dictionary[string,object]'
            foreach ($asset in @($release.assets)) {
                if ($null -eq $asset) { continue }
                $name = [string]$asset.name
                $state = [string]$asset.state
                $size = 0L
                [void][int64]::TryParse([string]$asset.size, [ref]$size)
                $uploaded = ($state -eq '' -or $state -eq 'uploaded')
                if (($AssetNames -contains $name) -and $uploaded -and $size -gt 0 -and $asset.browser_download_url) {
                    $ready[$name] = $asset
                }
            }

            $missing = @($AssetNames | Where-Object { -not $ready.ContainsKey($_) })
            if ($missing.Count -eq 0) {
                $OutDir = [System.IO.Path]::GetFullPath($OutDir)
                New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
                foreach ($name in $AssetNames) {
                    $destination = Join-Path $OutDir $name
                    Write-Host "Bajando $name"
                    Save-ReleaseAsset -Client $downloadClient -Asset $ready[$name] -Destination $destination
                    Write-Host $destination
                }
                if ($release.html_url) {
                    Write-Host "html_url: $($release.html_url)"
                }
                break
            }

            Write-Host ("Faltan assets: {0}. Reintento en {1}s." -f ($missing -join ', '), $delay)
        }

        Start-Sleep -Seconds $delay
    }
} finally {
    $client.Dispose()
    $downloadClient.Dispose()
}
