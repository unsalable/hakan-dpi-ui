# Ana ekrandaki Yontem/DNS menuleri gercek pencerede: satira tiklayinca menu yerinde acilir,
# menuden secim tek istekle servise gider (sayfa degismez).
# Gercek servise dokunulmaz: betik sahte bir servis pipe'i acar (varsayilan ayarlarla yanit verir),
# arayuz GDPI3_TEST + GDPI3_PIPE ile ona baglanir. Tiklamalar pencereye mesaj olarak gonderilir
# (fare imleci oynamaz); goruntuler PrintWindow ile alinir (pencere one zorlanmaz).
# Ornek: powershell -ExecutionPolicy Bypass -File perf\home-menu-test.ps1 -Exe target\release\GoodbyeDPI3.exe
# Not: dosya bilerek yalnizca ASCII karakter icerir (Windows PowerShell 5.1 BOM'suz UTF-8'i yanlis okur).
param(
    [Parameter(Mandatory = $true)] [string] $Exe,
    [string] $OutDir = "perf\out"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// Sahte motor servisi: her istege servis gibi yanit verir (varsayilan ayar, motor kapali);
// setConfig isteklerini saklar.
public class MenuFakeService {
    NamedPipeServerStream server;
    StreamReader reader;
    StreamWriter writer;
    readonly List<string> kinds = new List<string>();
    readonly List<string> configs = new List<string>();

    public MenuFakeService(string name) {
        server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 65536, 65536);
    }

    public bool WaitClient(int ms) {
        IAsyncResult ar = server.BeginWaitForConnection(null, null);
        if (!ar.AsyncWaitHandle.WaitOne(ms)) return false;
        server.EndWaitForConnection(ar);
        UTF8Encoding utf8 = new UTF8Encoding(false);
        reader = new StreamReader(server, utf8);
        writer = new StreamWriter(server, utf8);
        writer.AutoFlush = true;
        Thread t = new Thread(Loop);
        t.IsBackground = true;
        t.Start();
        return true;
    }

    void Loop() {
        try {
            string line;
            while ((line = reader.ReadLine()) != null) {
                string kind = Regex.Match(line, "\"type\":\"(\\w+)\"").Groups[1].Value;
                string id = Regex.Match(line, "\"id\":(\\d+)").Groups[1].Value;
                lock (kinds) {
                    kinds.Add(kind);
                    if (kind == "setConfig") configs.Add(line);
                }
                string r;
                if (kind == "hello") r = "{\"type\":\"hello\",\"service_version\":\"9.9.9\",\"protocol\":1}";
                else if (kind == "getState") r = "{\"type\":\"state\",\"state\":{\"serviceVersion\":\"9.9.9\",\"engine\":{\"methodName\":\"Varsay\u0131lan\",\"dnsName\":\"Cloudflare DoH\"},\"config\":{},\"learned\":[],\"conflicts\":[],\"update\":{\"state\":\"idle\"}}}";
                else r = "{\"type\":\"ok\"}";
                writer.Write("{\"kind\":\"reply\",\"id\":" + id + ",\"response\":" + r + "}\n");
            }
        } catch (Exception) { }
    }

    public bool Saw(string kind) { lock (kinds) return kinds.Contains(kind); }
    public int ConfigCount() { lock (kinds) return configs.Count; }
    public string Config(int i) { lock (kinds) return configs[i]; }
    public void Close() { try { server.Dispose(); } catch (Exception) { } }
}

public static class MenuW32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // Surecin gorunur ust duzey pencereleri (acilir menu ayri pencere olarak acilirsa gorunsun).
    public static int VisibleWindows(uint pid) {
        int n = 0;
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h)) n++;
            return true;
        }, IntPtr.Zero);
        return n;
    }
}
"@

$failed = 0
function Check([string] $name, [bool] $ok) {
    if ($ok) { Write-Host "  OK   $name" } else { Write-Host "  HATA $name"; $script:failed++ }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$pipeName = "GoodbyeDPI3.menutest.$PID"
$env:GDPI3_TEST = "1"; $env:GDPI3_INSTANCE = ".menutest"; $env:GDPI3_PIPE = "\\.\pipe\$pipeName"
$svc = New-Object MenuFakeService($pipeName)
$p = Start-Process -FilePath $Exe -PassThru
try {
    Check "pencere sahte servise baglandi" ($svc.WaitClient(15000))
    for ($i = 0; $i -lt 80 -and -not $svc.Saw("checkUpdate"); $i++) { Start-Sleep -Milliseconds 100 }
    for ($i = 0; $i -lt 50 -and $p.MainWindowHandle -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $p.Refresh() }
    $h = $p.MainWindowHandle
    Check "pencere acildi" ($h -ne [IntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    $s = [MenuW32]::GetDpiForWindow($h) / 96.0

    # Mantiksal (x, y) noktasina sol tik: imlec konumu, bas, birak. Uc mesaj arka arkaya kuyruga
    # girer: gercek imlec pencerenin disindayken Windows imlec konumu mesajindan sonra "fare cikti"
    # (WM_MOUSELEAVE) gonderir; arada bekleme olsaydi basma ona denk gelir ve kaybolurdu.
    function Click([double] $x, [double] $y) {
        $l = [IntPtr](([int]($y * $s) -shl 16) -bor [int]($x * $s))
        [void][MenuW32]::PostMessage($h, 0x0200, [IntPtr]::Zero, $l)
        [void][MenuW32]::PostMessage($h, 0x0201, [IntPtr]1, $l)
        [void][MenuW32]::PostMessage($h, 0x0202, [IntPtr]::Zero, $l)
        Start-Sleep -Milliseconds 600
    }
    function Shot([string] $name) {
        $r = New-Object MenuW32+RECT; [void][MenuW32]::GetWindowRect($h, [ref]$r)
        $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
        $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
        [void][MenuW32]::PrintWindow($h, $hdc, 2)
        $g.ReleaseHdc($hdc); $g.Dispose()
        $bmp.Save((Join-Path $OutDir "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        return $bmp
    }
    function Px($bmp, [double] $x, [double] $y) { return $bmp.GetPixel([int]($x * $s), [int]($y * $s)) }
    # Dosyaya yazmadan hizli goruntu: (x, y) noktasinin kirmizi degeri (koyu temada gri tonu).
    function Red([double] $x, [double] $y) {
        $r = New-Object MenuW32+RECT; [void][MenuW32]::GetWindowRect($h, [ref]$r)
        $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
        $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
        [void][MenuW32]::PrintWindow($h, $hdc, 2)
        $g.ReleaseHdc($hdc); $g.Dispose()
        $v = $bmp.GetPixel([int]($x * $s), [int]($y * $s)).R
        $bmp.Dispose()
        return $v
    }
    # Tikladiktan sonra `ms` boyunca bir noktanin degerleri (animasyonun ara kareleri).
    function Watch([double] $x, [double] $y, [int] $ms) {
        $sw = [Diagnostics.Stopwatch]::StartNew(); $vals = @()
        while ($sw.ElapsedMilliseconds -lt $ms) { $vals += (Red $x $y) }
        return $vals
    }
    # Mesajlari gonderir ama beklemez (animasyonu izlemek icin).
    function Press([double] $x, [double] $y) {
        $l = [IntPtr](([int]($y * $s) -shl 16) -bor [int]($x * $s))
        [void][MenuW32]::PostMessage($h, 0x0200, [IntPtr]::Zero, $l)
        [void][MenuW32]::PostMessage($h, 0x0201, [IntPtr]1, $l)
        [void][MenuW32]::PostMessage($h, 0x0202, [IntPtr]::Zero, $l)
    }
    function Same($a, $b) { return [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B) -lt 12 }

    $windows = [MenuW32]::VisibleWindows([uint32]$p.Id)
    $homeShot = Shot "home-menu-0-home"
    # Menunun kaplayacagi bos zemin (Yontem menusu x 138-378, y 128-528) ve hic kaplanmayan bir nokta.
    $bg = Px $homeShot 300 150
    $free = Px $homeShot 60 150

    Write-Host "Yontem menusu"
    # Acilis: menu bir anda belirmez; zemin rengi kareler boyunca kademe kademe menu rengine gecer.
    $bg0 = (Px $homeShot 300 150).R
    Press 200 554
    $vals = Watch 300 150 400
    $final = $vals[-1]
    $mid = @($vals | Where-Object { $_ -gt $bg0 + 3 -and $_ -lt $final - 3 }).Count
    Write-Host "    acilis kareleri: $($vals -join ',')"
    Check "menu solarak acildi ($mid ara kare)" ($mid -ge 1 -and $final -gt $bg0 + 20)
    Start-Sleep -Milliseconds 200
    $open = Shot "home-menu-1-method"
    Check "menu acildi (bos zemin menuyle kaplandi)" (-not (Same (Px $open 300 150) $bg))
    Check "menu disindaki yer degismedi" (Same (Px $open 60 150) $free)
    Check "menu ayri pencere degil" ([MenuW32]::VisibleWindows([uint32]$p.Id) -eq $windows)
    Check "menu acilinca ayar gonderilmedi" ($svc.ConfigCount() -eq 0)
    # Ucuncu oge: Genel saglayicinin ucuncu onerisi "Ters sira" (disorder). Menu y 128'de;
    # once "ONERILEN" basligi (26 px), ogeler 34 px.
    Press 250 244
    # Secince isaret cizilirken menu acik kalir, sonra soner (bir anda kaybolmaz).
    $vals = Watch 300 150 500
    $mid = @($vals | Where-Object { $_ -gt $bg0 + 3 -and $_ -lt $final - 3 }).Count
    Write-Host "    kapanis kareleri: $($vals -join ',')"
    Check "secimden sonra menu solarak kapandi ($mid ara kare)" ($mid -ge 1 -and $vals[0] -ge $final - 3 -and $vals[-1] -le $bg0 + 3)
    for ($i = 0; $i -lt 20 -and $svc.ConfigCount() -lt 1; $i++) { Start-Sleep -Milliseconds 100 }
    Check "secim tek istekle gitti" ($svc.ConfigCount() -eq 1)
    if ($svc.ConfigCount() -ge 1) { Check "yontem Ters sira (disorder)" ($svc.Config(0) -match '"method":"disorder"') }
    $closed = Shot "home-menu-2-picked"
    Check "secince menu kapandi" (Same (Px $closed 300 150) $bg)

    Write-Host "DNS menusu"
    Click 200 598
    $dns = Shot "home-menu-3-dns"
    # DNS menusu 9 oge ve "Kapali"dan sonra ince cizgi (9 px): y 247-572; ilk oge "Kapali".
    Check "DNS menusu acildi" (-not (Same (Px $dns 300 300) (Px $homeShot 300 300)))
    Click 250 269
    for ($i = 0; $i -lt 20 -and $svc.ConfigCount() -lt 2; $i++) { Start-Sleep -Milliseconds 100 }
    Check "DNS secimi tek istekle gitti" ($svc.ConfigCount() -eq 2)
    if ($svc.ConfigCount() -ge 2) { Check "DNS kapatildi" ($svc.Config(1) -match '"dns":\{"mode":"off"') }

    Write-Host "Disari tiklamak"
    Click 200 554
    Click 60 26
    $after = Shot "home-menu-4-dismissed"
    Check "disari tiklayinca menu secmeden kapandi" ((Same (Px $after 300 150) $bg) -and $svc.ConfigCount() -eq 2)

    Write-Host "Saglayici menusu"
    # En ustteki satir (y 488-532); 9 saglayici: menu y 168-484, ikinci oge Turk Telekom.
    Click 200 510
    $isp = Shot "home-menu-5-isp"
    Check "saglayici menusu acildi" (-not (Same (Px $isp 300 200) (Px $homeShot 300 200)))
    Click 250 224
    for ($i = 0; $i -lt 20 -and $svc.ConfigCount() -lt 3; $i++) { Start-Sleep -Milliseconds 100 }
    Check "saglayici secimi tek istekle gitti" ($svc.ConfigCount() -eq 3)
    if ($svc.ConfigCount() -ge 3) {
        Check "saglayici Turk Telekom, onerdigi yontemle (disorder)" ($svc.Config(2) -match '"isp":"turktelekom","method":"disorder"')
    }
    Check "pencere acik" (-not $p.HasExited)
    Write-Host "  goruntuler: $OutDir\home-menu-*.png"
}
finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    $svc.Close()
    Remove-Item Env:GDPI3_TEST, Env:GDPI3_INSTANCE, Env:GDPI3_PIPE -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { Write-Host "$failed kontrol basarisiz"; exit 1 }
Write-Host "Tum kontroller gecti"
