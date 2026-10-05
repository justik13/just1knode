# 📚 JUST1KNODE DOCUMENTATION HUB

Централизованный каталог инженерной и технической документации узлов **JUST1KNODE**.

---

## 📑 Каталог документов

### 1. [White Internet («Белый Интернет») Master Guide](WL/WHITELIST_MASTER_GUIDE.md)
* **Назначение:** Инженерно-технический справочник по работе в условиях жестких белых списков (Default-Drop). Архитектура VLESS XHTTP over Yandex Cloud CDN, Bodiless GET Uplink (защита от 413 ошибок на CDN), Nginx Zero Buffering, VLESS-Vision туннелирование Origin ➔ Exit, протокол INCY, а также детальный аудит транспорта XDRIVE (`network: "xdrive"` из Xray-core v26.9.30).

### 2. [AmneziaWG 2.0 Technical Reference](amnezia_docs.md)
* **Назначение:** Спецификация используемого протокола AmneziaWG 2.0 (`amneziawg2`), форматы файлов `.conf` и `.vpn`, схема URI `vpn://...`, обфускационные параметры (`Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`), особенности интеграции с нативным микросервисом `amnezia-api` и чеклист валидации.

### 3. [INCY Client Master Guide](INCY_MASTER_GUIDE.md)
* **Назначение:** Руководство по интеграции с клиентским приложением INCY (платформы iOS, Android, macOS, Windows). Форматы конфигураций (Full Xray JSON, URI с `extra`, HTTP Subscription Feed, `incy://` deep links), оптимизация памяти Network Extension на iOS и обход платформенных ограничений.

### 4. [Сетевая безопасность, ТСПУ и модель угроз](NETWORK_SECURITY_AND_TSPU.md)
* **Назначение:** Модель угроз ТСПУ/РКН, механизмы сетевой фильтрации (Active Probing / DPI Spiders), архитектура Zero-Signature (строгое закрытие портов, сброс прямых IP-проб), защита управляющих портов через UFW и реестр исследовательских ресурсов (NTC Party, Net4People, Zapret).

### 5. Реестры источников и исследований
* **[main_source.txt](main_source.txt):** Официальные репозитории, апстримы используемых ядер (Xray, AmneziaWG) и документация облачных провайдеров.
* **[research.txt](research.txt):** Технические исследования, RFC, бенчмарки, аналитические разборы DPI/ТСПУ (net4people, Хабр, постквантовый TLS, SelfSteal SNI).
* **[projects.txt](projects.txt):** Сторонние проекты, форки и идеи для справки.
