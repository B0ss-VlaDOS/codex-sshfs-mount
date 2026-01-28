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

