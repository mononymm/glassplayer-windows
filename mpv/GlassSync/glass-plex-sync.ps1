# Glass -> Plex watch-progress sync
# Runs on the Windows profile that runs Plex Media Server. Reads the progress mpv left in
# plex-queue.json and pushes it to Plex, but only when mpv's record is newer than Plex's own.
# Nothing is written to Plex's database directly; updates go through Plex's normal web API.

$ErrorActionPreference = 'Stop'
$SyncDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Queue    = Join-Path $SyncDir 'plex-queue.json'
$LogFile  = Join-Path $SyncDir 'sync.log'
$PlexUrl  = 'http://127.0.0.1:32400'
$Account  = 1          # the server's admin account
$Watched  = 0.90       # past this fraction of the runtime counts as watched
$Utf8     = New-Object System.Text.UTF8Encoding $false

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $Utf8)
}

# only one copy at a time
$mutex = New-Object System.Threading.Mutex($false, 'Global\GlassPlexSync')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    if (-not (Test-Path $Queue)) { exit 0 }
    # (Windows PowerShell returns a JSON array as one object; piping it through ForEach-Object unrolls it)
    $entries = @(Get-Content $Queue -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
    if ($entries.Count -eq 0) { exit 0 }

    # Plex's own settings (this profile): sign-in token and data folder
    $reg = Get-ItemProperty 'HKCU:\Software\Plex, Inc.\Plex Media Server' -ErrorAction SilentlyContinue
    if (-not $reg -or -not $reg.PlexOnlineToken) { Log 'Plex token not found in this profile''s registry. Run this on the profile that runs Plex.'; exit 1 }
    $token = $reg.PlexOnlineToken
    $dataRoot = if ($reg.LocalAppDataPath) { $reg.LocalAppDataPath } else { $env:LOCALAPPDATA }
    $db = Join-Path $dataRoot 'Plex Media Server\Plug-in Support\Databases\com.plexapp.plugins.library.db'
    $sqlite = Join-Path ${env:ProgramFiles} 'Plex\Plex Media Server\Plex SQLite.exe'
    if (-not (Test-Path $sqlite)) { $sqlite = Join-Path ${env:ProgramFiles(x86)} 'Plex\Plex Media Server\Plex SQLite.exe' }
    $headers = @{ 'X-Plex-Token' = $token; 'Accept' = 'application/json' }

    # wait (up to 15 minutes) for Plex to be up
    $up = $false
    for ($i = 0; $i -lt 90; $i++) {
        try { Invoke-WebRequest "$PlexUrl/identity" -UseBasicParsing -TimeoutSec 5 | Out-Null; $up = $true; break }
        catch { Start-Sleep -Seconds 10 }
    }
    if (-not $up) { Log 'Plex did not respond; will try again next run.'; exit 0 }

    $handled = @{}
    foreach ($e in $entries) {
        $path = [string]$e.path
        $key = $path + '|' + [string]$e.t
        try {
            $win = $path.Replace('/', '\').Replace("'", "''")
            $sql = "SELECT mi.id, IFNULL(s.view_offset,0), IFNULL(s.view_count,0), " +
                   "CASE typeof(s.last_viewed_at) WHEN 'integer' THEN s.last_viewed_at WHEN 'text' THEN strftime('%s',s.last_viewed_at) ELSE 0 END, " +
                   "CASE typeof(s.updated_at) WHEN 'integer' THEN s.updated_at WHEN 'text' THEN strftime('%s',s.updated_at) ELSE 0 END " +
                   "FROM media_parts mp JOIN media_items m ON m.id = mp.media_item_id " +
                   "JOIN metadata_items mi ON mi.id = m.metadata_item_id " +
                   "LEFT JOIN metadata_item_settings s ON s.guid = mi.guid AND s.account_id = $Account " +
                   "WHERE REPLACE(mp.file,'/','\') = '$win' COLLATE NOCASE LIMIT 1;"
            $row = & $sqlite -readonly -separator '|' $db $sql
            if (-not $row) { Log "Not in Plex, skipped: $path"; $handled[$key] = $true; continue }
            $f = ([string]$row).Split('|')
            $id = $f[0]
            $plexTime = [Math]::Max([double]$f[3], [double]$f[4])
            $mpvTime = [double]$e.t

            if ($mpvTime -le $plexTime + 5) {
                Log ("Plex is newer, kept Plex's progress: {0}" -f (Split-Path $path -Leaf))
                $handled[$key] = $true; continue
            }

            $pos = [double]$e.pos; $dur = [double]$e.dur
            $done = [bool]$e.done -or ($dur -gt 0 -and $pos -ge $Watched * $dur)
            if ($e.unwatch -eq $true) {
                Invoke-WebRequest "$PlexUrl/:/unscrobble?key=$id&identifier=com.plexapp.plugins.library" -Headers $headers -UseBasicParsing | Out-Null
                Log ("Marked unwatched: {0}" -f (Split-Path $path -Leaf))
            } elseif ($done) {
                Invoke-WebRequest "$PlexUrl/:/scrobble?key=$id&identifier=com.plexapp.plugins.library" -Headers $headers -UseBasicParsing | Out-Null
                Log ("Marked watched: {0}" -f (Split-Path $path -Leaf))
            } elseif ($pos -ge 10) {
                $ms = [int64]($pos * 1000); $durMs = [int64]($dur * 1000)
                try {
                    Invoke-WebRequest "$PlexUrl/:/progress?key=$id&identifier=com.plexapp.plugins.library&time=$ms&state=stopped" -Headers $headers -UseBasicParsing | Out-Null
                } catch {
                    Invoke-WebRequest ("$PlexUrl/:/timeline?ratingKey=$id&key=%2Flibrary%2Fmetadata%2F$id&identifier=com.plexapp.plugins.library" +
                        "&state=stopped&time=$ms&duration=$durMs") -Headers $headers -UseBasicParsing | Out-Null
                }
                Log ("Resume point set to {0:hh\:mm\:ss}: {1}" -f [TimeSpan]::FromSeconds($pos), (Split-Path $path -Leaf))
            } else {
                Log ("Under 10 seconds watched, nothing to send: {0}" -f (Split-Path $path -Leaf))
            }
            $handled[$key] = $true
        } catch {
            Log ("Failed (will retry next run): {0}  -  {1}" -f $path, $_.Exception.Message)
        }
    }

    # drop what was handled; re-read first in case mpv added something meanwhile
    $current = @(Get-Content $Queue -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ })
    $left = @($current | Where-Object { -not $handled.ContainsKey([string]$_.path + '|' + [string]$_.t) })
    $json = if ($left.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $left -Depth 4 -Compress }
    [System.IO.File]::WriteAllText($Queue, $json, $Utf8)
}
catch { Log ('Sync error: ' + $_.Exception.Message) }
finally { $mutex.ReleaseMutex() | Out-Null }
