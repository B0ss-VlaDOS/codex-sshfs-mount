# Установка зависимостей для `codex-sshfs-mount.*`

Ниже — минимальные шаги, чтобы заработали скрипты:
- macOS/Linux: `codex-sshfs-mount.sh`
- Windows 10/11: `codex-sshfs-mount.ps1`

## Общие требования (везде)

1) **VS Code**
2) **Плагин VS Code: SSH FS**
   - Установите расширение **SSH FS**
   - Добавьте хосты в настройку `sshfs.configs` (в `settings.json` VS Code)

Проверка, что хосты видны скрипту:
- macOS/Linux: запустите `./codex-sshfs-mount.sh` и убедитесь, что выводится список `1) ...`
- Windows: запустите `powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1` и убедитесь, что выводится список `1) ...`

Важно: после установки зависимостей **закройте и заново откройте терминал/VS Code** (они подхватывают `PATH` при запуске). На Windows часто помогает именно **выключение и включение** (полное Shut down → Power on), а не перезагрузка (Restart).

---

## macOS (для `codex-sshfs-mount.sh`)

### 1) Homebrew (если ещё нет)
Установите Homebrew с официального сайта Homebrew.

### 2) macFUSE (обязательно)
```sh
brew install --cask macfuse
```

После установки:
- `System Settings` → `Privacy & Security` → нажмите `Allow` для macFUSE system extension
- Перезагрузите Mac, если система попросит (часто требуется)

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
- закройте терминал и откройте заново (чтобы обновился `PATH`),
- закройте все окна VS Code и откройте снова (он наследует `PATH` при запуске),
- если не помогло — выполните **выключение и включение Windows** (полное Shut down → Power on), а не Restart,
- проверьте `where sshfs` (cmd) или `Get-Command sshfs` (PowerShell).
- если SSHFS-Win установлен, но `sshfs.exe` всё равно не в PATH — запустите PowerShell-скрипт с явным путём:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\codex-sshfs-mount.ps1 -SshfsPath "C:\Program Files\SSHFS-Win\bin\sshfs.exe"
  ```
- или задайте переменную окружения `SSHFS_EXE` на путь к `sshfs.exe`.
