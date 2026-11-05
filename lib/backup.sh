#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE - Библиотека резервного копирования (lib/backup.sh)
# =============================================================================

BACKUP_DIR="${BACKUP_DIR:-/var/backups/just1knode}"
BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-10}"
LAST_BACKUP_PATH=""

if ! declare -f log >/dev/null 2>&1; then
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -f "${_lib_dir}/common.sh" ]]; then
        # shellcheck source=lib/common.sh
        source "${_lib_dir}/common.sh"
    fi
    unset _lib_dir
fi

if ! declare -f ensure_xray_config_permissions >/dev/null 2>&1; then
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [[ -f "${_lib_dir}/state.sh" ]]; then
        # shellcheck source=lib/state.sh
        source "${_lib_dir}/state.sh"
    fi
    unset _lib_dir
fi

create_backup() {
    local target="$1"
    LAST_BACKUP_PATH=""
    if [[ -f "$target" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR" 2>/dev/null || true
        local bkp
        bkp="${BACKUP_DIR}/$(basename "$target")_$(date +%Y%m%d_%H%M%S).bak"
        cp -p "$target" "$bkp"
        chmod 600 "$bkp" 2>/dev/null || true
        LAST_BACKUP_PATH="$bkp"
        log "Создан защитный бэкап: $bkp"

        # Ограничение накопления резервных копий (Retention Policy)
        local base_name
        base_name="$(basename "$target")"
        local old_backups
        old_backups="$(find "$BACKUP_DIR" -maxdepth 1 -name "${base_name}_*.bak" -type f 2>/dev/null | sort -r | tail -n +$((BACKUP_RETENTION_COUNT + 1)) || true)"
        if [[ -n "$old_backups" ]]; then
            while IFS= read -r f; do
                [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
            done <<< "$old_backups"
        fi
    fi
}

backup_node() {
    local bak_file="${1:-}"
    if [[ -z "$bak_file" ]]; then
        mkdir -p "${BACKUP_DIR:-/var/backups/just1knode}"
        bak_file="${BACKUP_DIR:-/var/backups/just1knode}/xray_node_$(date +%Y%m%d_%H%M%S).tar.gz"
    fi
    mkdir -p "$(dirname "$bak_file")"
    chmod 700 "$(dirname "$bak_file")" 2>/dev/null || true

    local targets=()
    if [[ -d "/usr/local/etc/xray" ]]; then
        targets+=("usr/local/etc/xray")
    fi
    local state_dir="${STATE_DIR:-/etc/just1knode}"
    state_dir="${state_dir#/}"
    if [[ -d "/$state_dir" ]]; then
        targets+=("$state_dir")
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        warn "Каталоги конфигураций Xray (/usr/local/etc/xray, /etc/just1knode) не найдены для архивации."
        return 1
    fi

    log "Создание резервной копии конфигураций Xray в $bak_file..."
    if tar -czf "$bak_file" -C / "${targets[@]}" 2>/dev/null; then
        chmod 600 "$bak_file" 2>/dev/null || true
        log "✔ Резервная копия конфигураций Xray создана: $bak_file"
        echo "$bak_file"
        return 0
    else
        error "Ошибка при создании архива резервной копии: $bak_file"
        return 1
    fi
}

restore_node() {
    local bak_file="${1:-}"
    if [[ -z "$bak_file" ]]; then
        error "Укажите путь к архиву бэкапа: just1knode restore <путь_к_файлу.tar.gz>"
        return 1
    fi
    if [[ ! -f "$bak_file" ]]; then
        error "Файл резервной копии не найден: $bak_file"
        return 1
    fi

    check_root
    log "Восстановление конфигураций узла из $bak_file..."
    if tar -xzf "$bak_file" -C / 2>/dev/null; then
        log "✔ Конфигурации успешно восстановлены."
        if declare -f ensure_xray_config_permissions >/dev/null 2>&1; then
            ensure_xray_config_permissions "${XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
        fi
        local state_file="${STATE_FILE:-/etc/just1knode/state.json}"
        if [[ -f "$state_file" ]]; then
            chmod 660 "$state_file" 2>/dev/null || true
            chown root:xrayapi "$state_file" 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet xray 2>/dev/null || systemctl is-enabled --quiet xray 2>/dev/null; then
                systemctl restart xray 2>/dev/null || true
            fi
            if systemctl is-active --quiet xray-api 2>/dev/null || systemctl is-enabled --quiet xray-api 2>/dev/null; then
                systemctl restart xray-api 2>/dev/null || true
            fi
        fi
        log "✔ Восстановление узла успешно завершено."
        return 0
    else
        error "Ошибка при распаковке архива: $bak_file"
        return 1
    fi
}

