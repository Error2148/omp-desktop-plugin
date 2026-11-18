param([Parameter(Mandatory = $true)][string]$Root)

# Lists omp session files under $Root as JSON: one record per <project>/<session>.jsonl
# with the title (line 1) and the working directory (line 2, the "session" header).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$out = New-Object System.Collections.Generic.List[object]

if (Test-Path -LiteralPath $Root) {
    foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory) {
        foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File) {
            $title = ''
            $cwd = ''
            try {
                $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                try {
                    for ($i = 0; $i -lt 4; $i++) {
                        $line = $sr.ReadLine()
                        if ($null -eq $line) { break }
                        if ($line.Length -gt 100000) { continue }
                        $o = ConvertFrom-Json -InputObject $line
                        if ($o.type -eq 'title' -and $o.title) { $title = [string]$o.title }
                        elseif ($o.type -eq 'session') { if ($o.cwd) { $cwd = [string]$o.cwd }; break }
                    }
                }
                finally { $sr.Dispose(); $fs.Dispose() }
            }
            catch { continue }
            if ($cwd -eq '') { continue }
            $out.Add([pscustomobject]@{
                file  = $f.FullName
                cwd   = $cwd
                title = $title
                mtime = [int64][Math]::Floor(($f.LastWriteTimeUtc - $epoch).TotalSeconds)
                size  = $f.Length
            })
        }
    }
}

[Console]::Out.Write((ConvertTo-Json -InputObject @($out.ToArray()) -Compress -Depth 3))
