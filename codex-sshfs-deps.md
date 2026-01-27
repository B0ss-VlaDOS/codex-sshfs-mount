# Установка зависимостей для `codex-sshfs-mount.*`

Ниже — минимальные шаги, чтобы заработали скрипты:
- macOS/Linux: `codex-sshfs-mount.sh`
- Windows 10/11: `codex-sshfs-mount.ps1`

## Общие требования (везде)

1) **VS Code**
2) **Плагин VS Code: SSH FS**
   - Установи расширение **SSH FS**
   - Добавь хосты в настройку `sshfs.configs` (в `settings.json` VS Code)

Проверка, что хосты видны скрипту:
- macOS/Linux: запусти `./codex-sshfs-mount.sh` и убедись, что выводится список `1) ...`
- Windows: запусти `powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1` и убедись, что выводится список `1) ...`

---

## macOS (для `codex-sshfs-mount.sh`)

### 1) Homebrew (если ещё нет)
Поставь Homebrew с официального сайта Homebrew.

### 2) macFUSE (обязательно)
```sh
brew install --cask macfuse
```

После установки:
- `System Settings` → `Privacy & Security` → нажми `Allow` для macFUSE system extension
- Перезагрузи Mac, если система попросит

Проверка:
```sh
ls -ld /Library/Filesystems/macfuse.fs
```

### 3) sshfs (через sshfs-mac)
```sh
brew install gromgit/fuse/sshfs-mac
```

Проверка:
```sh
command -v sshfs
```

---

## Linux (для `codex-sshfs-mount.sh`)

Нужно: `bash`, `awk`, `sshfs`.

Debian/Ubuntu:
```sh
sudo apt-get update && sudo apt-get install -y sshfs
```

Fedora/RHEL:
```sh
sudo dnf install -y sshfs
```

Arch:
```sh
sudo pacman -Sy --noconfirm sshfs
```

openSUSE:
```sh
sudo zypper install -y sshfs
```

Проверка:
```sh
command -v sshfs
```

---

## Windows 10/11 (для `codex-sshfs-mount.ps1`)

На Windows `sshfs.exe` **не встроен** — он появляется после установки **WinFsp** и **SSHFS-Win**.

### Вариант A: winget (рекомендуется)
```powershell
winget install WinFsp.WinFsp
winget install SSHFS-Win.SSHFS-Win
```

### Вариант B: Chocolatey
```powershell
choco install -y winfsp sshfs-win
```

Проверка:
```powershell
Get-Command sshfs
```

Если `sshfs` не находится:
- перезапусти терминал (чтобы обновился PATH),
- проверь `where sshfs` (cmd) или `Get-Command sshfs` (PowerShell).

