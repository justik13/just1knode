# Release Notes — just1knode v2.5.0

## Что изменилось
- Подняли версию ноды до `2.5.0` в `VERSION`, `pyproject.toml` и `just1knode.sh`.
- Добавили актуальные заметки о релизе и команды для проверки узлов.

## Инварианты
- Управление: CLI `just1knode.sh` (`doctor`, `heal`, `update`, `limit`).
- Сеть: изоляция службы `xray-api:8444` через systemd и фаервол UFW с доступом только для IP бота.
- Протоколы: Xray VLESS (Direct TLS) и VLESS over XHTTP с каскадом Origin/Relay и ротацией эпох. Полная очистка от легаси AmneziaWG.

## Команды

Диагностика перед обновлением:
```bash
sudo just1knode doctor
```

Обновление:
```bash
sudo just1knode update
```
