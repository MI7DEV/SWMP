# SWMP — leitor de música em segundo plano (arrancado pelo mod ZeroCompanyMP).
# O mod escreve mp_player.json {"file":"C:\\...\\x.mp3","vol":0.7,"seq":N,"ts":N}; este leitor toca com crossfade
# e escreve mp_player_state.json {"seq":N,"pos":s,"len":s,"ended":bool,"ts":N}. Sai sozinho se o jogo fechar.
param([string]$Dir, [switch]$NoGameCheck)
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationCore
$cmdFile   = Join-Path $Dir 'mp_player.json'
$stateFile = Join-Path $Dir 'mp_player_state.json'
$lockFile  = Join-Path $Dir 'mp_player.pid'
$logFile   = Join-Path $Dir 'mp_player.log'
function Log($m) { Add-Content -Path $logFile -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $m) -Encoding utf8 }

# uma única instância
if (Test-Path $lockFile) {
    $old = Get-Content $lockFile -Raw
    if ($old -and (Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue)) { exit }
}
Set-Content -Path $lockFile -Value $PID -Encoding ascii
Log "leitor iniciado (pid $PID)"
trap { Log ("erro: " + $_); continue }

$players = @((New-Object System.Windows.Media.MediaPlayer), (New-Object System.Windows.Media.MediaPlayer))
$cur = 0; $curSeq = -1; $curFile = ''; $vol = 0.7
$fadeMs = 2500; $fadeStart = $null
$tick = 0

function Now-Unix { [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

while ($true) {
    # o jogo fechou → desliga (verifica a cada ~2 s)
    $tick++
    if (-not $NoGameCheck -and $tick % 8 -eq 0 -and -not (Get-Process -Name 'SWZeroCompany*' -ErrorAction SilentlyContinue)) { Log 'jogo fechado'; break }
    $cmd = $null
    try { $cmd = [IO.File]::ReadAllText($cmdFile) | ConvertFrom-Json } catch {}
    if ($cmd) {
        if ($cmd.vol -ne $null) { $vol = [double]$cmd.vol }
        # o mod renova "ts"; o jogo pode ficar minutos sem o renovar (shaders, mapas) — só desliga com 10 min sem sinal
        # (o fim normal é o jogo fechar, verificado acima)
        if ((Now-Unix) - [int]$cmd.ts -gt 600) { Log "sem sinal do mod (ts=$($cmd.ts))"; break }
        if ([int]$cmd.seq -ne $curSeq) {
            $curSeq = [int]$cmd.seq
            $next = 1 - $cur
            if ($cmd.file -and (Test-Path -LiteralPath $cmd.file)) {
                $players[$next].Open([Uri]$cmd.file)
                $players[$next].Volume = 0
                $players[$next].Play()
                $curFile = $cmd.file
            } else {
                $players[$next].Close(); $curFile = ''
            }
            $cur = $next; $fadeStart = Get-Date
        }
    }
    # crossfade: entra o atual, sai o anterior
    $p = $players[$cur]; $o = $players[1 - $cur]
    if ($fadeStart) {
        $k = [Math]::Min(1.0, ((Get-Date) - $fadeStart).TotalMilliseconds / $fadeMs)
        $p.Volume = $vol * $k
        $o.Volume = $o.Volume * (1 - $k)
        if ($k -ge 1) { $o.Stop(); $o.Close(); $fadeStart = $null }
    } else { $p.Volume = $vol }
    $len = 0; $pos = $p.Position.TotalSeconds
    if ($p.NaturalDuration.HasTimeSpan) { $len = $p.NaturalDuration.TimeSpan.TotalSeconds }
    $ended = ($curFile -ne '' -and $len -gt 0 -and $pos -ge $len - 0.3)
    $state = @{ seq = $curSeq; pos = [Math]::Round($pos, 1); len = [Math]::Round($len, 1); ended = $ended; file = $curFile; ts = (Now-Unix) } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($stateFile, $state)
    Start-Sleep -Milliseconds 250
}
Log 'leitor terminado'
foreach ($x in $players) { $x.Stop(); $x.Close() }
Remove-Item $lockFile -ErrorAction SilentlyContinue
