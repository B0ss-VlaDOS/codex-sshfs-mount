# `codex-sshfs-mount.sh` — VS Code SSH FS → system sshfs mount

Это оболочка для `sshfs`, которая берёт хосты из плагина **SSH FS** в VS Code и делает *прямое монтирование в систему* (mountpoint рядом со скриптом). Удобно, когда нужно, чтобы локальные инструменты (в т.ч. Codex) видели удалённый проект как обычную папку.

Скрипт читает список хостов из `settings.json` VS Code (`sshfs.configs` и опционально `sshfs.configpaths`), выводит список с номерами и монтирует выбранный хост в папку рядом со скриптом: `./<host-name>/`.

## Зависимости

Обязательно:
- VS Code + установленный плагин **SSH FS** (в нём должны быть добавлены хосты).
- `bash` (скрипт использует bash-совместимые конструкции).
- `awk` (парсинг `settings.json`/JSONC без python/jq/node).
- `sshfs` (сама утилита монтирования по SSH).

Дополнительно:
- macOS: `macFUSE` (драйвер FUSE) + `sshfs` (обычно через `sshfs-mac`).
- Linux: пакет `sshfs` (часто тянет FUSE как зависимость; в некоторых дистрибутивах нужен `fuse3`/`libfuse`).

## Установка зависимостей

### macOS
1) `macFUSE`:
```sh
brew install --cask macfuse
```
2) Разрешить system extension (System Settings → Privacy & Security → Allow) и при необходимости перезагрузи Mac.
3) `sshfs` (через `sshfs-mac`):
```sh
brew install gromgit/fuse/sshfs-mac
```
Проверка:
```sh
command -v sshfs
```

### Linux
Debian/Ubuntu:
```sh
sudo apt-get update && sudo apt-get install -y sshfs
```
Fedora:
```sh
sudo dnf install -y sshfs
```
Arch:
```sh
sudo pacman -Sy --noconfirm sshfs
```

## Запуск

Из папки, где лежит скрипт (интерактивный режим):
```sh
sh codex-sshfs-mount.sh
```

При запуске скрипт:
1) читает `sshfs.configs` из VS Code,
2) печатает список вида `1) ...`, `2) ...`,
3) просит `Select host number:`,
4) после ввода номера — монтирует выбранный хост.

Выбор без интерактива (по номеру или по имени из SSH FS):
```sh
./codex-sshfs-mount.sh --select 43
./codex-sshfs-mount.sh --select "имя хоста"
```

Показать команду без выполнения:
```sh
./codex-sshfs-mount.sh --select "имя хоста" --dry-run
```

Если уже смонтировано — перемонтировать:
```sh
./codex-sshfs-mount.sh --select "имя хоста" --force
```

## Unmount

Размонтировать выбранный хост:
```sh
./codex-sshfs-mount.sh --select "имя хоста" --unmount
```

Проверка “что сделает”:
```sh
./codex-sshfs-mount.sh --select "имя хоста" --unmount --dry-run
```

## Где берётся `settings.json`

- Можно явно: `--settings PATH` или переменная `VSCODE_SETTINGS`.
- Автодетект:
  - macOS: `~/Library/Application Support/Code/User/settings.json` (и варианты Insiders/VSCodium)
  - Linux: `${XDG_CONFIG_HOME:-~/.config}/Code/User/settings.json` (и варианты Insiders/VSCodium)

## Тюнинг keepalive

По умолчанию включены:
- `reconnect`
- `ServerAliveInterval=15`
- `ServerAliveCountMax=3`
- `TCPKeepAlive=yes`

Переопределение:
```sh
./codex-sshfs-mount.sh --interval 10 --count 5
```

Доп. опции sshfs:
```sh
SSHFS_EXTRA_OPTS="volname=myremote,follow_symlinks" ./codex-sshfs-mount.sh --select 1
```

## Troubleshooting

- `fuse: failed to exec mount program: Operation not permitted` (macOS): чаще всего не разрешён/не загружен macFUSE system extension, либо запуск идёт из ограниченной sandbox-среды.
- Если VS Code хранит пароли в `settings.json` — помни, что это чувствительные данные (лучше ключи/agent, где возможно).
