# `codex-sshfs-mount.ps1` — Windows 10/11 (SSHFS-Win)

Это PowerShell-оболочка для *прямого системного монтирования* удалённых хостов через **SSHFS-Win** (на базе WinFsp), чтобы удалённая папка была видна как обычная локальная директория рядом со скриптом (удобно для Codex и других CLI/IDE).

Список хостов берётся из плагина **SSH FS** в VS Code: хосты добавляются в настройку `sshfs.configs` внутри `settings.json`.

## Зависимости

Обязательно:
- Windows 10/11
- VS Code + установленный плагин **SSH FS** (в нём должны быть добавлены хосты)
- PowerShell 5.1+ или PowerShell 7+
- **WinFsp**
- **SSHFS-Win** (даёт `sshfs.exe`; нужен в `PATH` или укажи путь через `-SshfsPath` / `SSHFS_EXE`)

## Установка

### Через winget (если доступен)
```powershell
winget install WinFsp.WinFsp
winget install SSHFS-Win.SSHFS-Win
```

### Через Chocolatey (если используешь)
```powershell
choco install -y winfsp sshfs-win
```

Проверка:
```powershell
Get-Command sshfs
```

Если `Get-Command sshfs` ничего не выводит (а SSHFS-Win установлен):
- Найди бинарник: `where sshfs` (cmd) или в типичных местах вроде `C:\Program Files\SSHFS-Win\bin\sshfs.exe`
- Запусти скрипт с явным путём:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -SshfsPath "C:\Program Files\SSHFS-Win\bin\sshfs.exe"
  ```
  или задай переменную окружения (пример):
  ```powershell
  setx SSHFS_EXE "C:\Program Files\SSHFS-Win\bin\sshfs.exe"
  ```

## Запуск

Из папки, где лежит скрипт:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1
```

При запуске скрипт:
1) читает `sshfs.configs` из VS Code,
2) печатает список `1) ...`, `2) ...`,
3) просит `Select host number`,
4) после ввода номера — монтирует выбранный хост.

Выбор без интерактива:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select 1
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "example-host"
```

Показать команду без выполнения:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "example-host" -DryRun
```

## Unmount

Размонтировать выбранный хост:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "example-host" -Unmount
```

## Где берётся `settings.json`

- Можно явно: `-SettingsPath PATH` или переменная `VSCODE_SETTINGS`.
- Автодетект (по `%APPDATA%`):
  - `%APPDATA%\Code\User\settings.json` (и варианты Insiders/VSCodium)

## Keepalive / опции

По умолчанию:
- `reconnect`
- `ServerAliveInterval=15`
- `ServerAliveCountMax=3`
- `TCPKeepAlive=yes`

Переопределение:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Interval 10 -Count 5
```

Доп. опции:
- через переменную окружения `SSHFS_EXTRA_OPTS` (comma-separated)

## Примечания

- Скрипт сначала пытается смонтировать в каталог `.\<host-name>\`. Если конкретная сборка SSHFS-Win не поддерживает directory mount — скрипт автоматически пробует монтирование в свободную букву диска и создаёт junction `.\<host-name>\ -> X:\`.
