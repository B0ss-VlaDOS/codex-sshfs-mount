# `codex-sshfs-mount.ps1` — Windows 10/11 (SSHFS-Win)

Это PowerShell-оболочка для *прямого системного монтирования* удалённых хостов через **SSHFS-Win** (на базе WinFsp), чтобы удалённая папка была видна как обычная локальная директория рядом со скриптом (удобно для Codex и других CLI/IDE).

Список хостов берётся из плагина **SSH FS** в VS Code: хосты добавляются в настройку `sshfs.configs` внутри `settings.json`.

## Зависимости

Обязательно:
- Windows 10/11
- VS Code + установленный плагин **SSH FS** (в нём должны быть добавлены хосты)
- PowerShell 5.1+ или PowerShell 7+
- **WinFsp**
- **SSHFS-Win** (даёт `sshfs-win.exe`; нужен в `PATH` или укажите путь через `-SshfsPath` / `SSHFS_EXE`)

## Установка

### Через winget (если доступен)
```powershell
winget install WinFsp.WinFsp
winget install SSHFS-Win.SSHFS-Win
```

### Через Chocolatey (если Вы используете)
```powershell
choco install -y winfsp sshfs-win
```

Проверка:
```powershell
Get-Command sshfs-win
```

Важно: после установки WinFsp/SSHFS-Win **закройте и заново откройте терминал и VS Code**. Если `sshfs-win` всё равно не находится — выполните **выключение и включение Windows** (полное Shut down → Power on), а не Restart.

Если `Get-Command sshfs-win` ничего не выводит (а SSHFS-Win установлен):
- Найдите бинарник: `where sshfs-win` (cmd) или в типичных местах вроде `C:\Program Files\SSHFS-Win\bin\sshfs-win.exe`
- Запустите скрипт с явным путём:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -SshfsPath "C:\Program Files\SSHFS-Win\bin\sshfs-win.exe"
  ```
  или задайте переменную окружения (пример):
  ```powershell
  setx SSHFS_EXE "C:\Program Files\SSHFS-Win\bin\sshfs-win.exe"
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

Примечание:
- Скрипт хранит state-файл рядом с собой: `.codex-sshfs-<host-name>.json` (в т.ч. букву диска и UNC provider вида `\\sshfs\...`).
- При `-Unmount` он старается **не удалить чужой** диск, если буква уже переиспользована (проверяет provider; при необходимости ищет актуальную букву по provider).

## Где берётся `settings.json`

- Можно явно: `-SettingsPath PATH` или переменная `VSCODE_SETTINGS`.
- Автодетект (по `%APPDATA%`):
  - `%APPDATA%\Code\User\settings.json` (и варианты Insiders/VSCodium)

## Keepalive / опции

По умолчанию:
- `ServerAliveInterval=15`
- `ServerAliveCountMax=3`
- `StrictHostKeyChecking=no`
- `UserKnownHostsFile=/dev/null`

Если в `sshfs.configs` указан `password` строкой, скрипт также пробует использовать `password_stdin`, чтобы подключение прошло без интерактивного ввода пароля.

Переопределение:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Interval 10 -Count 5
```

Доп. опции:
- через переменную окружения `SSHFS_EXTRA_OPTS` (comma-separated)

## Примечания

- Скрипт монтирует в свободную букву диска и создаёт junction `.\<host-name>\ -> X:\` (так надёжнее с WinFsp).
- Для первого подключения к хосту скрипт отключает интерактивный вопрос `yes/no` про known hosts через `StrictHostKeyChecking=no` и `UserKnownHostsFile=/dev/null`. При необходимости Вы можете переопределить это через `SSHFS_EXTRA_OPTS` (например, `StrictHostKeyChecking=accept-new` или `StrictHostKeyChecking=yes`).
- Если `password` задан как boolean (секрет хранится вне `settings.json`) — скрипт не сможет извлечь пароль и может запросить его при подключении.
