# codex-sshfs-mount (v1.2)

Два скрипта, которые берут хосты из расширения **SSH FS** для VS Code (`sshfs.configs` в `settings.json`) и делают *системное монтирование* удалённого хоста, чтобы он был виден как обычная локальная папка/диск для CLI/IDE (в т.ч. Codex).

## Скрипты

### `codex-sshfs-mount.sh` (macOS/Linux)

- Монтирует выбранный хост через `sshfs` в папку рядом со скриптом: `./<host-name>/`.
- Работает с `settings.json` в формате JSON/JSONC (комментарии/висячие запятые).
- Поддерживает `sshfs.configpaths` (дополнительные файлы конфигов).

Документация: `codex-sshfs-mount.md`.

### `codex-sshfs-mount.ps1` (Windows 10/11)

- Монтирует выбранный хост через **SSHFS-Win** как отдельный диск (буква `X:`).
- Для удобства создаёт junction рядом со скриптом: `.\<host-name>\ -> X:\`.
- Диск можно отключать в Проводнике или через `-Unmount`.
- В VS Code обычно нужно открывать диск (`X:\`) как директорию проекта (или junction-папку рядом со скриптом).

Документация: `codex-sshfs-mount-windows.md`.

## Зависимости

- `codex-sshfs-mount.sh`: `bash`, `awk`, `sshfs` (на macOS ещё нужен `macFUSE`).
- `codex-sshfs-mount.ps1`: WinFsp + SSHFS-Win (`sshfs-win.exe`), PowerShell 5.1+/7+.

Подробно: `codex-sshfs-deps.md`.

## Быстрый старт

macOS/Linux:
```sh
./codex-sshfs-mount.sh
```

Windows:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1
```

## Windows: полный цикл (с нуля)

### 1) Установите расширение SSH FS в VS Code

1. Установите VS Code.
2. Откройте Extensions (`Ctrl+Shift+X`) и установите расширение **SSH FS** (Kelvin Schoofs).
3. Альтернатива: `Ctrl+P` → вставьте команду `ext install Kelvin.vscode-sshfs` → Enter.

### 2) Добавьте новый SSH FS host (sshfs.configs)

Добавляйте хост **через GUI/команды расширения SSH FS** (расширение само сохранит конфиг в `sshfs.configs`).

1. Откройте Command Palette: `Ctrl+Shift+P`.
2. Запустите команду SSH FS для добавления нового хоста (например `SSH FS: Add Host` / `SSH FS: Add New Host`) и заполните поля:
   - `name`/`label` — короткое имя (по нему вы выбираете хост **и в плагине, и в нашем скрипте**: `-Select "{имя хоста}"`),
   - `host` — домен/IP,
   - `port` — обычно `22`,
   - `username` — пользователь на сервере,
   - `root` — **путь до корня сайта на сервере** (например `/var/www/site`, `/home/user/www`, и т.п.).
   - `password` - пароль

Примечания:
- Рекомендуется ключевая аутентификация: укажите `privateKeyPath` (в UI расширения или в `sshfs.configs`) и держите ключ в `~/.ssh/`.

### 3) Установите WinFsp + SSHFS-Win

Рекомендуемый вариант (winget):
```powershell
winget install WinFsp.WinFsp
winget install SSHFS-Win.SSHFS-Win
```

Проверка:
```powershell
Get-Command sshfs-win
```

После установки закройте/откройте терминал и VS Code (иногда помогает полное выключение/включение Windows).

### 4) Смонтируйте хост нашим скриптом

Дефолтный вариант (интерактивно: скрипт покажет список и попросит выбрать номер хоста):
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1
```

Из папки репозитория без интерактива (выбор по имени хоста из SSH FS):
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "{имя хоста}"
```

Опционально — выбрать букву диска:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "{имя хоста}" -DriveLetter X
```

Что получится:
- будет создан отдельный диск (`X:` или другая свободная буква),
- рядом со скриптом появится junction `.\{имя хоста}\ -> X:\` (для удобства).

### 5) Откройте проект в VS Code

В VS Code откройте папку проекта как:
- диск (`X:\`) **или**
- junction-папку рядом со скриптом (`.\{имя хоста}\`).

### 6) Размонтирование

Через наш скрипт:
```powershell
powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -Select "{имя хоста}" -Unmount
```

Или через Проводник: отключите/извлеките соответствующий диск.

## macOS/Linux: полный цикл (с нуля)

### 1) Установите расширение SSH FS в VS Code

1. Установите VS Code.
2. Откройте Extensions и установите расширение **SSH FS** (Kelvin Schoofs).

### 2) Добавьте новый SSH FS host (sshfs.configs)

Добавляйте хост через GUI/команды расширения SSH FS — расширение сохранит конфиг в `sshfs.configs` внутри `settings.json`.

Важные поля:
- `name`/`label` — имя хоста (по нему выбираете хост **и в плагине, и в нашем скрипте**: `--select "my-host"`),
- `host` — домен/IP,
- `port` — обычно `22`,
- `username` — пользователь на сервере,
- `root` — путь до нужной директории на сервере (часто корень проекта/сайта).

### 3) Установите зависимости (FUSE + sshfs)

macOS:
```sh
brew install --cask macfuse
brew install gromgit/fuse/sshfs-mac
```

Linux (примеры):
```sh
sudo apt-get update && sudo apt-get install -y sshfs
# или: sudo dnf install -y sshfs
```

Проверка:
```sh
command -v sshfs
```

### 4) Смонтируйте хост нашим скриптом

Дефолтный вариант (интерактивно: скрипт покажет список и попросит выбрать номер хоста):
```sh
./codex-sshfs-mount.sh
```

Без интерактива (выбор по имени хоста из SSH FS):
```sh
./codex-sshfs-mount.sh --select "{имя хоста}"
```

Что получится:
- будет создана папка рядом со скриптом: `./{имя хоста}/`,
- в неё будет смонтирован удалённый путь (SSHFS).

### 5) Откройте проект в VS Code

Откройте папку `./{имя хоста}/` как директорию проекта.

### 6) Размонтирование

Через наш скрипт:
```sh
./codex-sshfs-mount.sh --select "{имя хоста}" --unmount
```

## Баги, исправленные до v1.2

### Общие / `settings.json`
- Исправлен разбор VS Code `settings.json` как JSONC: корректно игнорируются `//` и `/* */` комментарии и “висячие” запятые.
- Добавлена поддержка `sshfs.configpaths` (подхват дополнительных файлов конфигов).
- Добавлен авто-поиск `settings.json` (для macOS/Linux/Windows) и возможность явно задать путь через `VSCODE_SETTINGS`/`--settings`/`-SettingsPath`.

### `codex-sshfs-mount.sh`
- Исправлен запуск через `sh …`: скрипт сам переисполняется под `bash` (иначе ломались bash-конструкции).
- Улучшены проверки зависимостей и сообщения об установке (в т.ч. macFUSE/sshfs-mac на macOS).
- `--dry-run` не печатает пароли/секреты и позволяет проверить команду без монтирования.

### `codex-sshfs-mount.ps1`
- Исправлена ошибка `sshfs-win svc`, когда при передаче `-o ...` без `LOCUSER` аргументы могли смещаться (и `-o` воспринимался как `LOCUSER`).
- Исправлены проблемы идемпотентности: корректная работа с state-файлом и восстановление junction при “уже смонтировано”.
- Сделан безопасный `-Unmount`: защита от ситуации, когда буква диска из state переиспользована (проверка по `ProviderName` вида `\\sshfs\...`, поиск актуальной буквы по provider).
- Улучшены подсказки/поиск `sshfs-win.exe` и поведение `-DryRun`.
