#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека управления состоянием узла (lib/state.sh)
# =============================================================================

STATE_DIR="${STATE_DIR:-/etc/just1knode}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
CLIENTS_FILE="${CLIENTS_FILE:-${STATE_DIR}/clients.json}"
LINKS_FILE="${LINKS_FILE:-${STATE_DIR}/links.json}"

init_state_dir() {
    mkdir -p "$STATE_DIR"
    chown root:xrayapi "$STATE_DIR" 2>/dev/null || true
    chmod 2770 "$STATE_DIR" 2>/dev/null || true

    for f in "$STATE_FILE" "$CLIENTS_FILE" "$LINKS_FILE"; do
        if [[ -L "$f" ]]; then
            rm -f "$f"
        fi
    done

    if [[ ! -f "$STATE_FILE" ]]; then
        echo "{}" > "$STATE_FILE"
    fi
    if [[ ! -f "$CLIENTS_FILE" ]]; then
        echo "{}" > "$CLIENTS_FILE"
    fi
    if [[ ! -f "$LINKS_FILE" ]]; then
        echo "{}" > "$LINKS_FILE"
    fi

    chown -h root:xrayapi "$STATE_FILE" "$CLIENTS_FILE" "$LINKS_FILE" 2>/dev/null || true
    chmod 660 "$STATE_FILE" "$CLIENTS_FILE" "$LINKS_FILE" 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -type f -name "*.lock" -exec chown -h root:xrayapi {} + 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -type f -name "*.lock" -exec chmod 660 {} + 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -type f -name "idempotency.db*" -exec chown -h root:xrayapi {} + 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -type f -name "idempotency.db*" -exec chmod 660 {} + 2>/dev/null || true
}

set_state_val() {
    local key="$1"
    local val="$2"
    init_state_dir
    python3 -c "
import sys, json, os, tempfile
try:
    import fcntl
except ImportError:
    fcntl = None

os.umask(0o007)

def safe_arg(val):
    if not isinstance(val, str):
        return val
    try:
        return val.encode(sys.getfilesystemencoding(), 'surrogateescape').decode('utf-8', 'replace')
    except Exception:
        return val

f, k, v = sys.argv[1], safe_arg(sys.argv[2]), safe_arg(sys.argv[3])
lock_file = f + '.lock'
open_flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
lock_fd = os.open(lock_file, open_flags, 0o660)
try:
    if hasattr(os, 'fchmod'):
        os.fchmod(lock_fd, 0o660)
    else:
        os.chmod(lock_file, 0o660)
    try:
        import grp
        gid = grp.getgrnam('xrayapi').gr_gid
        if hasattr(os, 'fchown'):
            os.fchown(lock_fd, 0, gid)
    except Exception:
        import shutil
        shutil.chown(lock_file, user='root', group='xrayapi')
except Exception:
    pass
if fcntl:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    data = {}
    if os.path.exists(f):
        try:
            if os.path.getsize(f) == 0:
                raise ValueError('State file ' + str(f) + ' is empty (0 bytes)')
            with open(f, 'r', encoding='utf-8', errors='replace') as fp:
                data = json.load(fp)
                if not isinstance(data, dict):
                    raise ValueError('State file ' + str(f) + ' root must be a JSON object')
        except Exception as e:
            bak = f + '.corrupted.bak'
            bak_saved = False
            try:
                if os.path.islink(bak) or os.path.lexists(bak):
                    os.unlink(bak)
                open_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0)
                bak_fd = os.open(bak, open_flags, 0o600)
                try:
                    with open(f, 'rb') as src_fp, os.fdopen(bak_fd, 'wb') as dst_fp:
                        dst_fp.write(src_fp.read())
                    bak_saved = True
                except Exception:
                    pass
            except Exception:
                pass
            if bak_saved:
                print('ОШИБКА: Поврежден файл состояния ' + str(f) + ' (' + str(e) + '). Резервная копия сохранена в ' + str(bak) + '. Запись прервана во избежание потери данных.', file=sys.stderr)
            else:
                print('ОШИБКА: Поврежден файл состояния ' + str(f) + ' (' + str(e) + '). Не удалось сохранить резервную копию. Запись прервана во избежание потери данных.', file=sys.stderr)
            sys.exit(1)
    data[k] = v
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(f), suffix='.tmp')
    try:
        if hasattr(os, 'fchmod'):
            os.fchmod(tmp_fd, 0o660)
        import grp
        gid = grp.getgrnam('xrayapi').gr_gid
        if hasattr(os, 'fchown'):
            os.fchown(tmp_fd, 0, gid)
    except Exception:
        pass
    with os.fdopen(tmp_fd, 'w', encoding='utf-8', errors='replace') as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
        fp.flush()
    os.replace(tmp_path, f)
finally:
    if fcntl:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
" "$STATE_FILE" "$key" "$val"
}

get_state_val() {
    local key="$1"
    local default_val="${2:-}"
    if [[ ! -f "$STATE_FILE" ]] || ! command -v python3 >/dev/null 2>&1; then
        echo "$default_val"
        return
    fi
    python3 -c "
import sys, json

def safe_arg(val):
    if not isinstance(val, str):
        return val
    try:
        return val.encode(sys.getfilesystemencoding(), 'surrogateescape').decode('utf-8', 'replace')
    except Exception:
        return val

f, k, d = sys.argv[1], safe_arg(sys.argv[2]), safe_arg(sys.argv[3])
try:
    with open(f, 'r', encoding='utf-8', errors='replace') as fp:
        data = json.load(fp)
    print(data.get(k, d))
except Exception:
    print(d)
" "$STATE_FILE" "$key" "$default_val"
}

# Определение фактического статуса сервера (только роли v2)
get_node_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "unconfigured"
        return
    fi

    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        echo "$role"
        return
    fi
    echo "unconfigured"
}

ensure_xray_config_permissions() {
    local cfg="${1:-${XRAY_CONFIG:-/usr/local/etc/xray/config.json}}"
    local cfg_dir
    cfg_dir="$(dirname "$cfg")"
    chmod 755 "$cfg_dir" 2>/dev/null || true
    if [[ -f "$cfg" ]]; then
        chown root:xrayapi "$cfg" 2>/dev/null || true
        chmod 640 "$cfg" 2>/dev/null || true
    fi
}

# Единый атомарный мутатор JSON-полей state.json (zero duplication)
_state_mutate_json() {
    local action="$1"
    local arg1="${2:-}"
    local arg2="${3:-}"
    init_state_dir
    python3 -c "
import sys, json, os, tempfile
try:
    import fcntl
except ImportError:
    fcntl = None

f, action, arg1, arg2 = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
lock_file = f + '.lock'
open_flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
lock_fd = os.open(lock_file, open_flags, 0o660)
if fcntl:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    data = {}
    if os.path.exists(f) and os.path.getsize(f) > 0:
        with open(f, 'r', encoding='utf-8', errors='replace') as fp:
            loaded = json.load(fp)
            if isinstance(loaded, dict):
                data = loaded

    if action == 'set_json':
        data[arg1] = json.loads(arg2)
    elif action == 'set_module':
        mod_obj = json.loads(arg2)
        if not isinstance(mod_obj, dict):
            raise ValueError('module config must be a dict')
        mod_obj.setdefault('enabled', True)
        mods = data.get('modules')
        if not isinstance(mods, dict):
            mods = {}
        mods[arg1] = mod_obj
        data['modules'] = mods
    elif action == 'remove_module':
        mods = data.get('modules')
        if isinstance(mods, dict) and arg1 in mods:
            del mods[arg1]
            data['modules'] = mods
    else:
        raise ValueError('Unknown mutation action: ' + action)

    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(f), suffix='.tmp')
    try:
        import grp
        gid = grp.getgrnam('xrayapi').gr_gid
        os.fchown(tmp_fd, 0, gid)
        os.fchmod(tmp_fd, 0o660)
    except Exception:
        pass
    with os.fdopen(tmp_fd, 'w', encoding='utf-8', errors='replace') as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
        fp.flush()
    os.replace(tmp_path, f)
finally:
    if fcntl:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
" "$STATE_FILE" "$action" "$arg1" "$arg2"
}

set_state_json_val() {
    _state_mutate_json "set_json" "$1" "$2"
}

is_module_enabled() {
    local mod_name="$1"
    [[ -f "$STATE_FILE" ]] || return 1
    python3 -c "
import sys, json
f, m = sys.argv[1], sys.argv[2]
try:
    with open(f, 'r', encoding='utf-8', errors='replace') as fp:
        data = json.load(fp)
    mods = data.get('modules', {})
    sys.exit(0 if isinstance(mods, dict) and isinstance(mods.get(m), dict) and mods[m].get('enabled') is True else 1)
except Exception:
    sys.exit(1)
" "$STATE_FILE" "$mod_name"
}

get_module_val() {
    local mod_name="$1"
    local field="$2"
    local default_val="${3:-}"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$default_val"
        return 0
    fi
    python3 -c "
import sys, json
f, m, k, d = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(f, 'r', encoding='utf-8', errors='replace') as fp:
        data = json.load(fp)
    mods = data.get('modules', {})
    if isinstance(mods, dict) and isinstance(mods.get(m), dict):
        v = mods[m].get(k, d)
        print('' if v is None else v)
    else:
        print(d)
except Exception:
    print(d)
" "$STATE_FILE" "$mod_name" "$field" "$default_val"
}

set_module_config() {
    _state_mutate_json "set_module" "$1" "${2:-{\"enabled\": true}}"
}

remove_module_config() {
    _state_mutate_json "remove_module" "$1"
}

count_enabled_modules() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "0"
        return 0
    fi
    python3 -c "
import sys, json
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as fp:
        mods = json.load(fp).get('modules', {})
    print(sum(1 for v in mods.values() if isinstance(v, dict) and v.get('enabled') is True) if isinstance(mods, dict) else 0)
except Exception:
    print(0)
" "$STATE_FILE"
}

save_links_json() {
    local payload_json="$1"
    init_state_dir
    local lf="${LINKS_FILE:-${STATE_DIR}/links.json}"
    python3 -c '
import json, os, sys, tempfile
try:
    import fcntl
except ImportError:
    fcntl = None

os.umask(0o007)
lf, raw = sys.argv[1], sys.argv[2]
data = json.loads(raw)
if not isinstance(data, dict):
    raise ValueError("links.json root must be object")

lock_file = lf + ".lock"
open_flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
lock_fd = os.open(lock_file, open_flags, 0o660)
try:
    if fcntl:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(lf)), suffix=".tmp")
    try:
        import grp
        gid = grp.getgrnam("xrayapi").gr_gid
        os.fchown(tmp_fd, 0, gid)
    except Exception:
        pass
    os.fchmod(tmp_fd, 0o660)
    with os.fdopen(tmp_fd, "w", encoding="utf-8") as fp:
        json.dump(data, fp, indent=2, ensure_ascii=False)
        fp.flush()
    os.replace(tmp_path, lf)
finally:
    if fcntl:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    os.close(lock_fd)
' "$lf" "$payload_json"
}
