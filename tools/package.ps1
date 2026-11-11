# Builds dist\SDCoop_<version>.zip: UE4SS + the SDCoop mod, ready to unzip into
# the game folder (...\steamapps\common\SurrounDead). Takes UE4SS from the local
# game install, the mod from mods\SDCoop\scripts, the Steam join helper
# (Mods\SDCoop\steamlink\SDCoopSteamLink.exe) built from tools\steamlink with
# tools\steamlink\build.ps1. No logs, dumps, debug files or developer mods go
# into the archive.
# -Scripts <dir>: package another scripts folder (a checked snapshot) instead.
# -Public: the archive for GitHub releases (dist\public\): normal log level
#          (debug off), the README says how to turn the detailed log on.
# -GameWin64 <dir>: the game's Binaries\Win64 with UE4SS installed.
param([string]$Scripts = "", [switch]$Public,
      [string]$GameWin64 = "C:\Program Files (x86)\Steam\steamapps\common\SurrounDead\SurrounDead\Binaries\Win64")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$gameWin64 = $GameWin64
$scripts = if ($Scripts) { $Scripts } else { Join-Path $root "mods\SDCoop\scripts" }

$main = Get-Content (Join-Path $scripts "main.lua") -Raw
if ($main -notmatch 'local VERSION = "([^"]+)"') { throw "VERSION not found in main.lua" }
$version = $Matches[1]

$outDir = if ($Public) { Join-Path $root "dist\public" } else { Join-Path $root "dist" }
New-Item -ItemType Directory -Force $outDir | Out-Null
$stage = Join-Path $root ("dist\stage\SDCoop_$version" + $(if ($Public) { "_public" } else { "" }))
$zip = Join-Path $outDir "SDCoop_$version.zip"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$win64 = Join-Path $stage "SurrounDead\Binaries\Win64"
$ue4ss = Join-Path $win64 "ue4ss"
$mods = Join-Path $ue4ss "Mods"
New-Item -ItemType Directory -Force (Join-Path $mods "SDCoop\scripts") | Out-Null

# UE4SS itself (proxy dll, core, license, shared Lua libs, built-in keybinds mod)
Copy-Item (Join-Path $gameWin64 "dwmapi.dll") $win64
foreach ($f in "UE4SS.dll", "LICENSE") { Copy-Item (Join-Path $gameWin64 "ue4ss\$f") $ue4ss }
Copy-Item (Join-Path $gameWin64 "ue4ss\Mods\shared") $mods -Recurse
Copy-Item (Join-Path $gameWin64 "ue4ss\Mods\Keybinds") $mods -Recurse

# settings: no console windows for players
$settings = Get-Content (Join-Path $gameWin64 "ue4ss\UE4SS-settings.ini")
$settings = $settings -replace '^ConsoleEnabled\s*=.*', 'ConsoleEnabled = 0' `
                      -replace '^GuiConsoleEnabled\s*=.*', 'GuiConsoleEnabled = 0' `
                      -replace '^GuiConsoleVisible\s*=.*', 'GuiConsoleVisible = 0' `
                      -replace '^FullMemoryDump\s*=.*', 'FullMemoryDump = 0'   # the host may debug with full dumps (GBs each)
Set-Content -Path (Join-Path $ue4ss "UE4SS-settings.ini") -Value $settings -Encoding UTF8

Set-Content -Path (Join-Path $mods "mods.txt") -Value @(
    "SDCoop : 1",
    "",
    "; Built-in keybinds, do not move up!",
    "Keybinds : 1") -Encoding ASCII

# the mod: every script, an empty config (all defaults), enabled marker
Copy-Item (Join-Path $scripts "*.lua") (Join-Path $mods "SDCoop\scripts")
$debugLine = if ($Public) {
    @("; debug = true: a detailed UE4SS.log for a bug report (a bit slower)", "debug = false")
} else {
    @("; debug = true while we test together: detailed UE4SS.log for bug reports", "debug = true")
}
Set-Content -Path (Join-Path $mods "SDCoop\config.ini") -Value (@(
    "; SDCoop settings (all others use their defaults; the F7 menu writes this file)") + $debugLine + @(
    "; UE4SS.log written in batches (at most once a second): a slow log write stalled a client's game for seconds",
    "log_batch_always = true")) -Encoding UTF8
Set-Content -Path (Join-Path $mods "SDCoop\enabled.txt") -Value "" -Encoding ASCII

# Steam join helper (tools\steamlink, C# for .NET Framework 4): built fresh
# into the stage; the copy in mods\SDCoop\steamlink only when csc.exe fails.
# Only the exe goes in - never its status / friends / log files.
$steamlinkOut = Join-Path $mods "SDCoop\steamlink"
$built = $false
try {
    & (Join-Path $PSScriptRoot "steamlink\build.ps1") -Out $steamlinkOut | Out-Host
    $built = Test-Path (Join-Path $steamlinkOut "SDCoopSteamLink.exe")
} catch {
    Write-Warning "steamlink build failed: $_"
}
if (-not $built) {
    $prebuilt = Join-Path $root "mods\SDCoop\steamlink\SDCoopSteamLink.exe"
    if (-not (Test-Path $prebuilt)) { throw "SDCoopSteamLink.exe: build failed and no prebuilt copy in $prebuilt" }
    New-Item -ItemType Directory -Force $steamlinkOut | Out-Null
    Copy-Item $prebuilt $steamlinkOut
    Write-Warning "steamlink: packaged the prebuilt $prebuilt"
}

$readme = @"
SDCoop $version — кооператив для SurrounDead (мод на UE4SS)

УСТАНОВКА
1. Steam -> SurrounDead -> Управление -> Просмотреть локальные файлы.
   Откроется папка ...\steamapps\common\SurrounDead
2. Распакуйте архив в эту папку с заменой. Должны появиться
   SurrounDead\Binaries\Win64\dwmapi.dll и папка SurrounDead\Binaries\Win64\ue4ss
3. Запустите игру как обычно.
Удаление: удалите dwmapi.dll и папку ue4ss из SurrounDead\Binaries\Win64.
Версия мода у всех игроков должна быть одинаковой.

ВАЖНО: не ставьте вместе с другими модами, которые приносят свой UE4SS
(например SurrounDeadMP / MPFix). Их установщик перезаписывает dwmapi.dll и
mods.txt — после этого SDCoop молча перестаёт загружаться, а их удаление
стирает папку Mods. Если такой мод стоял: удалите SurrounDead\Binaries\Win64\UE4SS.dll,
папку Win64\Mods и распакуйте этот архив заново.

ПЕРВЫЙ ЗАПУСК: только самый первый запуск через Steam после установки мода —
мод дописывает в настройки игры одну строку (Engine.ini: bUseSteamNetworking=False,
игра ходит в сеть через обычный UDP) и просит перезапустить игру ОДИН раз.
Эту настройку игра читает только при старте, поэтому без перезапуска нельзя.
Если мод уже стоял (версия 0.6.12 и новее) — перезапуск не нужен.

КАК ИГРАТЬ ЧЕРЕЗ STEAM (без IP, VPN и проброса портов)
Хост и друг должны быть друзьями в Steam; версия мода у всех одна.
1. Хост: загрузите сохранение или начните новую игру как обычно (мир сам
   открывается для друзей; если нет — главное меню -> «Кооператив» ->
   «Открыть мир для друзей»). Справа появится «Друзья в Steam могут подключиться».
2. Друг: Steam -> список друзей -> правый клик по хосту -> «Присоединиться к игре».
   Игра запустится (или, если уже запущена, подключится из главного меню сама).
   Другие способы: хост приглашает через оверлей Steam (Shift+Tab -> пригласить)
   или кнопкой «Пригласить друга» на вкладке Steam панели «Кооператив»;
   или друг: главное меню -> «Кооператив» -> вкладка Steam -> хост в списке
   «Друзья в SurrounDead» -> «Подключиться».
3. Если хост ещё в главном меню, подключение ждёт до 2 минут, пока он загрузит мир.
Как это работает: вместе с игрой запускается помощник
SurrounDead\Binaries\Win64\ue4ss\Mods\SDCoop\steamlink\SDCoopSteamLink.exe
(при старте игры на долю секунды мелькнёт чёрное окно) и закрывается вместе с ней.
Он передаёт сетевой трафик игры через сеть Steam.
Подключиться к хосту могут только его друзья в Steam (настройка steam_link_friends_only;
другим игрокам хост может разрешить вход списком их кодов Steam в steam_link_allow).
Windows может один раз спросить, разрешить ли SDCoopSteamLink.exe доступ к сети:
лучше разрешить (прямое соединение быстрее); при отказе связь идёт через серверы Steam.
АНТИВИРУС: помощник — небольшая программа без цифровой подписи, которая работает
с сетью; антивирус может удалить её или спросить разрешение. Тогда разрешите или
добавьте папку игры в исключения и распакуйте архив заново. Без помощника
подключение через Steam не работает (по IP — работает). Исходный код помощника:
github.com/Chepchek/SurrounDead-Coop (папка tools/steamlink).

КАК ИГРАТЬ ПО IP (если через Steam не выходит: Radmin VPN, ZeroTier или проброс порта)
1. Оба ставят Radmin VPN (или ZeroTier) и входят в одну сеть.
2. Хосту — один раз разрешить игре входящие подключения в брандмауэре Windows:
   PowerShell ОТ ИМЕНИ АДМИНИСТРАТОРА и команда (одной строкой):
   New-NetFirewallRule -DisplayName "SurrounDead co-op (UDP)" -Direction Inbound -Program "<папка игры>\SurrounDead\Binaries\Win64\SurrounDead-Win64-Shipping.exe" -Protocol UDP -Action Allow -Profile Any
   (или: Панель управления -> Брандмауэр -> Разрешить приложение -> добавить этот exe,
   галочки «Частная» и «Публичная»).
3. Хост: главное меню -> «Кооператив» -> «Открыть мир для друзей»,
   затем загрузите сохранение / новую игру как обычно.
4. Клиент: главное меню -> «Кооператив» -> вкладка «По IP» -> в поле «IP хоста»
   впишите IP хоста из Radmin VPN (вида 26.x.x.x), порт 7777 -> «Подключиться».
С пробросом UDP-порта 7777 на роутере хоста вместо Radmin подойдёт внешний IP хоста.
Персонаж: при первом подключении у клиента открывается редактор персонажа игры
        (как для новой игры); после «Продолжить» начинается подключение.
        Поменять внешность: главное меню -> «Кооператив» -> вкладка «Персонаж» ->
        «Изменить внешность».

СОХРАНЕНИЯ
Перед открытием мира мод копирует сохранения хоста в
%LOCALAPPDATA%\SurrounDead\Saved\SDCoop_Backups\<дата-время>.
У клиента во время игры по сети его собственные сохранения не трогаются.

ЕСЛИ ЧТО-ТО НЕ ТАК
В панели «Кооператив» внизу есть «Сообщить об ошибке»: там кнопка «Открыть папку
с логом» и подсказка, что написать.
Пришлите файл SurrounDead\Binaries\Win64\ue4ss\UE4SS.log сразу после проблемы
(до следующего запуска игры — он перезаписывается), а при проблемах с Steam —
ещё и ...\ue4ss\Mods\SDCoop\steamlink\helper_log.txt (в нём нет имён, только
коды Steam для соединений).
$(if ($Public) { @"
Для подробного лога поставьте debug = true в Mods\SDCoop\config.ini (при
закрытой игре) и повторите проблему. Баги и логи: github.com/Chepchek/SurrounDead-Coop/issues
"@ } else { @"
Подробный лог уже включён (debug = true в Mods\SDCoop\config.ini); если игра
тормозит — поставьте debug = false.
"@ })
Раз в 30 секунд в лог пишется снимок состояния ([SNAP]): персонаж, здоровье,
HUD, управление, пинг, зомби рядом.
"@
Set-Content -Path (Join-Path $stage "README_SDCoop.txt") -Value $readme -Encoding UTF8

if (Test-Path $zip) { Remove-Item $zip -Force }
# .NET's ZipFile writes '/' in entry names (Compress-Archive in PowerShell 5
# writes '\', which some unpackers turn into odd file names)
[AppContext]::SetSwitch("Switch.System.IO.Compression.ZipFile.UseBackslash", $false)
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
"package: $zip ($size MB)"
