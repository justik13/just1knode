#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Движок независимых транспортных модулей (Fault Isolation)
# =============================================================================

LOADED_TRANSPORT_MODULES=()
BROKEN_MODULE_IDS=()
BROKEN_MODULE_REASONS=()

_modules_transports_dir() {
    if [[ -n "${MODULES_TRANSPORTS_DIR:-}" ]]; then
        echo "$MODULES_TRANSPORTS_DIR"
        return 0
    fi
    local root_dir="${SCRIPT_DIR:-${INSTALL_DIR:-/opt/just1knode}}"
    echo "${root_dir%/}/modules/transports"
}

is_module_loaded() {
    local target="$1"
    local m
    for m in "${LOADED_TRANSPORT_MODULES[@]}"; do
        [[ "$m" == "$target" ]] && return 0
    done
    return 1
}

is_module_broken() {
    local target="$1"
    local m
    for m in "${BROKEN_MODULE_IDS[@]}"; do
        [[ "$m" == "$target" ]] && return 0
    done
    return 1
}

get_broken_module_reason() {
    local target="$1"
    local idx
    for ((idx = 0; idx < ${#BROKEN_MODULE_IDS[@]}; idx++)); do
        if [[ "${BROKEN_MODULE_IDS[$idx]}" == "$target" ]]; then
            echo "${BROKEN_MODULE_REASONS[$idx]}"
            return 0
        fi
    done
    return 1
}

_record_broken_module() {
    local mod_id="$1"
    local reason="$2"
    reason="$(echo "$reason" | tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-240)"
    BROKEN_MODULE_IDS+=("$mod_id")
    BROKEN_MODULE_REASONS+=("${reason:-Неизвестная ошибка модуля}")
    if declare -F warn >/dev/null 2>&1; then
        warn "Модуль '${mod_id}' изолирован из-за ошибки и не загружен: ${reason}"
    fi
}

_persist_module_errors_json() {
    local state_dir="${STATE_DIR:-/etc/just1knode}"
    local err_file="${MODULE_ERRORS_FILE:-${state_dir}/module_errors.json}"
    [[ -d "$state_dir" ]] || return 0
    [[ -w "$state_dir" ]] || return 0

    local args=()
    local idx
    for ((idx = 0; idx < ${#BROKEN_MODULE_IDS[@]}; idx++)); do
        args+=("${BROKEN_MODULE_IDS[$idx]}" "${BROKEN_MODULE_REASONS[$idx]}")
    done

    python3 - "$err_file" "${args[@]}" <<'PYEOF' 2>/dev/null || true
import json, os, sys, tempfile

out_path = sys.argv[1]
items = sys.argv[2:]
errors = {}
for i in range(0, len(items) - 1, 2):
    errors[items[i]] = items[i + 1]

d = os.path.dirname(os.path.abspath(out_path))
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(errors, f, indent=2, ensure_ascii=False)
    f.flush()
os.chmod(tmp, 0o644)
os.replace(tmp, out_path)
PYEOF
}

load_all_transport_modules() {
    LOADED_TRANSPORT_MODULES=()
    BROKEN_MODULE_IDS=()
    BROKEN_MODULE_REASONS=()

    local t_dir
    t_dir="$(_modules_transports_dir)"
    if [[ ! -d "$t_dir" ]]; then
        _persist_module_errors_json
        return 0
    fi

    local mod_files=()
    local f
    while IFS= read -r f; do
        [[ -n "$f" ]] && mod_files+=("$f")
    done < <(find "$t_dir" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort)

    local mod_file mod_id syn_err sub_err meta_json spec_json kind
    for mod_file in "${mod_files[@]}"; do
        mod_id="$(basename "$mod_file" .sh)"
        [[ "$mod_id" == _* ]] && continue
        if [[ ! "$mod_id" =~ ^[a-z0-9_]+$ ]]; then
            _record_broken_module "$mod_id" "Недопустимое имя файла модуля"
            continue
        fi

        if ! syn_err="$(bash -n "$mod_file" 2>&1)"; then
            _record_broken_module "$mod_id" "Синтаксическая ошибка: ${syn_err}"
            continue
        fi

        if ! sub_err="$(
            (
                set -e
                # shellcheck source=/dev/null
                source "$mod_file"
                declare -F "${mod_id}_meta" >/dev/null
                declare -F "${mod_id}_install" >/dev/null
                declare -F "${mod_id}_uninstall" >/dev/null
                declare -F "${mod_id}_status_label" >/dev/null
            ) 2>&1
        )"; then
            _record_broken_module "$mod_id" "Ошибка контракта модуля: ${sub_err}"
            continue
        fi

        # shellcheck source=/dev/null
        if ! source "$mod_file"; then
            _record_broken_module "$mod_id" "Ошибка загрузки (source)"
            continue
        fi

        meta_json="$("${mod_id}_meta" 2>/dev/null || true)"
        if ! kind="$(python3 -c '
import json, sys
m = json.loads(sys.argv[1])
assert isinstance(m, dict)
assert m.get("id") == sys.argv[2]
print(m.get("kind", "transport"))
' "$meta_json" "$mod_id" 2>/dev/null)"; then
            _record_broken_module "$mod_id" "Некорректные метаданные (${mod_id}_meta)"
            continue
        fi

        if [[ "$kind" == "cdn" ]]; then
            if ! declare -F "${mod_id}_spec" >/dev/null 2>&1; then
                _record_broken_module "$mod_id" "Отсутствует функция ${mod_id}_spec для CDN-модуля"
                continue
            fi
            spec_json="$("${mod_id}_spec" 2>/dev/null || true)"
            if ! python3 -c '
import json, sys
s = json.loads(sys.argv[1])
assert isinstance(s, dict)
for req in ("port", "tag", "subpath", "upstream", "uplinkHTTPMethod", "uplinkDataPlacement", "xPaddingPlacement", "cidrs"):
    assert req in s
assert isinstance(s["cidrs"], list)
' "$spec_json" 2>/dev/null; then
                _record_broken_module "$mod_id" "Некорректная спецификация (${mod_id}_spec)"
                continue
            fi
        fi

        LOADED_TRANSPORT_MODULES+=("$mod_id")
    done

    _persist_module_errors_json
    return 0
}

get_module_meta_field() {
    local mod_id="$1"
    local field="$2"
    local default_val="${3:-}"
    if ! declare -F "${mod_id}_meta" >/dev/null 2>&1; then
        echo "$default_val"
        return 0
    fi
    local meta_json
    meta_json="$("${mod_id}_meta" 2>/dev/null || echo "{}")"
    python3 -c '
import json, sys
try:
    m = json.loads(sys.argv[1])
    val = m.get(sys.argv[2])
    if val is None:
        print(sys.argv[3])
    elif isinstance(val, list):
        print(",".join(str(x) for x in val))
    elif isinstance(val, bool):
        print("true" if val else "false")
    else:
        print(val)
except Exception:
    print(sys.argv[3])
' "$meta_json" "$field" "$default_val" 2>/dev/null || echo "$default_val"
}

get_child_modules_for() {
    local parent_id="$1"
    local m p_val
    for m in "${LOADED_TRANSPORT_MODULES[@]}"; do
        p_val="$(get_module_meta_field "$m" "parent" "")"
        [[ "$p_val" == "$parent_id" ]] && echo "$m"
    done
}

is_any_child_module_enabled() {
    local parent_id="$1"
    local m
    while IFS= read -r m; do
        [[ -z "$m" ]] && continue
        if is_module_enabled "$m"; then
            return 0
        fi
    done < <(get_child_modules_for "$parent_id")

    # Дополнительная проверка state.json на случай, если дочерний CDN-модуль сломан, но ещё числится включённым
    local cdn_active
    cdn_active="$(python3 -c '
import json, sys
try:
    mods = json.load(open(sys.argv[1], encoding="utf-8")).get("modules", {})
except Exception:
    mods = {}
for k, v in (mods.items() if isinstance(mods, dict) else []):
    if k.startswith("cdn_") and isinstance(v, dict) and v.get("enabled") is True:
        print("1")
        sys.exit(0)
print("0")
' "${STATE_FILE:-/etc/just1knode/state.json}" 2>/dev/null || echo "0")"
    [[ "$cdn_active" == "1" ]]
}

export_loaded_cdn_specs_json() {
    local pairs=()
    local m kind spec_json
    for m in "${LOADED_TRANSPORT_MODULES[@]}"; do
        kind="$(get_module_meta_field "$m" "kind" "transport")"
        if [[ "$kind" == "cdn" ]] && declare -F "${m}_spec" >/dev/null 2>&1; then
            spec_json="$("${m}_spec" 2>/dev/null || true)"
            if [[ -n "$spec_json" ]]; then
                pairs+=("$m" "$spec_json")
            fi
        fi
    done
    python3 - "${pairs[@]}" <<'PYEOF'
import json, sys
items = sys.argv[1:]
specs = {}
for i in range(0, len(items) - 1, 2):
    try:
        specs[items[i]] = json.loads(items[i + 1])
    except Exception:
        continue
print(json.dumps(specs, ensure_ascii=False))
PYEOF
}

# Общие обработчики жизненного цикла CDN-модулей (параметризованные через <id>_spec)
cdn_module_status_label() {
    local mod_key="$1"
    if is_module_broken "$mod_key"; then
        echo -e "${RED}🔴 Ошибка модуля (изолирован)${NC}"
        return 0
    fi
    if is_module_enabled "$mod_key"; then
        local c_dom
        c_dom="$(get_module_val "$mod_key" "cdn_domain" "")"
        [[ -n "$c_dom" ]] && echo -e "${GREEN}🟢 Активен (${c_dom})${NC}" || echo -e "${GREEN}🟢 Активен${NC}"
    else
        echo -e "${YELLOW}⚪ Не установлен${NC}"
    fi
}

cdn_module_install() {
    local mod_key="$1"
    check_root
    init_state_dir

    if is_module_broken "$mod_key"; then
        warn "Модуль '${mod_key}' изолирован из-за ошибки и не может быть установлен."
        return 1
    fi
    if ! declare -F "${mod_key}_spec" >/dev/null 2>&1; then
        warn "Спецификация CDN-модуля '${mod_key}' не загружена."
        return 1
    fi
    if ! is_module_enabled "vless_xhttp"; then
        warn "Сначала установите [2] VLESS XHTTP (Базовый)!"
        return 1
    fi

    local spec_json label port tag def_primary
    spec_json="$("${mod_key}_spec" 2>/dev/null || echo "{}")"
    read -r label port tag def_primary < <(python3 -c '
import json, sys
s = json.loads(sys.argv[1])
print(
    str(s.get("label") or sys.argv[2]).replace(" ", "_"),
    int(s.get("port") or 8003),
    str(s.get("tag") or "just1k-wl-default"),
    "1" if s.get("primary_cdn_default") else "0",
)
' "$spec_json" "$mod_key" 2>/dev/null)
    label="${label//_/ }"

    local def_cdn_dom input_cdn_dom=""
    def_cdn_dom="$(get_module_val "$mod_key" "cdn_domain" "")"
    [[ -z "$def_cdn_dom" ]] && def_cdn_dom="$(get_state_val "cdn_domain" "")"
    [[ -z "$def_cdn_dom" || "$def_cdn_dom" == "-" ]] && def_cdn_dom="$(get_state_val "domain" "")"

    if [[ -t 0 ]]; then
        read -rp "CDN-домен для ${label} [по умолчанию: ${def_cdn_dom}]: " input_cdn_dom || true
        input_cdn_dom="${input_cdn_dom:-$def_cdn_dom}"
        input_cdn_dom="$(normalize_domain "$input_cdn_dom" 2>/dev/null || echo "$input_cdn_dom")"
    else
        input_cdn_dom="$def_cdn_dom"
    fi

    if [[ -z "$input_cdn_dom" ]] || ! validate_fqdn "$input_cdn_dom" 2>/dev/null; then
        warn "Укажите корректный FQDN домен для ${label}."
        return 1
    fi

    local prev_json prev_root_cdn
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get(sys.argv[2], {})))
except Exception:
    print("{}")
' "$STATE_FILE" "$mod_key" 2>/dev/null || echo "{}")"
    prev_root_cdn="$(get_state_val "cdn_domain" "")"

    local mod_json
    mod_json="$(python3 -c 'import json,sys; print(json.dumps({"enabled": True, "provider": sys.argv[1], "port": int(sys.argv[2]), "tag": sys.argv[3], "cdn_domain": sys.argv[4]}))' "$mod_key" "$port" "$tag" "$input_cdn_dom")"
    set_module_config "$mod_key" "$mod_json"

    if [[ "$def_primary" == "1" || -z "$prev_root_cdn" || "$prev_root_cdn" == "-" ]]; then
        set_state_val "cdn_domain" "$input_cdn_dom"
    fi

    if ! apply_v2_hub_configuration; then
        if [[ "$prev_json" == "{}" ]]; then
            remove_module_config "$mod_key"
        else
            set_module_config "$mod_key" "$prev_json"
        fi
        [[ -n "$prev_root_cdn" ]] && set_state_val "cdn_domain" "$prev_root_cdn"
        warn "Не удалось применить конфигурацию ${label}. Откат выполнен."
        return 1
    fi

    log "✔ Субмодуль ${label} (порт ${port}) успешно активирован."
    return 0
}

cdn_module_uninstall() {
    local mod_key="$1"
    check_root
    init_state_dir
    if ! is_module_enabled "$mod_key"; then
        info "Субмодуль ${mod_key} не установлен."
        return 0
    fi

    local prev_json
    prev_json="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        print(json.dumps(json.load(f).get("modules", {}).get(sys.argv[2], {})))
except Exception:
    print("{}")
' "$STATE_FILE" "$mod_key" 2>/dev/null || echo "{}")"

    local prev_root_cdn next_root_cdn
    prev_root_cdn="$(get_state_val "cdn_domain" "")"

    remove_module_config "$mod_key"

    next_root_cdn="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        st = json.load(f)
except Exception:
    st = {}
mods = st.get("modules") if isinstance(st.get("modules"), dict) else {}
found = ""
for k, m in mods.items():
    if str(k).startswith("cdn_") and isinstance(m, dict) and m.get("enabled"):
        d = str(m.get("cdn_domain") or m.get("domain") or "").strip()
        if d and d != "-":
            found = d
            break
print(found)
' "$STATE_FILE" 2>/dev/null || echo "")"
    set_state_val "cdn_domain" "$next_root_cdn"

    if ! apply_v2_hub_configuration; then
        set_module_config "$mod_key" "$prev_json"
        set_state_val "cdn_domain" "$prev_root_cdn"
        warn "Ошибка пересборки после удаления ${mod_key}. Откат."
        return 1
    fi

    log "✔ Субмодуль ${mod_key} успешно удален."
    return 0
}
