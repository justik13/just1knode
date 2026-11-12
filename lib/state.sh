#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека управления состоянием узла (lib/state.sh)
# =============================================================================

STATE_DIR="${STATE_DIR:-/etc/just1knode}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.json}"
CLIENTS_FILE="${CLIENTS_FILE:-${STATE_DIR}/clients.json}"
RELAYS_FILE="${RELAYS_FILE:-${STATE_DIR}/relays.json}"
LINKS_FILE="${LINKS_FILE:-${STATE_DIR}/links.json}"

init_state_dir() {
    mkdir -p "$STATE_DIR"
    chown root:xrayapi "$STATE_DIR" 2>/dev/null || true
    chmod 2770 "$STATE_DIR" 2>/dev/null || true

    for f in "$STATE_FILE" "$CLIENTS_FILE" "$RELAYS_FILE" "$LINKS_FILE"; do
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
    if [[ ! -f "$RELAYS_FILE" ]]; then
        echo "[]" > "$RELAYS_FILE"
    fi
    if [[ ! -f "$LINKS_FILE" ]]; then
        echo "{}" > "$LINKS_FILE"
    fi

    chown -h root:xrayapi "$STATE_FILE" "$CLIENTS_FILE" "$RELAYS_FILE" "$LINKS_FILE" 2>/dev/null || true
    chmod 660 "$STATE_FILE" "$CLIENTS_FILE" "$RELAYS_FILE" "$LINKS_FILE" 2>/dev/null || true
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

# Миграция устаревших полей и ролей state.json
migrate_legacy_state() {
    if [[ ! -f "$STATE_FILE" ]] || ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    python3 -c "
import sys, json, os, tempfile
try:
    import fcntl
except ImportError:
    fcntl = None

f = sys.argv[1]
if not os.path.exists(f) or os.path.getsize(f) == 0:
    sys.exit(0)

lock_file = f + '.lock'
open_flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
lock_fd = os.open(lock_file, open_flags, 0o660)
if fcntl:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    try:
        with open(f, 'r', encoding='utf-8', errors='replace') as fp:
            data = json.load(fp)
    except Exception:
        sys.exit(0)
    if not isinstance(data, dict):
        sys.exit(0)

    changed = False
    role = str(data.get('role', '')).lower()

    is_v2_role = role in ('ru_hub', 'eu_hub', 'exit_node')
    if not is_v2_role:
        if 'has_relay' not in data:
            relay_p = str(data.get('relay_port', '')).strip()
            if role in ('relay', 'dual') or (relay_p and relay_p != '-'):
                data['has_relay'] = '1'
                changed = True
            else:
                data['has_relay'] = '0'
                changed = True

        if 'has_vless' not in data:
            v_dom = str(data.get('vless_domain', '')).strip()
            if role == 'vless' or (v_dom and v_dom != '-'):
                data['has_vless'] = '1'
                changed = True
            else:
                data['has_vless'] = '0'
                changed = True

        has_r = data.get('has_relay') == '1'
        has_v = data.get('has_vless') == '1'
        if role != 'origin' and (has_r or has_v) and data.get('role') != 'node':
            data['role'] = 'node'
            changed = True
        elif role in ('awg', 'dual') and not (has_r or has_v):
            data['role'] = 'unconfigured'
            changed = True

    if not data.get('xray_api_key') and data.get('awg_api_key'):
        data['xray_api_key'] = data['awg_api_key']
        changed = True

    # Migrate active legacy traffic watchdog settings into traffic_limit.json before key purge
    state_dir = os.path.dirname(os.path.abspath(f))
    tl_cfg_path = os.path.join(state_dir, 'traffic_limit.json')
    tl_exceeded_path = os.path.join(state_dir, 'traffic_limit_exceeded')
    legacy_cutoff_path = os.path.join(state_dir, 'traffic_cutoff.active')
    old_tl_status = str(data.get('traffic_limit_status') or '').strip().lower()
    raw_old_gb = data.get('traffic_limit_gb')
    raw_old_day = data.get('traffic_reset_day')
    old_gb = 0
    try:
        if raw_old_gb is not None and not isinstance(raw_old_gb, bool):
            old_gb = int(str(raw_old_gb).strip() or 0)
    except (TypeError, ValueError):
        old_gb = 0
    old_day = 1
    try:
        if raw_old_day is not None and not isinstance(raw_old_day, bool):
            parsed_day = int(str(raw_old_day).strip() or 1)
            if 1 <= parsed_day <= 31:
                old_day = parsed_day
    except (TypeError, ValueError):
        old_day = 1

    if old_tl_status == 'enabled' and old_gb > 0 and not os.path.exists(tl_cfg_path):
        tl_fd, tl_tmp = tempfile.mkstemp(dir=state_dir, suffix='.tmp')
        try:
            os.fchmod(tl_fd, 0o640)
            with os.fdopen(tl_fd, 'w', encoding='utf-8') as tfp:
                json.dump({'limit_gb': old_gb, 'reset_day': old_day}, tfp, indent=2)
                tfp.flush()
            os.replace(tl_tmp, tl_cfg_path)
        except Exception:
            if os.path.exists(tl_tmp):
                os.remove(tl_tmp)
    if (
        str(data.get('traffic_cutoff_triggered') or '').strip().lower() == 'true'
        or os.path.exists(legacy_cutoff_path)
    ) and os.path.exists(tl_cfg_path) and not os.path.exists(tl_exceeded_path):
        try:
            with open(tl_exceeded_path, 'a', encoding='utf-8'):
                pass
        except Exception:
            pass

    legacy_keys = [
        'has_awg', 'awg_installed', 'awg_api_url', 'awg_api_key', 'awg_domain', 'awg_port',
        'traffic_limit_status', 'traffic_limit_gb', 'traffic_reset_day', 'traffic_cutoff_triggered',
        'traffic_telegram_token', 'traffic_telegram_chat_id', 'traffic_warn_pct',
        'traffic_tg_token', 'traffic_tg_chat',
    ]
    for k in legacy_keys:
        if k in data:
            del data[k]
            changed = True

    if changed:
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
" "$STATE_FILE" 2>/dev/null || true
}

# Определение фактического статуса сервера (только роли v2)
get_node_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "unconfigured"
        return
    fi
    migrate_legacy_state

    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        echo "$role"
        return
    fi
    echo "unconfigured"
}

# Транзакционный манифест
manifest_begin() {
    local extra_targets=("$@")
    TXN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/just1knode_txn_XXXXXX")"
    mkdir -p "$TXN_DIR/files"
    MANIFEST_LOG="$TXN_DIR/manifest.tsv"
    : > "$MANIFEST_LOG"

    local targets=(
        "$RELAYS_FILE"
        "$LINKS_FILE"
        "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
        "${XRAY_API_CONFIG_ENV:-/etc/xray-api/config.env}"
        "${NGINX_CONF_DIR:-/etc/nginx}/conf.d/just1k-xhttp-upstreams.conf"
    )

    if [[ -d "${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}" ]]; then
        while IFS= read -r -d '' conf_file; do
            targets+=("$conf_file")
            echo "$conf_file" >> "$TXN_DIR/initial_nginx_relays.txt"
        done < <(find "${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}" -type f -name "*.conf" -print0 2>/dev/null)
    fi

    for extra in "${extra_targets[@]}"; do
        if [[ -n "$extra" ]]; then
            targets+=("$extra")
        fi
    done

    # Дедупликация и регистрация
    local seen_targets=()
    local tgt
    for tgt in "${targets[@]}"; do
        if [[ -z "$tgt" ]]; then
            continue
        fi
        local already_seen=0
        for s in "${seen_targets[@]}"; do
            if [[ "$s" == "$tgt" ]]; then
                already_seen=1
                break
            fi
        done
        if [[ $already_seen -eq 1 ]]; then
            continue
        fi
        seen_targets+=("$tgt")

        if [[ -f "$tgt" ]]; then
            local hash_orig
            hash_orig="$(sha256sum "$tgt" | awk '{print $1}')"
            local backup_path
            backup_path="$TXN_DIR/files/$(basename "$tgt")_$$_${RANDOM}"
            cp -p "$tgt" "$backup_path" 2>/dev/null || cp "$tgt" "$backup_path"
            echo -e "${tgt}\tpresent\t${hash_orig}\t${backup_path}" >> "$MANIFEST_LOG"
        else
            echo -e "${tgt}\tabsent\t-\t-" >> "$MANIFEST_LOG"
        fi
    done
}

manifest_track_file() {
    local target="$1"
    if [[ -z "${MANIFEST_LOG:-}" || ! -f "${MANIFEST_LOG:-}" ]]; then
        return
    fi
    if grep -q "^${target}\t" "$MANIFEST_LOG" 2>/dev/null; then
        return
    fi
    if [[ -f "$target" ]]; then
        local hash_orig
        hash_orig="$(sha256sum "$target" | awk '{print $1}')"
        local backup_path
        backup_path="$TXN_DIR/files/$(basename "$target")_$$_${RANDOM}"
        cp "$target" "$backup_path"
        echo -e "${target}\tpresent\t${hash_orig}\t${backup_path}" >> "$MANIFEST_LOG"
    else
        echo -e "${target}\tabsent\t-\t-" >> "$MANIFEST_LOG"
    fi
}

manifest_commit() {
    if [[ -n "${TXN_DIR:-}" && -d "${TXN_DIR:-}" ]]; then
        rm -rf "$TXN_DIR"
    fi
    MANIFEST_LOG=""
}

manifest_rollback() {
    warn "Инициирован откат изменений транзакции..."
    if [[ -z "${MANIFEST_LOG:-}" || ! -f "${MANIFEST_LOG:-}" ]]; then
        warn "Манифест транзакции не найден. Откат невозможен."
        return
    fi

    while IFS=$'\t' read -r target status _orig_hash backup_path; do
        if [[ "$status" == "present" ]]; then
            if [[ -f "$backup_path" ]]; then
                cp -p "$backup_path" "$target" 2>/dev/null || cp "$backup_path" "$target"
                log "Восстановлен исходный файл: $target"
            fi
        elif [[ "$status" == "absent" ]]; then
            rm -f "$target" 2>/dev/null || true
            log "Удален файл, созданный во время транзакции: $target"
        fi
    done < "$MANIFEST_LOG"

    # Удаление любых новых файлов в NGINX_RELAYS_DIR, созданных во время транзакции
    if [[ -d "${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}" ]]; then
        while IFS= read -r -d '' cur_conf; do
            if [[ ! -f "$TXN_DIR/initial_nginx_relays.txt" ]] || ! grep -Fxq "$cur_conf" "$TXN_DIR/initial_nginx_relays.txt" 2>/dev/null; then
                rm -f "$cur_conf" 2>/dev/null || true
                log "Удален новый Nginx конфиг, созданный во время транзакции: $cur_conf"
            fi
        done < <(find "${NGINX_RELAYS_DIR:-/etc/nginx/just1k_relays.d}" -type f -name "*.conf" -print0 2>/dev/null)
    fi

    rm -rf "${TXN_DIR:-}"
    MANIFEST_LOG=""

    ensure_xray_config_permissions "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"

    # Восстановление рабочего состояния сервисов
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi
    if [[ -n "${XRAY_CONFIG:-}" && -f "${XRAY_CONFIG:-}" && -n "${XRAY_BIN:-}" && -x "${XRAY_BIN:-}" ]]; then
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
            if declare -f safe_restart_xray >/dev/null 2>&1; then
                safe_restart_xray >/dev/null 2>&1 || true
            elif [[ ! -f "${STATE_DIR:-/etc/just1knode}/traffic_limit_exceeded" && ! -f "${STATE_DIR:-/etc/just1knode}/traffic_cutoff.active" ]]; then
                systemctl restart xray 2>/dev/null || true
            fi
        fi
    fi

    log "Откат транзакции завершен."
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
    elif action == 'upsert_peer':
        peer = json.loads(arg1)
        if not isinstance(peer, dict) or not peer.get('code'):
            raise ValueError('peer must be dict with code')
        peers = data.get('peers')
        if not isinstance(peers, list):
            peers = []
        code = str(peer['code']).strip().lower()
        peer['code'] = code
        peers = [p for p in peers if isinstance(p, dict) and str(p.get('code', '')).strip().lower() != code]
        peers.append(peer)
        data['peers'] = peers
    elif action == 'remove_peer':
        code = arg1.strip().lower()
        peers = data.get('peers')
        if isinstance(peers, list):
            data['peers'] = [p for p in peers if isinstance(p, dict) and str(p.get('code', '')).strip().lower() != code]
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

get_state_json_val() {
    local key="$1"
    local default_json="${2:-null}"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "$default_json"
        return 0
    fi
    python3 -c "
import sys, json
f, k, d = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(f, 'r', encoding='utf-8', errors='replace') as fp:
        data = json.load(fp)
    print(json.dumps(data[k], ensure_ascii=False) if k in data else d)
except Exception:
    print(d)
" "$STATE_FILE" "$key" "$default_json"
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

get_peers_json() {
    get_state_json_val "peers" "[]"
}

upsert_peer_json() {
    _state_mutate_json "upsert_peer" "$1"
}

remove_peer_json() {
    _state_mutate_json "remove_peer" "$1"
}

get_links_json() {
    local lf="${LINKS_FILE:-${STATE_DIR}/links.json}"
    if [[ ! -f "$lf" ]]; then
        echo "{}"
        return 0
    fi
    python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fp:
        d = json.load(fp)
    print(json.dumps(d if isinstance(d, dict) else {}, ensure_ascii=False))
except Exception:
    print("{}")
' "$lf"
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

has_active_xray_config() {
    local role
    role="$(get_state_val "role" "unconfigured")"
    if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then
        return 0
    fi
    return 1
}
