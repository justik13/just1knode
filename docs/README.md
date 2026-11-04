# 📚 JUST1KNODE DOCUMENTATION HUB

Централизованный каталог инженерной и технической документации узлов **JUST1KNODE**.

---

## 📑 Каталог документов

### 1. [Белые списки в РФ (Whitelist) Master Guide](WL/WHITELIST_MASTER_GUIDE.md)
* **Назначение:** Полный независимый исследовательский справочник и база знаний по цензурной инфраструктуре ТСПУ/РКН и методам работы в условиях жестких белых списков (Default-Drop). Архитектура VLESS XHTTP over Yandex Cloud CDN, Bodiless GET Uplink (защита от 413 ошибок на CDN), Nginx Zero Buffering, VLESS-Vision туннелирование Origin ➔ Exit, а также детальный аудит транспорта XDRIVE (`network: "xdrive"` из Xray-core v26.10.x).

### 2. [INCY Client Master Guide](INCY_MASTER_GUIDE.md)
* **Назначение:** Руководство по интеграции с клиентским приложением INCY (платформы iOS, Android, macOS, Windows). Форматы конфигураций (Full Xray JSON, URI с `extra`, HTTP Subscription Feed, `incy://` deep links), оптимизация памяти Network Extension на iOS и обход платформенных ограничений.

### 3. [Сетевая безопасность, ТСПУ и модель угроз](NETWORK_SECURITY_AND_TSPU.md)
* **Назначение:** Модель угроз ТСПУ/РКН, механизмы сетевой фильтрации (Active Probing / DPI Spiders), архитектура Zero-Signature (строгое закрытие портов, сброс прямых IP-проб), защита управляющих портов через UFW и реестр исследовательских ресурсов (NTC Party, Net4People, Zapret).

### 4. Реестры источников и исследований
* **[main_source.txt](main_source.txt):** Официальные репозитории, апстримы используемых ядер (Xray) и документация облачных провайдеров.
* **[research.txt](research.txt):** Технические исследования, RFC, бенчмарки, аналитические разборы DPI/ТСПУ (трилогия 0ka #997088/#1003852/#1010336, hyperion_cs #1044396, net4people, постквантовый TLS, SelfSteal SNI).
* **[projects.txt](projects.txt):** Сторонние проекты, форки и идеи для справки.
*(Историческая документация по выведенному из эксплуатации AmneziaWG сохранена в архивной ветке `archive/amnezia-awg`).*
