#!/usr/bin/env bash
# =============================================================================
# JUST1KNODE v2 - Независимый CDN-модуль: TurboFlare
# =============================================================================

cdn_turboflare_meta() {
    cat <<'EOF'
{
  "id": "cdn_turboflare",
  "kind": "cdn",
  "parent": "vless_xhttp",
  "label": "TurboFlare",
  "roles": ["ru_hub"],
  "order": 22
}
EOF
}

cdn_turboflare_spec() {
    cat <<'EOF'
{
  "label": "TurboFlare",
  "port": 8004,
  "tag": "just1k-wl-turboflare",
  "subpath": "turboflare",
  "upstream": "xray_xhttp_turboflare",
  "uplinkHTTPMethod": "POST",
  "uplinkDataPlacement": "body",
  "uplinkDataKey": "",
  "xPaddingPlacement": "header",
  "real_ip_header": "X-Real-IP",
  "options_rewrite": false,
  "primary_cdn_default": false,
  "cidrs": [
    "151.236.64.0/18", "62.152.61.0/24", "185.31.112.0/22", "185.141.225.0/24",
    "91.231.232.0/21", "91.238.108.0/22", "91.240.168.0/22", "78.159.248.0/21",
    "81.222.126.0/23", "46.42.184.0/21", "128.75.231.0/24", "195.211.0.0/16",
    "2a02:aec0::/32"
  ]
}
EOF
}

cdn_turboflare_status_label() {
    cdn_module_status_label "cdn_turboflare"
}

cdn_turboflare_install() {
    cdn_module_install "cdn_turboflare"
}

cdn_turboflare_uninstall() {
    cdn_module_uninstall "cdn_turboflare"
}
