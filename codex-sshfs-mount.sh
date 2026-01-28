#!/usr/bin/env bash

# If someone runs this script via `sh ...`, re-exec with bash (script uses bash features).
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -eu
set -o pipefail 2>/dev/null || true

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: codex-sshfs-mount.sh [options]

Reads SSH FS configs from VS Code settings.json, lets you pick a host, and mounts it via sshfs
into a folder next to this script (./<host-name>/).

Options:
  --settings PATH        Path to VS Code settings.json (JSON/JSONC). Auto-detected if omitted.
  --select NAME|NUMBER   Non-interactive selection (match by name, or 1-based index).
  --unmount, --umount    Unmount selected host (no mount).
  --force                If mountpoint is already mounted, unmount first.
  --interval SECONDS     SSH keepalive interval (default: 15).
  --count N              SSH keepalive max missed (default: 3).
  --dry-run              Print sshfs command and exit (never prints passwords).
  -h, --help             Show help.

Environment:
  VSCODE_SETTINGS        Same as --settings.
  SSHFS_EXTRA_OPTS       Extra sshfs -o options (comma-separated), appended to defaults.
EOF
}

KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-15}"
KEEPALIVE_COUNT="${KEEPALIVE_COUNT:-3}"
SETTINGS_PATH="${VSCODE_SETTINGS:-}"
SELECT=""
FORCE=0
DRY_RUN=0
UNMOUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)
      SETTINGS_PATH="${2:-}"; shift 2 ;;
    --select)
      SELECT="${2:-}"; shift 2 ;;
    --unmount|--umount)
      UNMOUNT=1; shift ;;
    --force)
      FORCE=1; shift ;;
    --interval)
      KEEPALIVE_INTERVAL="${2:-}"; shift 2 ;;
    --count)
      KEEPALIVE_COUNT="${2:-}"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1 (use --help)" ;;
  esac
done

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
os_name="$(uname -s 2>/dev/null || echo "")"

ensure_sshfs() {
  local fuse_missing=0
  local macfuse_install_cmd=""

  if [[ "$os_name" == "Darwin" ]]; then
    if [[ -d "/Library/Filesystems/macfuse.fs" || -d "/Library/Filesystems/osxfuse.fs" ]] \
      || command -v mount_macfuse >/dev/null 2>&1 \
      || command -v mount_osxfuse >/dev/null 2>&1; then
      :
    else
      fuse_missing=1
      echo "macFUSE not detected (required for sshfs on macOS)."
      echo "Install:"
      if command -v brew >/dev/null 2>&1; then
        macfuse_install_cmd="brew install --cask macfuse"
        echo "  brew install --cask macfuse"
      else
        echo "  Install macFUSE and re-run."
      fi
      echo "Note: you may need to allow the system extension in System Settings and reboot."

      if command -v brew >/dev/null 2>&1 && [[ -t 0 ]]; then
        printf 'Try to install macFUSE now? [y/N] ' >&2
        local ans=""
        read -r ans || true
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
          brew install --cask macfuse || true
        fi
        if [[ -d "/Library/Filesystems/macfuse.fs" || -d "/Library/Filesystems/osxfuse.fs" ]]; then
          fuse_missing=0
        fi
      fi
    fi
  fi

  if command -v sshfs >/dev/null 2>&1; then
    if [[ $fuse_missing -eq 1 ]]; then
      if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        echo "warning: macFUSE is not installed; continuing because --dry-run was used." >&2
        return 0
      fi
      if [[ -n "$macfuse_install_cmd" ]]; then
        die "macFUSE is required on macOS. Install with: $macfuse_install_cmd"
      fi
      die "macFUSE is required on macOS (install it and re-run)"
    fi
    return 0
  fi

  if [[ "$os_name" == "Darwin" ]]; then
    echo "sshfs command not found in PATH (on macOS it comes from sshfs-mac)."
  else
    echo "sshfs not found in PATH."
  fi

  local install_cmd=""
  if [[ "$os_name" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then
      echo "Install (macOS + Homebrew):"
      if [[ $fuse_missing -eq 1 ]]; then
        echo "  brew install --cask macfuse"
      fi
      echo "  brew install gromgit/fuse/sshfs-mac  # provides the 'sshfs' command"
      if [[ $fuse_missing -eq 1 ]]; then
        install_cmd="brew install --cask macfuse && brew install gromgit/fuse/sshfs-mac"
      else
        install_cmd="brew install gromgit/fuse/sshfs-mac"
      fi
    else
      echo "Install macFUSE + sshfs-mac (which provides the 'sshfs' command), then re-run."
    fi
  else
    if command -v apt-get >/dev/null 2>&1; then
      echo "Install (Debian/Ubuntu):"
      echo "  sudo apt-get update && sudo apt-get install -y sshfs"
      install_cmd="sudo apt-get update && sudo apt-get install -y sshfs"
    elif command -v dnf >/dev/null 2>&1; then
      echo "Install (Fedora/RHEL):"
      echo "  sudo dnf install -y sshfs"
      install_cmd="sudo dnf install -y sshfs"
    elif command -v yum >/dev/null 2>&1; then
      echo "Install (CentOS/RHEL):"
      echo "  sudo yum install -y sshfs"
      install_cmd="sudo yum install -y sshfs"
    elif command -v pacman >/dev/null 2>&1; then
      echo "Install (Arch):"
      echo "  sudo pacman -Sy --noconfirm sshfs"
      install_cmd="sudo pacman -Sy --noconfirm sshfs"
    elif command -v zypper >/dev/null 2>&1; then
      echo "Install (openSUSE):"
      echo "  sudo zypper install -y sshfs"
      install_cmd="sudo zypper install -y sshfs"
    elif command -v apk >/dev/null 2>&1; then
      echo "Install (Alpine):"
      echo "  sudo apk add sshfs"
      install_cmd="sudo apk add sshfs"
    else
      echo "Install sshfs via your distro's package manager and re-run."
    fi
  fi

  if [[ -n "$install_cmd" && -t 0 ]]; then
    printf 'Try to install now? [y/N] ' >&2
    local ans=""
    read -r ans || true
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
      sh -c "$install_cmd" || true
    fi
  fi

  if command -v sshfs >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    echo "warning: sshfs is not installed; continuing because --dry-run was used." >&2
    return 0
  fi
  if [[ -n "$install_cmd" ]]; then
    die "sshfs is required. Install with: $install_cmd"
  fi
  die "sshfs is required (install it via your package manager)"
}

detect_settings_path() {
  local base=""
  local -a candidates=()

  if [[ "$os_name" == "Darwin" ]]; then
    base="${HOME}/Library/Application Support"
    candidates+=(
      "$base/Code/User/settings.json"
      "$base/Code - Insiders/User/settings.json"
      "$base/VSCodium/User/settings.json"
    )
  else
    base="${XDG_CONFIG_HOME:-$HOME/.config}"
    candidates+=(
      "$base/Code/User/settings.json"
      "$base/Code - Insiders/User/settings.json"
      "$base/VSCodium/User/settings.json"
    )
  fi

  local p
  for p in "${candidates[@]}"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

expand_path() {
  local p="$1"
  if [[ "$p" == "~/"* ]]; then
    p="$HOME/${p:2}"
  elif [[ "$p" == "~" ]]; then
    p="$HOME"
  fi
  echo "$p"
}

jsonc_parse() {
  # Prints:
  # - mode=configs: one record per config, fields separated by 0x1f
  # - mode=paths: one path per line
  local file="$1"
  local mode="$2"
  local key="$3"
  local first_array="${4:-0}"

  awk -v mode="$mode" -v key="$key" -v first_array="$first_array" '
  BEGIN {
    delim = sprintf("%c", 31)

    in_string = 0
    esc = 0
    str = ""

    in_line_comment = 0
    in_block_comment = 0

    want_colon = 0
    want_array = 0

    in_target = 0
    target_depth = 0

    g_obj = 0
    g_arr = 0

    in_obj = 0
    obj_depth = 0
    state = 0 # 0 key, 1 colon, 2 value, 3 comma/end
    current_key = ""

    value_nesting = 0
    v_brace = 0
    v_bracket = 0

    reset_fields()
  }

  function reset_fields() {
    name = ""; host = ""; user = ""; port = ""; root = ""
    password_mode = "empty"; password_value = ""
    key_path = ""
  }

  function emit_config(  n) {
    n = name
    if (n == "") n = host
    printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
      n, delim, host, delim, user, delim, port, delim, root, delim, \
      password_mode, delim, password_value, delim, key_path
  }

  function hex2dec(h,    i,c,v,d) {
    d = 0
    for (i = 1; i <= length(h); i++) {
      c = tolower(substr(h, i, 1))
      if (c >= "0" && c <= "9") v = c + 0
      else if (c >= "a" && c <= "f") v = index("abcdef", c) + 9
      else v = 0
      d = d * 16 + v
    }
    return d
  }

  function set_field(k, v, is_string) {
    if (k == "name") name = v
    else if (k == "host") host = v
    else if (k == "username") user = v
    else if (k == "port") port = v
    else if (k == "root") root = v
    else if (k == "password") {
      if (is_string) {
        if (v != "") { password_mode = "string"; password_value = v }
        else { password_mode = "empty"; password_value = "" }
      } else {
        password_mode = "bool"; password_value = ""
      }
    }
    else if (k == "privateKeyPath" || k == "privateKey" || k == "identityFile") {
      if (key_path == "" && v != "") key_path = v
    }
  }

  function handle_string(tok) {
    if (!in_target) {
      if (key != "" && tok == key) {
        want_colon = 1
        want_array = 0
      }
      return
    }

    if (mode == "paths") {
      if (target_depth == 1 && !in_obj) {
        print tok
      }
      return
    }

    if (mode == "configs") {
      if (in_obj && obj_depth == 1 && !value_nesting) {
        if (state == 0) { current_key = tok; state = 1 }
        else if (state == 2) { set_field(current_key, tok, 1); state = 3 }
      }
      return
    }
  }

  function handle_primitive(tok) {
    if (mode != "configs") return
    if (!(in_obj && obj_depth == 1 && state == 2 && !value_nesting)) return

    if (tok == "null") set_field(current_key, "", 0)
    else set_field(current_key, tok, 0)
    state = 3
  }

  function start_target_array() {
    in_target = 1
    target_depth = 0
    want_colon = 0
    want_array = 0
  }

  function end_target_array() {
    in_target = 0
    target_depth = 0
  }

  {
    line = $0 "\n"
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)

      if (in_line_comment) {
        if (c == "\n") in_line_comment = 0
        continue
      }

      if (in_block_comment) {
        if (c == "*" && substr(line, i + 1, 1) == "/") {
          in_block_comment = 0
          i++
        }
        continue
      }

      if (in_string) {
        if (esc) {
          if (c == "u") {
            hex = substr(line, i + 1, 4)
            if (hex ~ /^[0-9A-Fa-f]{4}$/) {
              code = hex2dec(hex)
              if (code < 256) str = str sprintf("%c", code)
              else str = str "\\u" hex
              i += 4
            } else {
              str = str "u"
            }
          }
          else if (c == "n") str = str "\n"
          else if (c == "r") str = str "\r"
          else if (c == "t") str = str "\t"
          else if (c == "b") str = str "\b"
          else if (c == "f") str = str "\f"
          else str = str c
          esc = 0
          continue
        }

        if (c == "\\") { esc = 1; continue }
        if (c == "\"") {
          in_string = 0
          tok = str
          str = ""
          handle_string(tok)
          continue
        }

        str = str c
        continue
      }

      # Not in string/comment
      if (c == "/") {
        nxt = substr(line, i + 1, 1)
        if (nxt == "/") { in_line_comment = 1; i++; continue }
        if (nxt == "*") { in_block_comment = 1; i++; continue }
      }

      if (c == "\"") { in_string = 1; esc = 0; str = ""; continue }

      # Key-based target array detection
      if (!in_target && key != "") {
        if (want_colon && c == ":") { want_colon = 0; want_array = 1; continue }
        if (want_array) {
          if (c ~ /[ \t\r\n]/) continue
          if (c == "[") { start_target_array() }
          else { want_array = 0 }
        }
      }

      # Fallback: first top-level array
      if (!in_target && key == "" && first_array + 0 == 1) {
        if (c == "[" && g_obj == 0 && g_arr == 0) {
          start_target_array()
        }
      }

      # Track target array depth
      if (in_target) {
        if (c == "[") target_depth++
        else if (c == "]") {
          target_depth--
          if (target_depth == 0) { end_target_array(); continue }
        }
      }

      # Enter/exit config object (only direct elements of target array)
      if (in_target && mode == "configs") {
        if (!in_obj && target_depth == 1 && c == "{") {
          in_obj = 1
          obj_depth = 1
          state = 0
          current_key = ""
          value_nesting = 0
          v_brace = 0
          v_bracket = 0
          reset_fields()
          continue
        }

        if (in_obj) {
          # Track nested value structures (objects/arrays) so we can advance state after them
          if (!value_nesting && obj_depth == 1 && state == 2) {
            if (c == "{") { value_nesting = 1; v_brace = 1; v_bracket = 0 }
            else if (c == "[") { value_nesting = 1; v_brace = 0; v_bracket = 1 }
          }

          if (value_nesting) {
            if (c == "{") v_brace++
            else if (c == "}") v_brace--
            else if (c == "[") v_bracket++
            else if (c == "]") v_bracket--
            if (v_brace <= 0 && v_bracket <= 0) {
              value_nesting = 0
              v_brace = 0
              v_bracket = 0
              state = 3
            }
          }

          if (c == "{") obj_depth++
          else if (c == "}") {
            obj_depth--
            if (obj_depth == 0) {
              emit_config()
              in_obj = 0
              continue
            }
          }

          if (obj_depth == 1 && !value_nesting) {
            if (c == ":" && state == 1) { state = 2; continue }
            if (c == "," && state == 3) { state = 0; continue }

            if (state == 2) {
              if (c ~ /[ \t\r\n]/) continue
              if (c ~ /[-0-9tfn]/) {
                tok = c
                while (i + 1 <= length(line)) {
                  nxt = substr(line, i + 1, 1)
                  if (nxt ~ /[A-Za-z0-9+\\-.]/) { tok = tok nxt; i++ }
                  else break
                }
                handle_primitive(tok)
                continue
              }
            }
          }
          continue
        }
      }

      # Global depths (for fallback detection)
      if (c == "{") g_obj++
      else if (c == "}" && g_obj > 0) g_obj--
      else if (c == "[") g_arr++
      else if (c == "]" && g_arr > 0) g_arr--
    }
  }
  ' "$file"
}

append_configs_from_file() {
  local file="$1"
  local out=""
  out="$(jsonc_parse "$file" configs "sshfs.configs" 0 || true)"
  if [[ -z "$out" ]]; then
    out="$(jsonc_parse "$file" configs "" 1 || true)"
  fi

  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=$'\x1f' read -r name host username port root password_mode password_value key_path <<<"$line"
    cfg_name+=("$name")
    cfg_host+=("$host")
    cfg_user+=("$username")
    cfg_port+=("$port")
    cfg_root+=("$root")
    cfg_pw_mode+=("$password_mode")
    cfg_pw_value+=("$password_value")
    cfg_key_path+=("$key_path")
  done <<<"$out"
}

ensure_sshfs

if [[ -z "$SETTINGS_PATH" ]]; then
  SETTINGS_PATH="$(detect_settings_path || true)"
fi
[[ -n "$SETTINGS_PATH" ]] || die "could not find VS Code settings.json (set VSCODE_SETTINGS or use --settings PATH)"
[[ -f "$SETTINGS_PATH" ]] || die "settings.json not found: $SETTINGS_PATH"

settings_dir="$(cd -- "$(dirname -- "$SETTINGS_PATH")" && pwd)"

cfg_name=()
cfg_host=()
cfg_user=()
cfg_port=()
cfg_root=()
cfg_pw_mode=()
cfg_pw_value=()
cfg_key_path=()

append_configs_from_file "$SETTINGS_PATH"

tmp_cfgpaths="$(mktemp "${TMPDIR:-/tmp}/codex-sshfs-configpaths.XXXXXX")"
jsonc_parse "$SETTINGS_PATH" paths "sshfs.configpaths" 0 >"$tmp_cfgpaths" 2>/dev/null || true
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  p="$(expand_path "$p")"
  if [[ "$p" != /* ]]; then
    p="$settings_dir/$p"
  fi
  if [[ -f "$p" ]]; then
    append_configs_from_file "$p"
  fi
done <"$tmp_cfgpaths"
rm -f "$tmp_cfgpaths" >/dev/null 2>&1 || true

[[ ${#cfg_name[@]} -gt 0 ]] || die "no sshfs.configs found in $SETTINGS_PATH"

pick_index() {
  local picked=""

  if [[ -n "$SELECT" ]]; then
    if [[ "$SELECT" =~ ^[0-9]+$ ]]; then
      picked="$SELECT"
    else
      local i
      for i in "${!cfg_name[@]}"; do
        if [[ "${cfg_name[$i]}" == "$SELECT" ]]; then
          picked=$((i + 1))
          break
        fi
      done
      [[ -n "$picked" ]] || die "no host matches --select \"$SELECT\""
    fi
  else
    local i display summary
    for i in "${!cfg_name[@]}"; do
      summary=""
      if [[ -n "${cfg_user[$i]}" && -n "${cfg_host[$i]}" ]]; then
        summary="${cfg_user[$i]}@${cfg_host[$i]}"
      elif [[ -n "${cfg_host[$i]}" ]]; then
        summary="${cfg_host[$i]}"
      fi
      if [[ -n "${cfg_port[$i]}" && -n "$summary" ]]; then
        summary="${summary}:${cfg_port[$i]}"
      fi
      if [[ -n "${cfg_root[$i]}" ]]; then
        summary="${summary} ${cfg_root[$i]}"
      fi
      display="${cfg_name[$i]}"
      [[ -n "$summary" ]] && display="${display} (${summary})"
      printf '%3d) %s\n' "$((i + 1))" "$display" >&2
    done
    printf 'Select host number: ' >&2
    read -r picked
  fi

  [[ "$picked" =~ ^[0-9]+$ ]] || die "invalid selection: $picked"
  (( picked >= 1 && picked <= ${#cfg_name[@]} )) || die "selection out of range: $picked"
  echo "$picked"
}

selected="$(pick_index)"
idx=$((selected - 1))

NAME="${cfg_name[$idx]}"
HOST="${cfg_host[$idx]}"
USERNAME="${cfg_user[$idx]}"
PORT="${cfg_port[$idx]}"
ROOT="${cfg_root[$idx]}"
PASSWORD_MODE="${cfg_pw_mode[$idx]}"
PASSWORD_VALUE="${cfg_pw_value[$idx]}"
KEY_PATH="${cfg_key_path[$idx]}"

[[ -n "${HOST:-}" ]] || die "selected config has empty host"

safe_name="${NAME// /_}"
safe_name="${safe_name//\//_}"
safe_name="${safe_name//\\/_}"
safe_name="$(printf '%s' "$safe_name" | tr -cd 'A-Za-z0-9._-')"
[[ -n "$safe_name" ]] || safe_name="sshfs-mount"

mount_dir="$script_dir/$safe_name"
mkdir -p "$mount_dir"

is_mounted() {
  local dir="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$dir"
    return $?
  fi
  if command -v df >/dev/null 2>&1; then
    local mp=""
    mp="$(df -P "$dir" 2>/dev/null | awk 'NR==2{print $6}')"
    if [[ -n "$mp" && "$mp" == "$dir" ]]; then
      return 0
    fi
  fi
  mount | grep -F " on $dir " >/dev/null 2>&1 || mount | grep -F " on $dir(" >/dev/null 2>&1
}

unmount_dir() {
  local dir="$1"
  local rc=0
  local out=""
  local -a errs=()

  # IMPORTANT: with `set -e`, we must handle failures explicitly.
  set +e

  if [[ "$os_name" == "Darwin" ]]; then
    # On macOS, prefer diskutil. It usually works better for FUSE mounts than plain umount.
    if command -v diskutil >/dev/null 2>&1; then
      out="$(diskutil unmount "$dir" 2>&1)"
      rc=$?
      if [[ $rc -eq 0 ]]; then
        set -e
        return 0
      fi
      [[ -n "$out" ]] && errs+=("diskutil unmount: $out")

      # If the mount is busy, force usually helps.
      out="$(diskutil unmount force "$dir" 2>&1)"
      rc=$?
      if [[ $rc -eq 0 ]]; then
        set -e
        return 0
      fi
      [[ -n "$out" ]] && errs+=("diskutil unmount force: $out")
    fi

    out="$(umount "$dir" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      set -e
      return 0
    fi
    [[ -n "$out" ]] && errs+=("umount: $out")

    out="$(umount -f "$dir" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      set -e
      return 0
    fi
    [[ -n "$out" ]] && errs+=("umount -f: $out")

    set -e
    if [[ ${#errs[@]} -gt 0 ]]; then
      echo "unmount errors:" >&2
      printf '  - %s\n' "${errs[@]}" >&2
    fi
    return 1
  fi

  # Linux
  if command -v fusermount3 >/dev/null 2>&1; then
    out="$(fusermount3 -u "$dir" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      set -e
      return 0
    fi
    [[ -n "$out" ]] && errs+=("fusermount3 -u: $out")
  fi
  if command -v fusermount >/dev/null 2>&1; then
    out="$(fusermount -u "$dir" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      set -e
      return 0
    fi
    [[ -n "$out" ]] && errs+=("fusermount -u: $out")
  fi

  out="$(umount "$dir" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 && -n "$out" ]]; then
    errs+=("umount: $out")
  fi
  if [[ $rc -ne 0 && ${#errs[@]} -gt 0 ]]; then
    echo "unmount errors:" >&2
    printf '  - %s\n' "${errs[@]}" >&2
  fi
  return $rc
}

wait_for_unmount() {
  local dir="$1"
  local i=0
  while (( i < 5 )); do
    if ! is_mounted "$dir"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

if is_mounted "$mount_dir"; then
  if [[ $UNMOUNT -eq 1 ]]; then
    :
  elif [[ $FORCE -eq 1 ]]; then
    unmount_dir "$mount_dir"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "Already mounted: $mount_dir" >&2
    else
      echo "Already mounted: $mount_dir"
      exit 0
    fi
  fi
fi

if [[ $UNMOUNT -eq 1 ]]; then
  if ! is_mounted "$mount_dir"; then
    echo "Not mounted: $mount_dir"
    exit 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Would unmount: $mount_dir"
    exit 0
  fi
  unmount_dir "$mount_dir" || true
  if wait_for_unmount "$mount_dir"; then
    echo "Unmounted: $NAME"
    echo " -> $mount_dir"
    exit 0
  fi

  if [[ "$os_name" == "Darwin" ]]; then
    cat >&2 <<'EOF'
hint: unmount can fail if something is using the mount (open file, current working directory, VS Code indexer).
Try:
  - close terminals/VS Code windows that use this mount, then run unmount again
  - or force unmount:
      diskutil unmount force "<mountpoint>"
EOF
  else
    cat >&2 <<'EOF'
hint: unmount can fail if something is using the mount (open file, current working directory).
Try closing processes using the mount, then run unmount again.
EOF
  fi

  echo "mount grep:" >&2
  mount | grep -F " on $mount_dir" >&2 || true
  die "failed to unmount: $mount_dir"
fi

remote="$HOST"
[[ -n "${USERNAME:-}" ]] && remote="${USERNAME}@${HOST}"
remote_spec="${remote}:"
[[ -n "${ROOT:-}" ]] && remote_spec="${remote}:${ROOT}"

optlist=(
  "reconnect"
  "ServerAliveInterval=${KEEPALIVE_INTERVAL}"
  "ServerAliveCountMax=${KEEPALIVE_COUNT}"
  "TCPKeepAlive=yes"
)

if [[ -n "${KEY_PATH:-}" ]]; then
  optlist+=("IdentityFile=${KEY_PATH}" "IdentitiesOnly=yes")
fi

optstr="$(IFS=,; echo "${optlist[*]}")"
if [[ -n "${SSHFS_EXTRA_OPTS:-}" ]]; then
  optstr="${optstr},${SSHFS_EXTRA_OPTS}"
fi

cmd=(sshfs)
if [[ -n "${PORT:-}" ]]; then
  cmd+=(-p "$PORT")
fi
cmd+=("$remote_spec" "$mount_dir" -o "$optstr")

if [[ $DRY_RUN -eq 1 ]]; then
  printf 'sshfs command:'
  printf ' %q' "${cmd[@]}"
  echo
  exit 0
fi

run_sshfs() {
  SSHFS_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-sshfs-stderr.XXXXXX")"
  local rc=0

  if [[ "${PASSWORD_MODE:-empty}" == "string" && -n "${PASSWORD_VALUE:-}" ]]; then
    local askpass=""
    askpass="$(mktemp "${TMPDIR:-/tmp}/codex-sshfs-askpass.XXXXXX")"
    chmod 700 "$askpass"
    cat >"$askpass" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "${SSHFS_PASSWORD:-}"
EOF

    set +e
    SSHFS_PASSWORD="$PASSWORD_VALUE" SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-1}" "${cmd[@]}" 2>"$SSHFS_ERR_FILE"
    rc=$?
    set -e
    rm -f "$askpass"
  else
    set +e
    "${cmd[@]}" 2>"$SSHFS_ERR_FILE"
    rc=$?
    set -e
  fi

  return $rc
}

SSHFS_ERR_FILE=""
run_sshfs || die "sshfs mount failed"

wait_for_mount() {
  local dir="$1"
  local i=0
  while (( i < 5 )); do
    if is_mounted "$dir"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

if wait_for_mount "$mount_dir"; then
  echo "Mounted: $NAME"
  echo " -> $mount_dir"
else
  if [[ -n "${SSHFS_ERR_FILE:-}" && -s "${SSHFS_ERR_FILE:-}" ]]; then
    echo "sshfs stderr:" >&2
    cat "$SSHFS_ERR_FILE" >&2
  fi
  if [[ "$os_name" == "Darwin" ]] && [[ -n "${SSHFS_ERR_FILE:-}" ]] && grep -q "failed to exec mount program: Operation not permitted" "$SSHFS_ERR_FILE" 2>/dev/null; then
    cat >&2 <<'EOF'
hint: macOS blocked the macFUSE mount helper. Usually this means:
  - macFUSE system extension is not allowed/loaded (System Settings → Privacy & Security → Allow, then reboot), or
  - you're running in a restricted sandbox environment that disallows FUSE mounts.
EOF
  fi
  if command -v df >/dev/null 2>&1; then
    echo "df -P mountpoint:" >&2
    df -P "$mount_dir" >&2 || true
  fi
  echo "mount grep:" >&2
  mount | grep -F " on $mount_dir" >&2 || true
  rm -f "${SSHFS_ERR_FILE:-}" >/dev/null 2>&1 || true
  die "sshfs exited but mountpoint is not mounted: $mount_dir"
fi

rm -f "${SSHFS_ERR_FILE:-}" >/dev/null 2>&1 || true
