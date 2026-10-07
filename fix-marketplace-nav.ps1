# fix-marketplace-nav.ps1
#
# Restores the Spicetify Marketplace nav icon, route and stylesheet on a
# SpotX-patched Spotify client.
#
# WHY THIS IS NEEDED
#   Spotify 1.2.64+ ships its xpui modules inside v8_context_snapshot.bin, and
#   Spicetify extracts them to xpui-modules.js, then rewrites index.html to load
#   that file. The rewrite is keyed on a <script src="/xpui-snapshot.js"> tag.
#   On a SpotX-patched client that tag (and the file) do not exist: index.html
#   loads /xpui.js instead. So Spicetify's custom-app patches land in a file the
#   client never fetches, and every step still reports "success".
#
#   Upstream will not fix this - spicetify/cli#3922 was closed as not planned
#   ("Both should not be used at the same time"), tracked at
#   SpotX-Official/SpotX#892. So this script is the long-term fix, not a stopgap.
#
#   Verified on Spotify 1.2.99.317.g9bd8c54d + Spicetify 2.44.0 (Windows 11).
#   The anchors below are exact substrings of that xpui.js; on a different
#   build the script refuses to write rather than guess (see the anchor check).
#
# WHAT IT DOES
#   Applies the four patches Spicetify would have applied, directly into the
#   xpui.js that actually loads. Each edit is applied only if missing, so the
#   script is idempotent and safe to re-run at any time.
#
# WHEN TO RE-RUN
#   After any Spotify update, `spicetify apply`, `spicetify backup apply`, or
#   Spicetify upgrade. If Marketplace looks unstyled or its icon vanishes, run it.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File .\fix-marketplace-nav.ps1
#
#   Close Spotify first. With no arguments it patches the live bundle plus
#   Spicetify's two staging copies, so a later `spicetify apply` keeps working.

param(
    [string[]]$Target,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'

if (-not $Target -or $Target.Count -eq 0) {
    $spotifyDir = Join-Path $env:APPDATA "Spotify"
    if (-not (Test-Path $spotifyDir)) {
        $spotifyDir = Join-Path $env:LOCALAPPDATA "Spotify"
    }

    $Target = @(
        (Join-Path $spotifyDir "Apps\xpui\xpui.js")               # the file Spotify loads
        "$env:APPDATA\spicetify\Extracted\Raw\xpui\xpui.js"       # survives `spicetify apply`
        "$env:APPDATA\spicetify\Extracted\Themed\xpui\xpui.js"
    ) | Where-Object { Test-Path $_ }
}

# Marker = proof the edit is already in place. Find = unique anchor. Repl = anchor + patch.
$edits = @(
    @{
        Name   = 'lazy component'
        Marker = 'spicetifyApp0=D.lazy'
        Find   = 'return{default:e}}),ok=()=>'
        Repl   = 'return{default:e}}),spicetifyApp0=D.lazy((()=>i.e("spicetify-routes-marketplace").then(i.bind(i,"spicetify-routes-marketplace")))),ok=()=>'
    },
    @{
        Name   = 'route'
        Marker = 'path:"/marketplace/*"'
        Find   = '(0,y.jsx)(eO.qh,{path:"/settings",element:(0,y.jsx)(_x.$,{to:"/"})})'
        Repl   = '(0,y.jsx)(eO.qh,{path:"/marketplace/*",pathV6:"/marketplace/*",element:(0,y.jsx)(spicetifyApp0,{})}),(0,y.jsx)(eO.qh,{path:"/settings",element:(0,y.jsx)(_x.$,{to:"/"})})'
    },
    @{
        # spicetifyWrapper.js's _renderNavLinks calls Spicetify.React.useReducer as
        # its very first line, before its own "are the deps ready" guard. Spicetify.React
        # is resolved asynchronously ("[spicetifyWrapper] Waiting for required webpack
        # modules to load"), so calling this unguarded on the nav bar's first render
        # (which happens synchronously at boot, before that resolves) throws
        # "Cannot read properties of undefined (reading 'useReducer')" - uncaught,
        # which trips xpui's top-level error boundary into "Something went wrong" on
        # every launch. The try/catch throws away that one failed attempt (it never
        # reaches React's dispatcher - Spicetify.React.useReducer fails on the
        # property read, so no hook bookkeeping happens) and relies on the sidebar's
        # frequent natural re-renders (playback ticks, etc.) to retry once
        # Spicetify.React is actually set. Same pattern as the useNavigateStable fix
        # in fix.ps1 Section B2.
        Name   = 'nav icon'
        Marker = '_renderNavLinks(["marketplace"'
        Find   = 'c&&(0,y.jsxs)(dh,{children:[o?(0,y.jsx)(d_,{}):(0,y.jsx)(dm,{}),(0,y.jsx)(dl,{className:dt})'
        Repl   = 'c&&(0,y.jsxs)(dh,{children:[o?(0,y.jsx)(d_,{}):(0,y.jsx)(dm,{}),(0,y.jsx)(dl,{className:dt}),(()=>{try{return Spicetify._renderNavLinks(["marketplace",], true)}catch(err){return null}})()'
    },
    @{
        # Without this the route's stylesheet is never fetched and Marketplace
        # renders completely unstyled - no grid, oversized controls, one long
        # scroll. webpack gates CSS fetching on a numeric-only allowlist.
        Name   = 'stylesheet allowlist'
        Marker = '"spicetify-routes-marketplace":1'
        Find   = 'a.f.miniCss=function(e,t){if(d[e])t.push(d[e]);else 0!==d[e]&&({'
        Repl   = 'a.f.miniCss=function(e,t){if(d[e])t.push(d[e]);else 0!==d[e]&&({"spicetify-routes-marketplace":1,'
    }
)

if (Get-Process Spotify -ErrorAction SilentlyContinue) {
    Write-Host "WARNING: Spotify is running. Close it first, or the patch may not take effect." -ForegroundColor Yellow
}

$enc = New-Object System.Text.UTF8Encoding($false)
$anyChanged = $false

foreach ($path in $Target) {
    Write-Host "`n$path" -ForegroundColor White
    if (-not (Test-Path $path)) { Write-Host "  missing - skipped" -ForegroundColor DarkGray; continue }

    $text = [System.IO.File]::ReadAllText($path, $enc)
    $todo = @()

    foreach ($e in $edits) {
        if ($text.Contains($e.Marker)) {
            Write-Host ("  already present: {0}" -f $e.Name) -ForegroundColor DarkGray
            continue
        }
        $count = 0; $i = 0
        while (($i = $text.IndexOf($e.Find, $i)) -ge 0) { $count++; $i += $e.Find.Length }
        if ($count -ne 1) {
            Write-Host ("  ANCHOR '{0}' matched {1} times (expected 1) - skipping this file untouched." -f $e.Name, $count) -ForegroundColor Red
            Write-Host "  Spotify's bundle likely changed. Nothing was written." -ForegroundColor Red
            $todo = $null
            break
        }
        $todo += $e
    }

    if ($null -eq $todo) { continue }
    if ($todo.Count -eq 0) { Write-Host "  fully patched" -ForegroundColor Green; continue }

    if (-not $NoBackup) {
        $bak = "$path.prenav.bak"
        if (-not (Test-Path $bak)) { Copy-Item $path $bak }
    }

    foreach ($e in $todo) {
        $text = $text.Replace($e.Find, $e.Repl)
        Write-Host ("  patched: {0}" -f $e.Name) -ForegroundColor Cyan
    }

    [System.IO.File]::WriteAllText($path, $text, $enc)
    $anyChanged = $true
}

if ($anyChanged) {
    Write-Host "`nDone. Start Spotify and open Marketplace to confirm." -ForegroundColor Green
} else {
    Write-Host "`nNothing to do - everything already patched." -ForegroundColor Green
}
