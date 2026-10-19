# Release Notes — just1knode v2.5.0

## Обзор релиза / Overview
Официальный релиз агента серверных узлов **just1knode** версии **v2.5.0** в рамках комплексной стабилизации платформы just1k.

## Изменения в версии v2.5.0 / Changelog

### Синхронизация версий
- Версия в `pyproject.toml` обновлена до `2.5.0`.
- Версия в `VERSION` обновлена до `2.5.0`.
- В `just1knode.sh` дефолтная fallback-версия `JUST1KNODE_VERSION` обновлена до `2.5.0`.

### Архитектурные инварианты
- **CLI команды:** Диспетчер `just1knode.sh` (`doctor`, `heal`, `update`, `limit`).
- **Сетевая изоляция:** Защита микросервисов `xray-api:8444` и `amnezia-api:8443` через systemd (`ProtectSystem=strict`, `PrivateTmp=true`) и фаервол UFW со строгой привязкой к `BOT_IP` и `ORIGIN_IP` в режиме fail-closed.
- **Поддержка протоколов:** AmneziaWG (AWG 2.0–3.1, контейнер `amnezia-awg2`), Xray VLESS over XHTTP с Origin/Relay каскадом, ротацией эпох и Nginx Zero Buffering.

---

## Диагностика и обновление

### Pre-flight проверка узла (Read-Only)
```bash
sudo just1knode doctor
```

### Обновление узла
```bash
sudo just1knode update
```
