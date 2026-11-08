# Release Notes — just1knode v2.5.1

## Что изменилось
- Подняли версию ноды до `2.5.1` в `VERSION`, `pyproject.toml` и `just1knode.sh`.
- **Гибкость портов Relay:** снят жесткий запрет порта 443 для Relay на выделенных узлах без VLESS Direct (`has_vless == 0`), что позволяет скрывать туннель под стандартный HTTPS.
- **Интеллектуальные порты для гибридных узлов:** при наличии VLESS Direct порт 443 отдается клиентам, а для Relay предлагаются безопасные порты (`8443` по умолчанию, `2053`, `2083`, `10443`).
- **Zero-Signature Fallback для Relay:** на инбаунд Relay (`inbound-tls`) добавлен fallback на `127.0.0.1:80` (Nginx 404), устраняя сигнатуру сброса соединения при активном сканировании.
- Добавлена защита от коллизии портов в `install_vless_direct_node`, если Relay уже занимает порт 443.

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
