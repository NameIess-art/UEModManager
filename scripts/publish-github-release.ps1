param(
    [string]$Owner = "NameIess-art",
    [string]$Repo = "UEModManager",
    [string]$Tag = "v2.4.1",
    [string]$ReleaseName = "",
    [string[]]$Assets = @()
)

$ErrorActionPreference = "Stop"

function Get-GitHubToken {
    $inputData = "protocol=https`nhost=github.com`nusername=$Owner`n"
    $credentialOutput = $inputData | git credential-manager get --no-ui
    $passwordLine = $credentialOutput | Where-Object { $_ -like "password=*" } | Select-Object -First 1

    if (-not $passwordLine) {
        throw "Unable to obtain a GitHub API token from Git Credential Manager. Run: git credential-manager github login --device --username $Owner"
    }

    return $passwordLine.Substring("password=".Length)
}

function Get-Headers([string]$Token) {
    return @{
        Authorization        = "Bearer $Token"
        Accept               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"         = "UEModManager-ReleasePublisher"
    }
}

function Invoke-GitHubJsonRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body
    )

    if ($null -eq $Body) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
}

if ([string]::IsNullOrWhiteSpace($ReleaseName)) {
    $ReleaseName = $Tag
}

if ($Assets.Count -eq 0) {
    $version = $Tag.TrimStart("v")
    $Assets = @(
        "dist\UE Mod Manager Setup $version.exe",
        "dist\UE Mod Manager Setup $version.exe.blockmap",
        "dist\latest.yml"
    )
}

$resolvedAssets = @()
foreach ($asset in $Assets) {
    $resolved = Resolve-Path -LiteralPath $asset -ErrorAction Stop
    $resolvedAssets += $resolved.Path
}

$token = Get-GitHubToken
$headers = Get-Headers -Token $token
$apiBase = "https://api.github.com/repos/$Owner/$Repo"
$release = $null

try {
    $release = Invoke-GitHubJsonRequest -Method "GET" -Uri "$apiBase/releases/tags/$Tag" -Headers $headers -Body $null
    Write-Output "Found existing release for $Tag."
}
catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        throw
    }

    $releaseBody = @{
        tag_name              = $Tag
        name                  = $ReleaseName
        target_commitish      = "main"
        generate_release_notes = $true
        draft                 = $false
        prerelease            = $false
    }

    $release = Invoke-GitHubJsonRequest -Method "POST" -Uri "$apiBase/releases" -Headers $headers -Body $releaseBody
    Write-Output "Created release for $Tag."
}

$uploadUrl = $release.upload_url -replace "\{\?name,label\}", ""

foreach ($asset in $resolvedAssets) {
    $assetName = Split-Path -Leaf $asset
    $existingAsset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1

    if ($existingAsset) {
        Invoke-RestMethod -Method "DELETE" -Uri "$apiBase/releases/assets/$($existingAsset.id)" -Headers $headers | Out-Null
        Write-Output "Deleted existing asset: $assetName"
    }

    $uploadUri = "${uploadUrl}?name=$([Uri]::EscapeDataString($assetName))"
    Invoke-RestMethod -Method "POST" -Uri $uploadUri -Headers @{
        Authorization        = $headers.Authorization
        Accept               = $headers.Accept
        "X-GitHub-Api-Version" = $headers."X-GitHub-Api-Version"
        "User-Agent"         = $headers."User-Agent"
        "Content-Type"       = "application/octet-stream"
    } -InFile $asset | Out-Null

    Write-Output "Uploaded asset: $assetName"
}

Write-Output "Release published: $($release.html_url)"
