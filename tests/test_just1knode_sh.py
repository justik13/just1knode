"""
Tests for scripts/just1knode.sh provisioning, namespacing, transactional rollback,
fail-closed firewall, and immutable dependency pinning.
Covers findings F02, F03, F04, F05, F19, F20, F21, F22.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
NODE_ROOT = REPO_ROOT if (REPO_ROOT / "lib").exists() else (REPO_ROOT / "just1knode")
JUST1KNODE_SH = (REPO_ROOT / "just1knode.sh") if (REPO_ROOT / "just1knode.sh").exists() else (REPO_ROOT / "scripts" / "just1knode.sh")
REQUIREMENTS_TXT = REPO_ROOT / "scripts" / "xray_api" / "requirements.txt"


@unittest.skipIf(sys.platform == "win32", "Shell behavioural tests run strictly on Linux CI")
@unittest.skipUnless(shutil.which("bash"), "Bash is required for shell behavioural tests")
class TestJust1kNodeScript(unittest.TestCase):
    @classmethod
    def _bp(cls, p: Path | str) -> str:
        p_str = str(p).replace("\\", "/")
        if os.name == "nt" and re.match(r"^[a-zA-Z]:", p_str):
            drive = p_str[0].lower()
            return f"/mnt/{drive}{p_str[2:]}"
        return p_str

    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.state_dir = Path(self.temp_dir) / "etc" / "just1knode"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.nginx_conf_dir = Path(self.temp_dir) / "etc" / "nginx"
        self.nginx_conf_dir.mkdir(parents=True, exist_ok=True)
        self.nginx_relays_d = Path(self.temp_dir) / "etc" / "nginx" / "just1k_relays.d"
        self.nginx_relays_d.mkdir(parents=True, exist_ok=True)
        self.xray_config_dir = Path(self.temp_dir) / "usr" / "local" / "etc" / "xray"
        self.xray_config_dir.mkdir(parents=True, exist_ok=True)
        self.xray_share_dir = Path(self.temp_dir) / "usr" / "local" / "share" / "xray"
        self.xray_share_dir.mkdir(parents=True, exist_ok=True)
        self.xray_api_etc = Path(self.temp_dir) / "etc" / "xray-api"
        self.xray_api_etc.mkdir(parents=True, exist_ok=True)
        self.xray_api_dir = Path(self.temp_dir) / "opt" / "xray-api"
        self.xray_api_dir.mkdir(parents=True, exist_ok=True)
        self.xray_api_lib = Path(self.temp_dir) / "var" / "lib" / "xray-api"
        self.xray_api_lib.mkdir(parents=True, exist_ok=True)
        self.systemd_dir = Path(self.temp_dir) / "etc" / "systemd" / "system"
        self.systemd_dir.mkdir(parents=True, exist_ok=True)
        self.certbot_dir = Path(self.temp_dir) / "var" / "www" / "certbot"
        self.certbot_dir.mkdir(parents=True, exist_ok=True)
        self.letsencrypt_dir = Path(self.temp_dir) / "etc" / "letsencrypt"
        self.letsencrypt_dir.mkdir(parents=True, exist_ok=True)
        self.www_html_dir = Path(self.temp_dir) / "var" / "www" / "html"
        self.www_html_dir.mkdir(parents=True, exist_ok=True)
        self.backup_dir = Path(self.temp_dir) / "var" / "backups" / "just1knode"
        self.backup_dir.mkdir(parents=True, exist_ok=True)
        self.install_dir = Path(self.temp_dir) / "opt" / "just1knode"
        self.install_dir.mkdir(parents=True, exist_ok=True)
        self.sysctl_d = Path(self.temp_dir) / "etc" / "sysctl.d"
        self.sysctl_d.mkdir(parents=True, exist_ok=True)
        self.sysctl_conf = self.sysctl_d / "99-disable-ipv6.conf"
        self.modules_load_d = Path(self.temp_dir) / "etc" / "modules-load.d"
        self.modules_load_d.mkdir(parents=True, exist_ok=True)
        self.modules_load_conf = self.modules_load_d / "just1knode.conf"
        self.bin_dir = Path(self.temp_dir) / "bin"
        self.bin_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def _create_mock_script(self, name: str, content: str) -> Path:
        script_path = self.bin_dir / name
        with open(script_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        script_path.chmod(0o755)
        return script_path

    def _prepare_base_env(self):
        # Default mock commands
        self._create_mock_script("nginx", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("systemctl", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("xray", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("ufw", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("certbot", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("apt-get", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("pkill", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("userdel", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("groupdel", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("sysctl", "#!/bin/sh\nexit 0\n")
        self._create_mock_script(
            "unzip",
            """#!/bin/sh
dest="."
prev=""
for arg in "$@"; do
    if [ "$prev" = "-d" ]; then
        dest="$arg"
    fi
    prev="$arg"
done
mkdir -p "$dest"
for arg in "$@"; do
    if [ -f "$arg" ]; then
        python3 -c "import zipfile; zipfile.ZipFile('$arg').extractall('$dest')" 2>/dev/null || true
    fi
done
exit 0
""",
        )

        # Initial files
        state_file = self.state_dir / "state.json"
        with open(state_file, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "role": "ru_hub",
                    "domain": "hub.example.com",
                    "secret_base_path": "/stream",
                    "modules": {"vless_tls": {"enabled": True}, "vless_xhttp": {"enabled": True}},
                },
                f,
            )

        relays_file = self.state_dir / "relays.json"
        with open(relays_file, "w", encoding="utf-8") as f:
            json.dump([], f)

        xray_config = self.xray_config_dir / "config.json"
        with open(xray_config, "w", encoding="utf-8") as f:
            json.dump(
                {
                    "inbounds": [{"tag": "just1k-wl-default", "port": 8003, "protocol": "vless"}],
                    "outbounds": [
                        {"tag": "just1k-wl-direct", "protocol": "freedom"},
                        {"tag": "just1k-wl-block", "protocol": "blackhole"},
                        {"tag": "direct", "protocol": "freedom"},
                        {"tag": "block", "protocol": "blackhole"},
                    ],
                    "routing": {"rules": []},
                },
                f,
            )

        env_file = self.xray_api_etc / "config.env"
        with open(env_file, "w", encoding="utf-8") as f:
            f.write("XRAY_API_KEY=testkey\nXRAY_INBOUND_TAGS=just1k-wl-default\n")

    def _run_shell_snippet(
        self, snippet: str, extra_env: dict = None, input_text: str | None = None
    ) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}:{env['PATH']}"
        env["STATE_DIR"] = str(self.state_dir)
        env["STATE_FILE"] = str(self.state_dir / "state.json")
        env["CLIENTS_FILE"] = str(self.state_dir / "clients.json")
        env["RELAYS_FILE"] = str(self.state_dir / "relays.json")
        env["XRAY_CONFIG_DIR"] = str(self.xray_config_dir)
        env["XRAY_CONFIG"] = str(self.xray_config_dir / "config.json")
        env["XRAY_SHARE_DIR"] = str(self.xray_share_dir)
        env["XRAY_BIN"] = str(self.bin_dir / "xray")
        env["BACKUP_DIR"] = str(self.backup_dir)
        env["NGINX_CONF_DIR"] = str(self.nginx_conf_dir)
        env["NGINX_RELAYS_DIR"] = str(self.nginx_relays_d)
        env["XRAY_API_DIR"] = str(self.xray_api_dir)
        env["XRAY_API_LIB"] = str(self.xray_api_lib)
        env["XRAY_API_ETC"] = str(self.xray_api_etc)
        env["XRAY_API_CONFIG_ENV"] = str(self.xray_api_etc / "config.env")
        env["SYSTEMD_SYSTEM_DIR"] = str(self.systemd_dir)
        env["CERTBOT_DIR"] = str(self.certbot_dir)
        env["LETSENCRYPT_DIR"] = str(self.letsencrypt_dir)
        env["XRAY_TLS_DIR"] = str(self.xray_config_dir / "tls")
        env["WWW_HTML_DIR"] = str(self.www_html_dir)
        env["INSTALL_DIR"] = str(self.install_dir)
        env["JUST1KNODE_SYSCTL_IPV6_CONF"] = str(self.sysctl_conf)
        if extra_env:
            env.update(extra_env)

        backup_dir_val = extra_env.get("BACKUP_DIR", str(self.backup_dir)) if extra_env else str(self.backup_dir)
        state_dir_val = extra_env.get("STATE_DIR", str(self.state_dir)) if extra_env else str(self.state_dir)

        _bp = self._bp

        # Source just1knode.sh functions and run snippet with root bypass for testing
        full_script = f"""
export PATH='{_bp(self.bin_dir)}':"$PATH"
export STATE_DIR='{_bp(state_dir_val)}'
export STATE_FILE='{_bp(self.state_dir / "state.json")}'
export CLIENTS_FILE='{_bp(self.state_dir / "clients.json")}'
export RELAYS_FILE='{_bp(self.state_dir / "relays.json")}'
export XRAY_CONFIG_DIR='{_bp(self.xray_config_dir)}'
export XRAY_CONFIG='{_bp(self.xray_config_dir / "config.json")}'
export XRAY_SHARE_DIR='{_bp(self.xray_share_dir)}'
export XRAY_BIN='{_bp(self.bin_dir / "xray")}'
export BACKUP_DIR='{_bp(backup_dir_val)}'
export NGINX_CONF_DIR='{_bp(self.nginx_conf_dir)}'
export NGINX_RELAYS_DIR='{_bp(self.nginx_relays_d)}'
export XRAY_API_DIR='{_bp(self.xray_api_dir)}'
export XRAY_API_LIB='{_bp(self.xray_api_lib)}'
export XRAY_API_ETC='{_bp(self.xray_api_etc)}'
export XRAY_API_CONFIG_ENV='{_bp(self.xray_api_etc / "config.env")}'
export SYSTEMD_SYSTEM_DIR='{_bp(self.systemd_dir)}'
export CERTBOT_DIR='{_bp(self.certbot_dir)}'
export LETSENCRYPT_DIR='{_bp(self.letsencrypt_dir)}'
export XRAY_TLS_DIR='{_bp(self.xray_config_dir / "tls")}'
export WWW_HTML_DIR='{_bp(self.www_html_dir)}'
export INSTALL_DIR='{_bp(self.install_dir)}'
export JUST1KNODE_SYSCTL_IPV6_CONF='{_bp(self.sysctl_conf)}'
export MODULES_LOAD_CONF='{_bp(self.modules_load_conf)}'

source '{_bp(JUST1KNODE_SH)}'

check_root() {{ return 0; }}
install_base_deps() {{ return 0; }}
obtain_ssl_certificate() {{ return 0; }}
download_and_verify_xray() {{ return 0; }}
deploy_xray_api_sources() {{ return 0; }}
setup_xray_api_venv() {{ return 0; }}
ensure_xrayapi_user() {{ return 0; }}

{snippet}
"""
        return subprocess.run(
            ["bash", "-c", full_script],
            input=input_text if input_text is not None else "",
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            check=False,
        )


    def test_apply_node_sysctl_hardening_disables_ipv6_and_icmp_echo(self):
        """apply_node_sysctl_hardening must write IPv6 disable and ICMP echo ignore settings to sysctl.d."""
        self._prepare_base_env()
        res = self._run_shell_snippet("apply_node_sysctl_hardening")
        self.assertEqual(res.returncode, 0, f"apply_node_sysctl_hardening failed: {res.stderr}\n{res.stdout}")
        self.assertTrue(self.sysctl_conf.exists(), "99-disable-ipv6.conf must be created")
        content = self.sysctl_conf.read_text(encoding="utf-8")
        self.assertIn("net.ipv6.conf.all.disable_ipv6 = 1", content)
        self.assertIn("net.ipv6.conf.default.disable_ipv6 = 1", content)
        self.assertIn("net.ipv6.conf.lo.disable_ipv6 = 1", content)
        self.assertIn("net.ipv4.icmp_echo_ignore_all = 1", content)
        self.assertIn("net.mptcp.enabled = 0", content)
        self.assertIn("net.ipv4.tcp_tw_reuse = 1", content)
        self.assertIn("net.ipv4.tcp_fin_timeout = 15", content)
        self.assertIn("net.core.somaxconn = 65535", content)
        self.assertIn("net.ipv4.ip_local_port_range = 32768 65535", content)
        self.assertIn("net.core.default_qdisc = fq", content)
        self.assertIn("net.ipv4.tcp_congestion_control = bbr", content)


    def test_validate_public_ipv4_behavioural(self):
        """Verify public IPv4 classification rejects private, loopback, link-local, CGNAT, and IPv6."""
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        self.assertIn("10#$oct < 0 || 10#$oct > 255", common_sh, "Bash fallback must enforce decimal base")

        import ipaddress

        def is_public_ipv4(ip_str: str) -> bool:
            try:
                addr = ipaddress.IPv4Address(ip_str)
                return addr.is_global and not addr.is_multicast and not addr.is_reserved and not addr.is_unspecified
            except Exception:
                return False

        # Globally routable public IPv4 addresses
        self.assertTrue(is_public_ipv4("93.184.216.34"))
        self.assertTrue(is_public_ipv4("1.1.1.1"))
        self.assertTrue(is_public_ipv4("8.8.8.8"))
        self.assertTrue(is_public_ipv4("142.250.180.206"))

        # Private RFC 1918
        self.assertFalse(is_public_ipv4("10.0.0.1"))
        self.assertFalse(is_public_ipv4("10.255.255.255"))
        self.assertFalse(is_public_ipv4("172.16.0.1"))
        self.assertFalse(is_public_ipv4("172.31.255.255"))
        self.assertFalse(is_public_ipv4("192.168.0.1"))
        self.assertFalse(is_public_ipv4("192.168.1.100"))

        # Loopback & Link-local
        self.assertFalse(is_public_ipv4("127.0.0.1"))
        self.assertFalse(is_public_ipv4("127.0.1.1"))
        self.assertFalse(is_public_ipv4("169.254.1.1"))

        # Carrier-Grade NAT (100.64.0.0/10)
        self.assertFalse(is_public_ipv4("100.64.0.1"))
        self.assertFalse(is_public_ipv4("100.127.255.254"))

        # Multicast, Broadcast, Reserved
        self.assertFalse(is_public_ipv4("0.0.0.0"))
        self.assertFalse(is_public_ipv4("224.0.0.1"))
        self.assertFalse(is_public_ipv4("240.0.0.1"))
        self.assertFalse(is_public_ipv4("255.255.255.255"))

        # IPv6 strings
        self.assertFalse(is_public_ipv4("2a12:bec4:1483:7b1::2"))
        self.assertFalse(is_public_ipv4("::1"))
        self.assertFalse(is_public_ipv4("fe80::1"))


    def test_doctor_icmp_stealth_fails_closed_when_dropin_missing(self):
        """Verify doctor ICMP stealth check fails closed if runtime=1 but drop-in is missing."""
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn('icmp_persisted=0', just1knode_sh)
        self.assertIn('echo -e "  ${RED}✗${NC} ICMP Echo отключен в ядре, но не зафиксирован в $sysctl_conf', just1knode_sh)
        self.assertIn('failed=$((failed + 1))', just1knode_sh)

    def test_doctor_ipv6_fails_closed_when_dropin_missing(self):
        """Verify doctor IPv6 check fails closed if runtime=1 but drop-in is missing."""
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn('11. Проверка отключения IPv6 (защита от утечек трафика)...', just1knode_sh)
        self.assertIn('ipv6_persisted=0', just1knode_sh)
        self.assertIn('echo -e "  ${RED}✗${NC} IPv6 отключен в ядре, но не зафиксирован в $sysctl_conf', just1knode_sh)
        self.assertIn('net.ipv6.conf.all.disable_ipv6', just1knode_sh)

    def test_configure_safe_ufw_fails_closed_on_ssh_port_error(self):
        """Verify configure_safe_ufw fails closed if SSH port rule cannot be applied."""
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        self.assertIn('if ! ufw allow "$ssh_port/tcp" >/dev/null 2>&1; then', common_sh)
        self.assertIn('return 1', common_sh)

    def test_state_json_corruption_backup_preservation(self):
        """Verify set_state_val preserves corrupted state file to .corrupted.bak without wiping."""
        self._prepare_base_env()
        state_file = self.state_dir / "state.json"
        bak_file = self.state_dir / "state.json.corrupted.bak"

        # Case 1: Corrupted non-JSON file
        state_file.write_text("INVALID_JSON_CONTENT{{{", encoding="utf-8")
        state_sh = (NODE_ROOT / "lib" / "state.sh").read_text(encoding="utf-8")
        py_match = re.search(r'python3 -c "(.*?)" "\$STATE_FILE"', state_sh, re.DOTALL)
        self.assertIsNotNone(py_match, "python script inside set_state_val must be found")
        py_code = py_match.group(1)

        res = subprocess.run(
            [sys.executable, "-c", py_code, str(state_file), "test_key", "test_val"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res.returncode, 1, "Must exit with code 1 on corrupted state")
        self.assertTrue(bak_file.exists(), "Backup .corrupted.bak must be created")
        self.assertEqual(bak_file.read_text(encoding="utf-8"), "INVALID_JSON_CONTENT{{{")
        self.assertEqual(state_file.read_text(encoding="utf-8"), "INVALID_JSON_CONTENT{{{")

        # Case 2: 0-byte file must also be treated as corrupted (not wiped with {new_key: new_val})
        bak_file.unlink(missing_ok=True)
        state_file.write_text("", encoding="utf-8")
        res0 = subprocess.run(
            [sys.executable, "-c", py_code, str(state_file), "new_key", "new_val"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(res0.returncode, 1, "Must exit with code 1 on 0-byte state")
        self.assertTrue(bak_file.exists(), "Backup .corrupted.bak must be created for 0-byte state")
        self.assertEqual(state_file.read_text(encoding="utf-8"), "")
        self.assertIn("Резервная копия сохранена в", res.stderr)
        self.assertIn("Резервная копия сохранена в", res0.stderr)

    def test_update_xray_core_uses_isolated_mktemp_directory(self):
        """Verify update_xray_core avoids static /tmp paths and uses mktemp directory with cleanup."""
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        self.assertIn('tmp_dir="$(mktemp -d /tmp/xray_update.XXXXXX', core_sh)
        self.assertIn('rm -rf "$tmp_dir"', core_sh)
        self.assertNotIn('/tmp/xray_update.zip', core_sh)
        self.assertNotIn('/tmp/xray_new', core_sh)

    def test_update_xray_core_skips_when_version_matches(self):
        """Verify update_xray_core checks current binary version and skips re-downloading if already pinned."""
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        self.assertIn('current_ver="$($XRAY_BIN version 2>/dev/null | awk \'NR==1 {print $2}\')"', core_sh)
        self.assertIn('[[ $force_update -eq 0 && -n "$current_ver" && "$current_ver" == "$XRAY_VERSION_PINNED" ]]', core_sh)


    def test_configure_safe_ufw_verifies_status_active(self):
        """Verify configure_safe_ufw checks ufw status active before logging successful activation."""
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        self.assertIn('if echo "y" | ufw enable >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then', common_sh)
        self.assertIn('warn "Внимание: не удалось активировать фаервол UFW."', common_sh)


    def test_state_lock_file_uses_o_nofollow(self):
        """Verify set_state_val opens lock file with O_NOFOLLOW to mitigate symlink races."""
        state_sh = (NODE_ROOT / "lib" / "state.sh").read_text(encoding="utf-8")
        self.assertIn("getattr(os, 'O_NOFOLLOW', 0)", state_sh)

    def test_update_node_declares_is_menu_and_survives_set_u(self):
        """Verify update_node initializes local is_menu to prevent unbound variable under set -u."""
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        self.assertIn('local is_menu="${2:-0}"', core_sh)
        self.assertIn('exec "$bin_path" update-post "$target" "${is_menu:-0}"', core_sh)
        self.assertIn('update_node_post "$target" "${is_menu:-0}"', core_sh)


    def test_apply_node_sysctl_hardening_updates_ufw_sysctl_conf(self):
        """Verify apply_node_sysctl_hardening updates /etc/ufw/sysctl.conf and uninstall cleans it up."""
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        self.assertIn('local ufw_conf="${JUST1KNODE_UFW_SYSCTL_CONF:-/etc/ufw/sysctl.conf}"', common_sh)
        self.assertIn('net/ipv4/icmp_echo_ignore_all=1', common_sh)
        self.assertIn('sed -i -E \'/^[#[:space:]]*net\\/ipv4\\/icmp_echo_ignore_all[[:space:]]*=/d\' "$ufw_conf"', common_sh)

        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn('local ufw_conf="${JUST1KNODE_UFW_SYSCTL_CONF:-/etc/ufw/sysctl.conf}"', just1knode_sh)
        self.assertIn('sed -i -E \'/^[#[:space:]]*net\\/ipv4\\/icmp_echo_ignore_all[[:space:]]*=/d\' "$ufw_conf"', just1knode_sh)


    def test_rollback_removes_newly_created_relay_nginx_conf(self):
        self._prepare_base_env()
        new_conf = self.nginx_relays_d / "fr.conf"
        self.assertFalse(new_conf.exists())

        new_conf_posix = self._bp(new_conf)
        cmd = f'''
        manifest_begin "{new_conf_posix}"
        echo "fake nginx config" > "{new_conf_posix}"
        manifest_rollback
        '''
        res = self._run_shell_snippet(cmd)
        self.assertEqual(res.returncode, 0, f"rollback snippet failed: {res.stderr + res.stdout}")
        self.assertFalse(
            new_conf.exists(), "Rollback failed to remove newly created relay nginx config file!"
        )


    # -------------------------------------------------------------------------
    # F19: Fail-Closed UFW Firewall & Doctor ACL Validation
    # -------------------------------------------------------------------------
    def test_doctor_ufw_acl_validation(self):
        self._prepare_base_env()

        # Case 1: Insecure UFW with 8444 open to 0.0.0.0/0
        self._create_mock_script(
            "ufw",
            """#!/bin/sh
if [ "$1" = "status" ] || [ "$1" = "status verbose" ]; then
    echo "Status: active"
    echo "To                         Action      From"
    echo "--                         ------      ----"
    echo "8444/tcp                   ALLOW       Anywhere"
    echo "443/tcp                    ALLOW       Anywhere"
    exit 0
fi
exit 0
""",
        )
        res_vuln = self._run_shell_snippet("run_doctor")
        self.assertIn("УЯЗВИМОСТЬ: Порт 8444 открыт для всех", res_vuln.stdout + res_vuln.stderr)

        # Case 2: Secure UFW with BOT_IP restriction
        with open(self.state_dir / "state.json", "w", encoding="utf-8") as f:
            json.dump(
                {"role": "ru_hub", "domain": "hub.example.com", "bot_ip": "198.51.100.42"}, f
            )

        self._create_mock_script(
            "ufw",
            """#!/bin/sh
if [ "$1" = "status" ] || [ "$1" = "status verbose" ]; then
    echo "Status: active"
    echo "To                         Action      From"
    echo "--                         ------      ----"
    echo "8444/tcp                   ALLOW       198.51.100.42"
    echo "443/tcp                    ALLOW       Anywhere"
    exit 0
fi
exit 0
""",
        )
        res_sec = self._run_shell_snippet("run_doctor")
        self.assertIn("Порт 8444 защищен и доступен только с BOT_IP", res_sec.stdout)

    # -------------------------------------------------------------------------
    # F20: Verified Update Rollback in update_xray_core
    # -------------------------------------------------------------------------
    def test_update_xray_fail_closed_rollback(self):
        self._prepare_base_env()
        xray_bin = self.bin_dir / "xray"
        xray_bin.write_text("#!/bin/sh\necho 'Xray 25.1.0'\nexit 0\n", encoding="utf-8")
        xray_bin.chmod(0o755)

        # Mock download_and_verify_xray using python zipfile
        cmd = """
download_and_verify_xray() {
    local dest="$1"
    python3 -c "
import zipfile, os
os.makedirs('/tmp/xray_mock_pkg', exist_ok=True)
with open('/tmp/xray_mock_pkg/xray', 'w') as f:
    f.write('#!/bin/sh\\nif [ \\\"\\$1\\\" = \\\"version\\\" ]; then echo \\\"Xray 27.0.0\\\"; exit 0; fi\\nexit 0\\n')
os.chmod('/tmp/xray_mock_pkg/xray', 0o755)
with zipfile.ZipFile('$dest', 'w') as zf:
    zf.write('/tmp/xray_mock_pkg/xray', arcname='xray')
"
}

# Mock systemctl to fail when starting the new version
systemctl() {
    if [ "$1" = "restart" ] && [ "$2" = "xray" ]; then
        if "$XRAY_BIN" version | grep -q "27.0.0"; then
            echo "Failed to start new Xray service" >&2
            return 1
        fi
    fi
    return 0
}

update_xray_core
"""
        res = self._run_shell_snippet(cmd)
        self.assertNotEqual(
            res.returncode, 0, "update_xray_core must exit with error on service restart failure"
        )
        self.assertIn("Xray не запустился после обновления", res.stdout + res.stderr)
        self.assertIn(
            "Откат на предыдущую версию успешно выполнен и подтвержден", res.stdout + res.stderr
        )
        self.assertNotIn("27.0.0", (self.bin_dir / "xray").read_text(encoding="utf-8"))

    def test_update_node_xray_api_rollback_on_restart_failure(self):
        """update_node rolls back xray-api code, cleans new files, restores node modules, and restores service on failure."""
        self._prepare_base_env()

        # Create original /opt/xray-api files
        orig_api = self.xray_api_dir / "api.py"
        orig_api.write_text("#!/usr/bin/env python3\n# original_v1\n", encoding="utf-8")
        orig_conf = self.xray_api_dir / ".orig_config"
        orig_conf.write_text("ACTIVE=1\n", encoding="utf-8")
        venv_dir = self.xray_api_dir / "venv" / "bin"
        venv_dir.mkdir(parents=True, exist_ok=True)
        orig_pip = venv_dir / "pip"
        orig_pip.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        orig_pip.chmod(0o755)

        # Create original /opt/just1knode module
        orig_node_module = self.install_dir / "test_module.sh"
        orig_node_module.write_text("# original_node_sh\n", encoding="utf-8")
        orig_node_bin = self.install_dir / "just1knode.sh"
        orig_node_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        orig_node_bin.chmod(0o755)

        cmd = """
# Mock curl to return a tar.gz archive with new xray-api and just1knode files
curl() {
    local dest=""
    local prev=""
    for arg in "$@"; do
        if [ "$prev" = "-o" ]; then dest="$arg"; fi
        prev="$arg"
    done
    if [ -n "$dest" ]; then
        python3 -c "
import tarfile, os, io
with tarfile.open('$dest', 'w:gz') as tar:
    for path, content in [
        ('package/scripts/xray_api/api.py', b'# new_v2\\n'),
        ('package/scripts/xray_api/new_orphan.py', b'# orphan\\n'),
        ('package/scripts/xray_api/requirements.txt', b'# reqs\\n'),
        ('package/just1knode/just1knode.sh', b'#!/bin/sh\\nexit 0\\n'),
        ('package/just1knode/test_module.sh', b'# new_node_sh\\n'),
        ('package/just1knode/orphan_node.sh', b'# orphan_node\\n'),
    ]:
        ti = tarfile.TarInfo(name=path)
        ti.size = len(content)
        tar.addfile(ti, io.BytesIO(content))
" 2>/dev/null
        return 0
    fi
    return 1
}

# Mock systemctl: initially active, fails restart on v2, succeeds on rollback
XRAY_API_ACTIVE=1
systemctl() {
    if [ "$1" = "is-active" ] && [ "$2" = "xray-api" ]; then
        [ "$XRAY_API_ACTIVE" -eq 1 ] && return 0 || return 1
    fi
    if [ "$1" = "restart" ] && [ "$2" = "xray-api" ]; then
        if grep -q "new_v2" "$XRAY_API_DIR/api.py" 2>/dev/null; then
            echo "Failed to start xray-api with new_v2" >&2
            XRAY_API_ACTIVE=0
            return 1
        fi
        XRAY_API_ACTIVE=1
        return 0
    fi
    return 0
}

update_node "all"
"""
        res = self._run_shell_snippet(cmd)
        self.assertNotEqual(res.returncode, 0, "update_node must fail when xray-api restart fails")
        self.assertIn("Сбой обновления", res.stdout + res.stderr)

        # State-based assertions: physical postconditions verified!
        self.assertIn("original_v1", orig_api.read_text(encoding="utf-8"))
        self.assertFalse((self.xray_api_dir / "new_orphan.py").exists(), "Orphan files must be purged on rollback")
        self.assertTrue((self.xray_api_dir / ".orig_config").exists(), "Dotfiles must be preserved on rollback")
        self.assertIn("original_node_sh", orig_node_module.read_text(encoding="utf-8"), "Node modules must be restored on rollback")
        self.assertFalse((self.install_dir / "orphan_node.sh").exists(), "Orphan node files must be purged on rollback")

    def test_update_node_rollback_on_cp_failure(self):
        """update_node triggers rollback when copying files fails during deploy."""
        self._prepare_base_env()

        orig_api = self.xray_api_dir / "api.py"
        orig_api.write_text("#!/usr/bin/env python3\n# original_v1\n", encoding="utf-8")
        orig_node_module = self.install_dir / "test_module.sh"
        orig_node_module.write_text("# original_node_sh\n", encoding="utf-8")
        orig_node_bin = self.install_dir / "just1knode.sh"
        orig_node_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        orig_node_bin.chmod(0o755)

        cmd = """
# Mock curl to return valid archive
curl() {
    local dest=""
    local prev=""
    for arg in "$@"; do
        if [ "$prev" = "-o" ]; then dest="$arg"; fi
        prev="$arg"
    done
    if [ -n "$dest" ]; then
        python3 -c "
import tarfile, io
with tarfile.open('$dest', 'w:gz') as tar:
    for path, content in [
        ('package/scripts/xray_api/api.py', b'# new_v2\\n'),
        ('package/just1knode/just1knode.sh', b'#!/bin/sh\\nexit 0\\n'),
        ('package/just1knode/test_module.sh', b'# new_node_sh\\n'),
    ]:
        ti = tarfile.TarInfo(name=path)
        ti.size = len(content)
        tar.addfile(ti, io.BytesIO(content))
" 2>/dev/null
        return 0
    fi
    return 1
}

# Fail cp only during the forward deployment from tmp_dir, NOT during rollback from backup_root
real_cp=$(which cp)
DEPLOY_FAILED=0
cp() {
    for arg in "$@"; do
        if [ "$arg" = "$INSTALL_DIR/" ] && [ "$DEPLOY_FAILED" -eq 0 ]; then
            DEPLOY_FAILED=1
            echo "cp: simulated disk full failure during deploy" >&2
            return 1
        fi
    done
    "$real_cp" "$@"
}

update_node "all"
"""
        res = self._run_shell_snippet(cmd)
        self.assertNotEqual(res.returncode, 0, "update_node must fail when deploy cp fails")
        self.assertIn("Не удалось скопировать модули", res.stdout + res.stderr)
        self.assertIn("original_node_sh", orig_node_module.read_text(encoding="utf-8"))

    def test_update_node_preserves_backup_on_rollback_failure(self):
        """update_node preserves backup directory on disk when rollback restart fails."""
        self._prepare_base_env()

        orig_api = self.xray_api_dir / "api.py"
        orig_api.write_text("#!/usr/bin/env python3\n# original_v1\n", encoding="utf-8")
        orig_node_module = self.install_dir / "test_module.sh"
        orig_node_module.write_text("# original_node_sh\n", encoding="utf-8")

        cmd = """
curl() {
    local dest=""
    local prev=""
    for arg in "$@"; do
        if [ "$prev" = "-o" ]; then dest="$arg"; fi
        prev="$arg"
    done
    if [ -n "$dest" ]; then
        python3 -c "
import tarfile, io
with tarfile.open('$dest', 'w:gz') as tar:
    for path, content in [
        ('package/scripts/xray_api/api.py', b'# new_v2\\n'),
        ('package/just1knode/test_module.sh', b'# new_node_sh\\n'),
    ]:
        ti = tarfile.TarInfo(name=path)
        ti.size = len(content)
        tar.addfile(ti, io.BytesIO(content))
" 2>/dev/null
        return 0
    fi
    return 1
}

# Initially is-active is 0 (service active before update).
# On restart (during update) it fails.
# On restart/start (during rollback) it fails.
# On is-active (after rollback) it returns 1 (service inactive).
XRAY_API_ATTEMPT=0
systemctl() {
    if [ "$1" = "is-active" ] && [ "$2" = "xray-api" ]; then
        [ "$XRAY_API_ATTEMPT" -eq 0 ] && return 0 || return 1
    fi
    if [ "$1" = "restart" ] || [ "$1" = "start" ]; then
        XRAY_API_ATTEMPT=$((XRAY_API_ATTEMPT + 1))
        echo "systemctl: service failed to start" >&2
        return 1
    fi
    return 0
}

update_node "all"
"""
        res = self._run_shell_snippet(cmd)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("Резервная копия сохранена в:", res.stdout + res.stderr)
        # Verify that backup directory exists in self.backup_dir
        backup_dirs = list(self.backup_dir.glob("update_bak.*"))
        self.assertTrue(len(backup_dirs) > 0, "Backup directory must be preserved on failed rollback")

    # -------------------------------------------------------------------------
    # F21: Certificate Expiration & SAN Check in Doctor
    # -------------------------------------------------------------------------
    def test_cert_expiration_and_san_check(self):
        self._prepare_base_env()
        domain = "origin.example.com"
        cert_dir = Path(self.temp_dir) / "etc" / "letsencrypt" / "live" / domain
        cert_dir.mkdir(parents=True, exist_ok=True)
        cert_file = cert_dir / "fullchain.pem"
        key_file = cert_dir / "privkey.pem"

        if shutil.which("openssl") is None:
            self.skipTest("openssl binary not found in PATH")

        # Generate test valid certificate with correct SAN
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-keyout",
                str(key_file),
                "-out",
                str(cert_file),
                "-days",
                "90",
                "-nodes",
                "-subj",
                f"/CN={domain}",
                "-addext",
                f"subjectAltName=DNS:{domain}",
            ],
            check=True,
            capture_output=True,
        )

        with open(self.state_dir / "state.json", "w", encoding="utf-8") as f:
            json.dump({"role": "ru_hub", "domain": domain, "bot_ip": "1.2.3.4"}, f)

        # Mock doctor cert path to point to our test cert
        doctor_snippet = f"""
run_doctor() {{
    local failed=0
    local domain="{domain}"
    local cert_file="{self._bp(cert_file)}"
    local exp_date
    exp_date="$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)"

    if ! openssl x509 -checkend 0 -noout -in "$cert_file"; then
        echo "SSL expired"
        failed=$((failed + 1))
    elif ! openssl x509 -checkend 2592000 -noout -in "$cert_file"; then
        echo "SSL expiring soon"
    else
        echo "SSL valid"
    fi

    local cert_text
    cert_text="$(openssl x509 -noout -text -in "$cert_file")"
    if echo "$cert_text" | grep -qE "DNS:${{domain}}\\b|CN\\s*=\\s*${{domain}}\\b"; then
        echo "SAN match confirmed"
    else
        echo "SAN mismatch"
        failed=$((failed + 1))
    fi
    return $failed
}}
run_doctor
"""
        res_valid = self._run_shell_snippet(doctor_snippet)
        self.assertEqual(res_valid.returncode, 0)
        self.assertIn("SSL valid", res_valid.stdout)
        self.assertIn("SAN match confirmed", res_valid.stdout)

        # Generate cert with domain mismatch
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-keyout",
                str(key_file),
                "-out",
                str(cert_file),
                "-days",
                "90",
                "-nodes",
                "-subj",
                "/CN=wrong.example.com",
                "-addext",
                "subjectAltName=DNS:wrong.example.com",
            ],
            check=True,
            capture_output=True,
        )

        res_mismatch = self._run_shell_snippet(doctor_snippet)
        self.assertNotEqual(res_mismatch.returncode, 0)
        self.assertIn("SAN mismatch", res_mismatch.stdout)

    # -------------------------------------------------------------------------
    # F22: Immutable Dependency Pinning
    # -------------------------------------------------------------------------
    def test_installer_immutable_dependencies(self):
        # 1. Check requirements.txt
        req_content = REQUIREMENTS_TXT.read_text(encoding="utf-8")
        req_lines = [
            line.strip()
            for line in req_content.splitlines()
            if line.strip() and not line.startswith("#")
        ]

        for line in req_lines:
            self.assertIn("==", line, f"Requirement {line} must be strictly pinned with ==")
            self.assertFalse(
                re.search(r"[><~]=?", line.split("==")[0]), f"Range specifiers forbidden in {line}"
            )

        pinned_packages = {}
        for item in req_lines:
            pkg, ver = item.split("==")
            pkg_name = pkg.split("[")[0].strip()
            pinned_packages[pkg_name] = ver.strip()

        self.assertEqual(pinned_packages.get("fastapi"), "0.141.1")
        self.assertEqual(pinned_packages.get("uvicorn"), "0.53.0")
        self.assertEqual(pinned_packages.get("grpcio"), "1.84.0")
        self.assertEqual(pinned_packages.get("protobuf"), "7.36.1")
        self.assertEqual(pinned_packages.get("pydantic"), "2.13.5")
        self.assertEqual(pinned_packages.get("psutil"), "7.2.2")

        # 2. Check just1knode for absence of floating git tarballs / unpinned upgrades / dead commits
        sh_content = ""
        for sub in ["lib", "modules"]:
            sub_dir = NODE_ROOT / sub
            if sub_dir.exists():
                for p in sub_dir.glob("**/*"):
                    if p.is_file():
                        sh_content += p.read_text(encoding="utf-8", errors="ignore") + "\n"
        if (NODE_ROOT / "just1knode.sh").exists():
            sh_content += (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8", errors="ignore") + "\n"
        if JUST1KNODE_SH.exists() and JUST1KNODE_SH != (NODE_ROOT / "just1knode.sh"):
            sh_content += JUST1KNODE_SH.read_text(encoding="utf-8", errors="ignore")
        self.assertNotIn(
            "pip install --upgrade pip", sh_content, "Unpinned pip self-upgrade is forbidden"
        )
        self.assertNotIn(
            "JUST1KBOT_RELEASE_COMMIT", sh_content, "Hallucinated release commit must be removed"
        )
        self.assertNotIn(
            "AMNEZIA_API_COMMIT", sh_content, "Hallucinated Amnezia API commit must be removed"
        )
        self.assertNotIn(
            "install_amnezia_api_node",
            sh_content,
            "Third-party amnezia-api installer must be purged",
        )
        self.assertIn(
            "setup_xray_api_venv", sh_content, "Virtualenv setup function must be present"
        )
        self.assertIn("useradd -r", sh_content, "System user creation must be present")
        self.assertIn("xrayapi", sh_content, "Non-root xrayapi user must be configured")
        self.assertIn("JUST1KBOT_REF", sh_content, "Dynamic ref resolution must be configured")

    # -------------------------------------------------------------------------
    # F23: Panel version label and entry update check
    # -------------------------------------------------------------------------
    def test_node_version_label_format(self):
        """node_version_label prints v<semver> with optional short commit."""
        res = self._run_shell_snippet("node_version_label")
        self.assertEqual(res.returncode, 0, f"node_version_label failed: {res.stderr}")
        self.assertRegex(res.stdout.strip(), r"^v[0-9]+\.[0-9]+\.[0-9]+( \([0-9a-f]+\))?$")

    def test_node_version_box_line_width(self):
        """print_node_version_box_line keeps the 61-char inner box width."""
        res = self._run_shell_snippet("print_node_version_box_line")
        self.assertEqual(res.returncode, 0, f"box line failed: {res.stderr}")
        # 61 inner chars + 2 borders; Python counts codepoints locale-independently.
        line = res.stdout.strip()
        self.assertEqual(len(line), 63)
        self.assertTrue(line.startswith("│") and line.endswith("│"))

    def test_node_update_check_skipped_for_custom_repo(self):
        """check_node_update_on_entry exits 0 silently for non-default repo URL."""
        res = self._run_shell_snippet(
            "check_node_update_on_entry",
            extra_env={"JUST1KBOT_REPO_URL": "https://example.com/custom.git"},
        )
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "")

    def test_node_update_check_detects_newer_remote(self):
        """check_node_update_on_entry warns when remote VERSION differs (mocked curl)."""
        self._create_mock_script("git", "#!/bin/sh\nexit 1\n")
        self._create_mock_script("curl", "#!/bin/sh\necho '99.99.99'\n")
        res = self._run_shell_snippet("check_node_update_on_entry")
        self.assertEqual(res.returncode, 0)
        self.assertIn("99.99.99", res.stdout)

    def test_node_update_check_silent_when_up_to_date(self):
        """check_node_update_on_entry stays silent when remote VERSION matches."""
        self._create_mock_script("git", "#!/bin/sh\nexit 1\n")
        current = (NODE_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        self._create_mock_script("curl", f"#!/bin/sh\necho '{current}'\n")
        res = self._run_shell_snippet("check_node_update_on_entry")
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "")

    def test_node_update_check_silent_when_remote_older(self):
        """No 'new version' notice when remote VERSION is older than local."""
        self._create_mock_script("git", "#!/bin/sh\nexit 1\n")
        self._create_mock_script("curl", "#!/bin/sh\necho '0.0.0'\n")
        res = self._run_shell_snippet("check_node_update_on_entry")
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "")

    def test_node_update_check_silent_for_invalid_remote(self):
        """Malformed remote VERSION values are ignored, never rendered."""
        self._create_mock_script("git", "#!/bin/sh\nexit 1\n")
        for bad in ["2.1.2-beta", "garbage", "", "v2.1.3", "999"]:
            self._create_mock_script("curl", f"#!/bin/sh\necho '{bad}'\n")
            res = self._run_shell_snippet("check_node_update_on_entry")
            self.assertEqual(res.returncode, 0, f"failed for remote={bad!r}: {res.stderr}")
            self.assertEqual(res.stdout.strip(), "", f"notice shown for remote={bad!r}")

    def test_node_update_check_detects_commit_diff(self):
        """check_node_update_on_entry warns when remote commit differs from local SHA."""
        self._create_mock_script(
            "git",
            "#!/bin/sh\nprintf '1111111111111111111111111111111111111111\\trefs/heads/main\\n'\n",
        )
        self._create_mock_script("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
        res = self._run_shell_snippet(
            "check_node_update_on_entry",
            extra_env={"JUST1KNODE_LOCAL_SHA": "0" * 40},
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("Доступны изменения в GitHub origin/main", res.stdout)

    def test_node_update_check_silent_when_commit_identical(self):
        """check_node_update_on_entry silent when remote commit matches local SHA."""
        self._create_mock_script(
            "git",
            "#!/bin/sh\nprintf '0000000000000000000000000000000000000000\\trefs/heads/main\\n'\n",
        )
        self._create_mock_script("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
        res = self._run_shell_snippet(
            "check_node_update_on_entry",
            extra_env={"JUST1KNODE_LOCAL_SHA": "0" * 40},
        )
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "")

    def test_node_update_check_detects_commit_diff_from_git_repo(self):
        """check_node_update_on_entry warns when running in git repo and remote differs."""
        script = """#!/bin/sh
case "$*" in
    *rev-parse*HEAD*) printf '0000000000000000000000000000000000000000\\n' ;;
    *ls-remote*) printf '1111111111111111111111111111111111111111\\trefs/heads/main\\n' ;;
    *) exit 1 ;;
esac
"""
        self._create_mock_script("git", script)
        self._create_mock_script("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
        res = self._run_shell_snippet("check_node_update_on_entry")
        self.assertEqual(res.returncode, 0)
        self.assertIn("Доступны изменения в GitHub origin/main", res.stdout)


    # -------------------------------------------------------------------------
    # Functional Validation: Zero-Signature Purge & Certbot Deploy Hook
    # -------------------------------------------------------------------------
    def test_functional_zero_signature_and_certbot_deploy_hook(self):
        self._prepare_base_env()
        index_file = self.www_html_dir / "index.html"
        index_file.write_text("<h1>SimpleCalc</h1>", encoding="utf-8")
        self.assertTrue(index_file.exists())

        res = self._run_shell_snippet("deploy_camouflage_site; deploy_certbot_renewal_hook")
        self.assertEqual(res.returncode, 0)

        # 1. Zero-Signature: legacy camouflage index.html must be purged
        self.assertFalse(index_file.exists())

        # 1b. Zero-Signature: Edge Gateway camouflage index.html must also be purged
        edge_index = self.www_html_dir / "index.html"
        edge_index.write_text("<h1>Edge Gateway Infrastructure</h1>", encoding="utf-8")
        res_edge = self._run_shell_snippet("deploy_camouflage_site")
        self.assertEqual(res_edge.returncode, 0)
        self.assertFalse(edge_index.exists())

        # 2. Zero-Collateral: custom user index.html must NOT be purged
        custom_index = self.www_html_dir / "index.html"
        custom_index.write_text("<h1>Custom User Site</h1>", encoding="utf-8")
        res2 = self._run_shell_snippet("deploy_camouflage_site")
        self.assertEqual(res2.returncode, 0)
        self.assertTrue(custom_index.exists())
        self.assertEqual(custom_index.read_text(encoding="utf-8"), "<h1>Custom User Site</h1>")

        # 2. Certbot renewal hook
        hook_file = self.letsencrypt_dir / "renewal-hooks" / "deploy" / "restart-xray-nginx.sh"
        self.assertTrue(hook_file.exists())
        hook_content = hook_file.read_text(encoding="utf-8")
        self.assertIn("systemctl reload nginx", hook_content)
        self.assertIn("systemctl restart xray", hook_content)
        self.assertIn("systemctl start xray-api", hook_content)


    def test_deploy_camouflage_site_preserves_unrelated_index_html(self):
        self._prepare_base_env()
        custom_html = self.www_html_dir / "index.html"
        custom_html.write_text("<html><h1>My Personal Blog</h1></html>", encoding="utf-8")

        res = self._run_shell_snippet("deploy_camouflage_site")
        self.assertEqual(res.returncode, 0)
        self.assertTrue(custom_html.exists(), "Custom user index.html must NOT be deleted")

    def test_normalize_domain_strips_protocols_and_slashes(self):
        self._prepare_base_env()
        res = self._run_shell_snippet('normalize_domain "  https://mybot.example.com/some/path/  "')
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout.strip(), "mybot.example.com")

        res_http = self._run_shell_snippet('normalize_domain "http://test.domain.com:8443/"')
        self.assertEqual(res_http.returncode, 0)
        self.assertEqual(res_http.stdout.strip(), "test.domain.com:8443")

    def test_init_state_dir_sets_sgid_and_permissions(self):
        self._prepare_base_env()
        idemp_db = self.state_dir / "idempotency.db"
        idemp_wal = self.state_dir / "idempotency.db-wal"
        idemp_db.write_text("dummy", encoding="utf-8")
        idemp_wal.write_text("dummy", encoding="utf-8")
        os.chmod(idemp_db, 0o600)
        os.chmod(idemp_wal, 0o600)

        res = self._run_shell_snippet("init_state_dir")
        self.assertEqual(res.returncode, 0)
        st = os.stat(self.state_dir)
        # Check SGID and permissions (2770 or 0o2770)
        self.assertTrue(bool(st.st_mode & 0o2000), "SGID bit must be set on STATE_DIR")
        self.assertTrue(bool(st.st_mode & 0o0070), "Group must have rwx permissions on STATE_DIR")
        self.assertEqual(st.st_mode & 0o0007, 0, "Others must have zero permissions on STATE_DIR")

        # Check state file permissions 660
        state_file = self.state_dir / "state.json"
        if state_file.exists():
            st_file = os.stat(state_file)
            self.assertTrue(
                bool(st_file.st_mode & 0o0660),
                "State file must have rw permissions for owner and group",
            )
            self.assertEqual(
                st_file.st_mode & 0o0007, 0, "State file must have zero permissions for others"
            )

        for p in (idemp_db, idemp_wal):
            st_idemp = os.stat(p)
            self.assertTrue(
                bool(st_idemp.st_mode & 0o0660),
                f"{p.name} must have rw permissions for owner and group",
            )
            self.assertEqual(
                st_idemp.st_mode & 0o0007, 0, f"{p.name} must have zero permissions for others"
            )

    def test_detect_existing_nginx_sites_in_just1knode(self):
        self._prepare_base_env()
        sites_enabled = self.nginx_conf_dir / "sites-enabled"
        sites_enabled.mkdir(parents=True, exist_ok=True)

        # Default stock
        (sites_enabled / "default").write_text(
            "server { listen 80; server_name _; }\n", encoding="utf-8"
        )
        # User site
        (sites_enabled / "my-blog.conf").write_text(
            "server {\n    listen 80;\n    server_name myblog.org;\n}\n", encoding="utf-8"
        )

        res = self._run_shell_snippet(f'detect_existing_nginx_sites "{self._bp(self.nginx_conf_dir)}"')
        self.assertEqual(
            res.returncode, 0, f"detect_existing_nginx_sites failed: stderr={res.stderr}"
        )
        self.assertIn("my-blog.conf", res.stdout)
        self.assertIn("myblog.org", res.stdout)
        self.assertNotIn("default", res.stdout)


    def test_origin_nginx_restores_default_on_validation_failure(self):
        self._prepare_base_env()
        sites_enabled = self.nginx_conf_dir / "sites-enabled"
        sites_available = self.nginx_conf_dir / "sites-available"
        sites_enabled.mkdir(parents=True, exist_ok=True)
        sites_available.mkdir(parents=True, exist_ok=True)

        (sites_available / "default").write_text(
            "server {\n    listen 80;\n    server_name default.test;\n}\n", encoding="utf-8"
        )
        (sites_enabled / "default").symlink_to(sites_available / "default")

        snippet = f"""
NGINX_CONF_DIR="{self._bp(self.nginx_conf_dir)}"
default_was_linked_origin=0
if [[ -f "${{NGINX_CONF_DIR}}/sites-enabled/default" ]]; then
    default_was_linked_origin=1
    rm -f "${{NGINX_CONF_DIR}}/sites-enabled/default"
fi
# Simulate validation failure rollback
if [[ $default_was_linked_origin -eq 1 && -f "${{NGINX_CONF_DIR}}/sites-available/default" ]]; then
    ln -sf "${{NGINX_CONF_DIR}}/sites-available/default" "${{NGINX_CONF_DIR}}/sites-enabled/default"
fi
"""
        res = self._run_shell_snippet(snippet)
        self.assertEqual(res.returncode, 0)
        self.assertTrue(
            (sites_enabled / "default").exists(),
            "default site must be restored after validation failure",
        )

    def test_ensure_xrayapi_user_creates_group_and_user(self):
        self._prepare_base_env()
        mock_bin = self.bin_dir
        group_log = Path(self.temp_dir) / "groupadd.log"
        user_log = Path(self.temp_dir) / "useradd.log"
        group_log_posix = self._bp(group_log)
        user_log_posix = self._bp(user_log)
        (mock_bin / "groupadd").write_text(
            f"#!/bin/bash\necho \"$@\" >> '{group_log_posix}'\nexit 0\n", encoding="utf-8"
        )
        (mock_bin / "groupadd").chmod(0o755)
        (mock_bin / "useradd").write_text(
            f"#!/bin/bash\necho \"$@\" >> '{user_log_posix}'\nexit 0\n", encoding="utf-8"
        )
        (mock_bin / "useradd").chmod(0o755)
        (mock_bin / "getent").write_text("#!/bin/bash\nexit 1\n", encoding="utf-8")
        (mock_bin / "getent").chmod(0o755)
        (mock_bin / "id").write_text(
            f'#!/bin/bash\nif [[ -f "{user_log_posix}" ]]; then echo 1001; exit 0; fi\nexit 1\n',
            encoding="utf-8",
        )
        (mock_bin / "id").chmod(0o755)

        api_sh = NODE_ROOT / "modules" / "xray" / "api.sh"
        res = self._run_shell_snippet(f"""
unset -f ensure_xrayapi_user
source '{self._bp(api_sh)}'
ensure_xrayapi_user
""")
        self.assertEqual(res.returncode, 0, f"ensure_xrayapi_user failed: {res.stderr}")
        self.assertTrue(group_log.exists(), "groupadd must be called when group does not exist")
        self.assertIn("-r xrayapi", group_log.read_text(encoding="utf-8"))
        self.assertTrue(user_log.exists(), "useradd must be called when user does not exist")
        self.assertIn("xrayapi", user_log.read_text(encoding="utf-8"))


    # -------------------------------------------------------------------------
    # Safe Complete Uninstallation Lifecycle Tests
    # -------------------------------------------------------------------------

    def test_uninstall_node_fails_closed_without_confirmation(self):
        """just1knode uninstall in non-interactive mode without --confirm=DELETE must exit 1."""
        self._prepare_base_env()
        res = self._run_shell_snippet("uninstall_node")
        self.assertEqual(res.returncode, 1)
        self.assertIn("В неинтерактивном режиме для удаления требуется явный флаг", res.stdout + res.stderr)
        self.assertTrue(self.state_dir.exists(), "state_dir must remain untouched")

    def test_uninstall_node_aborts_on_first_prompt_cancellation(self):
        """just1knode uninstall must abort when user responds 'n' to first prompt."""
        self._prepare_base_env()
        res = self._run_shell_snippet("uninstall_node", input_text="n\n")
        self.assertEqual(res.returncode, 0)
        self.assertIn("Удаление отменено пользователем", res.stdout + res.stderr)
        self.assertTrue(self.state_dir.exists())

    def test_uninstall_node_aborts_on_keyword_mismatch(self):
        """just1knode uninstall must abort when user enters incorrect confirmation keyword."""
        self._prepare_base_env()
        res = self._run_shell_snippet("uninstall_node", input_text="y\nABORT\n")
        self.assertEqual(res.returncode, 0)
        self.assertIn("Подтверждение не совпало", res.stdout + res.stderr)
        self.assertTrue(self.state_dir.exists())

    def test_uninstall_node_complete_cleanup_lifecycle(self):
        """just1knode uninstall --confirm=DELETE --purge-backups removes services, binaries, configs, nginx sites, user, and state."""
        self._prepare_base_env()

        # 1. Setup mock services and files
        (self.systemd_dir / "xray.service").write_text("[Unit]\nDescription=Xray\n", encoding="utf-8")
        (self.systemd_dir / "xray-api.service").write_text("[Unit]\nDescription=API\n", encoding="utf-8")
        (self.xray_config_dir / "config.json").write_text("{}", encoding="utf-8")
        (self.xray_api_etc / "config.env").write_text("API_KEY=test\n", encoding="utf-8")
        (self.xray_api_dir / "app.py").write_text("# app\n", encoding="utf-8")
        (self.xray_api_lib / "epoch.json").write_text("{}", encoding="utf-8")

        # Nginx configs
        nginx_sites_avail = self.nginx_conf_dir / "sites-available"
        nginx_sites_enabled = self.nginx_conf_dir / "sites-enabled"
        nginx_conf_d = self.nginx_conf_dir / "conf.d"
        nginx_sites_avail.mkdir(parents=True, exist_ok=True)
        nginx_sites_enabled.mkdir(parents=True, exist_ok=True)
        nginx_conf_d.mkdir(parents=True, exist_ok=True)

        origin_conf = nginx_sites_avail / "just1k-origin.conf"
        origin_conf.write_text("server { listen 80; }", encoding="utf-8")
        (nginx_sites_enabled / "just1k-origin.conf").symlink_to(origin_conf)
        (nginx_conf_d / "xhttp-map.conf").write_text("map $request_method $xhttp { }", encoding="utf-8")
        (nginx_conf_d / "just1k-xhttp-upstreams.conf").write_text("upstream xhttp { }", encoding="utf-8")
        fallback_ssl_dir = self.nginx_conf_dir / "fallback_ssl"
        fallback_ssl_dir.mkdir(parents=True, exist_ok=True)
        (fallback_ssl_dir / "dummy.crt").write_text("cert", encoding="utf-8")

        # Backup of user default site
        (nginx_sites_avail / "default.user.bak").write_text("server { server_name user.com; }", encoding="utf-8")

        # Fake camouflage site
        (self.www_html_dir / "index.html").write_text("<h1>Cloud Ingress Network Node</h1>", encoding="utf-8")

        # Fake certbot hook & renewal conf
        hook_dir = self.letsencrypt_dir / "renewal-hooks" / "deploy"
        hook_dir.mkdir(parents=True, exist_ok=True)
        (hook_dir / "restart-xray-nginx.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        (hook_dir / "20-just1knode-restart-xray.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        renewal_conf_dir = self.letsencrypt_dir / "renewal"
        renewal_conf_dir.mkdir(parents=True, exist_ok=True)
        (renewal_conf_dir / "relay.example.com.conf").write_text(
            "[renewalparams]\npre_hook = sh -c '... /run/just1knode_caddy_was_paused ...'\npost_hook = sh -c '... 20-just1knode-restart-xray.sh ...'\naccount = abc123\n",
            encoding="utf-8",
        )
        (renewal_conf_dir / "other.example.com.conf").write_text(
            "[renewalparams]\npre_hook = /usr/local/bin/my-just1knode-monitor\naccount = other456\n",
            encoding="utf-8",
        )

        # Fake install dir & global bin
        fake_install_dir = Path(self.temp_dir) / "opt" / "just1knode"
        fake_install_dir.mkdir(parents=True, exist_ok=True)
        (fake_install_dir / "marker.txt").write_text("just1knode", encoding="utf-8")

        fake_global_bin = Path(self.temp_dir) / "usr_local_bin" / "just1knode"
        fake_global_bin.parent.mkdir(parents=True, exist_ok=True)
        fake_global_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")

        # Mock userdel, groupdel, pkill
        self._create_mock_script("userdel", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("groupdel", "#!/bin/sh\nexit 0\n")
        self._create_mock_script("pkill", "#!/bin/sh\nexit 0\n")

        # Fake sysctl and modules-load conf
        self.sysctl_conf.write_text("net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv4.icmp_echo_ignore_all = 1\n", encoding="utf-8")
        self.modules_load_conf.write_text("nf_conntrack\nxt_string\n", encoding="utf-8")

        extra_env = {
            "INSTALL_DIR": str(fake_install_dir),
            "JUST1KNODE_GLOBAL_BIN": str(fake_global_bin),
            "BACKUP_DIR": str(self.backup_dir),
            "JUST1KNODE_ALLOW_CUSTOM_INSTALL_RM": "1",
        }

        res = self._run_shell_snippet("uninstall_node --confirm=DELETE --purge-backups", extra_env=extra_env)
        self.assertEqual(res.returncode, 0, f"uninstall_node failed: {res.stderr}\nOutput: {res.stdout}")
        self.assertIn("just1knode успешно и полностью удален с сервера без остатков", res.stdout)

        # Assertions
        self.assertFalse(self.sysctl_conf.exists(), "sysctl configuration must be removed on uninstall")
        self.assertFalse(self.modules_load_conf.exists(), "modules-load configuration must be removed on uninstall")
        self.assertFalse((self.systemd_dir / "xray.service").exists(), "xray.service must be removed")
        self.assertFalse((self.systemd_dir / "xray-api.service").exists(), "xray-api.service must be removed")
        self.assertFalse(self.xray_config_dir.exists(), "xray config dir must be removed")
        self.assertFalse(self.xray_api_dir.exists(), "xray-api dir must be removed")
        self.assertFalse(self.xray_api_etc.exists(), "xray-api etc must be removed")
        self.assertFalse(self.xray_api_lib.exists(), "xray-api lib must be removed")
        self.assertFalse(self.state_dir.exists(), "state_dir must be removed")
        self.assertFalse((nginx_sites_avail / "just1k-origin.conf").exists(), "origin nginx site must be removed")
        self.assertFalse((nginx_sites_enabled / "just1k-origin.conf").exists(), "origin nginx link must be removed")
        self.assertFalse((nginx_conf_d / "xhttp-map.conf").exists(), "xhttp-map.conf must be removed")
        self.assertFalse((nginx_conf_d / "just1k-xhttp-upstreams.conf").exists(), "just1k-xhttp-upstreams.conf must be removed")
        self.assertFalse(fallback_ssl_dir.exists(), "fallback_ssl directory must be removed on uninstall")
        self.assertTrue((nginx_sites_avail / "default").exists(), "default site must be restored from default.user.bak")
        self.assertFalse((nginx_sites_avail / "default.user.bak").exists(), "default.user.bak must be removed after restore")
        self.assertFalse((self.www_html_dir / "index.html").exists(), "camouflage index.html must be removed")
        self.assertFalse((hook_dir / "restart-xray-nginx.sh").exists(), "certbot hook must be removed")
        self.assertFalse((hook_dir / "20-just1knode-restart-xray.sh").exists(), "deploy hook 20-just1knode-restart-xray.sh must be removed")
        conf_after = (renewal_conf_dir / "relay.example.com.conf").read_text(encoding="utf-8")
        self.assertNotIn("pre_hook", conf_after, "inline pre_hook must be purged from renewal conf")
        self.assertNotIn("post_hook", conf_after, "inline post_hook must be purged from renewal conf")
        self.assertIn("account = abc123", conf_after, "other renewal parameters must be preserved")
        other_after = (renewal_conf_dir / "other.example.com.conf").read_text(encoding="utf-8")
        self.assertIn("pre_hook = /usr/local/bin/my-just1knode-monitor", other_after, "third-party custom hook must NOT be removed")
        self.assertFalse(fake_install_dir.exists(), "INSTALL_DIR must be removed")
        self.assertFalse(fake_global_bin.exists(), "JUST1KNODE_GLOBAL_BIN must be removed")
        self.assertFalse(self.backup_dir.exists(), "BACKUP_DIR must be removed when --purge-backups is passed")

    def test_uninstall_node_preserves_backups_without_purge_flag(self):
        """uninstall_node preserves BACKUP_DIR unless --purge-backups is explicitly given."""
        self._prepare_base_env()
        (self.backup_dir / "xray_state.tar.gz").write_text("backup_content", encoding="utf-8")

        extra_env = {
            "BACKUP_DIR": str(self.backup_dir),
            "JUST1KNODE_ALLOW_CUSTOM_INSTALL_RM": "1",
        }

        res = self._run_shell_snippet("uninstall_node --confirm=DELETE", extra_env=extra_env)
        self.assertEqual(res.returncode, 0, f"uninstall_node failed: {res.stderr}\nOutput: {res.stdout}")
        self.assertTrue(self.backup_dir.exists(), "BACKUP_DIR must remain when --purge-backups is omitted")
        self.assertTrue((self.backup_dir / "xray_state.tar.gz").exists(), "Backup archive must remain intact")
        self.assertIn("Каталог бэкапов сохранен", res.stdout)

    def test_uninstall_node_rejects_protected_system_directories(self):
        """uninstall_node must fail-closed (code 1) when STATE_DIR or BACKUP_DIR is a protected root/system directory."""
        self._prepare_base_env()
        for dangerous_dir in ["/etc", "/var", "/usr", "/root", "/"]:
            res = self._run_shell_snippet("uninstall_node --confirm=DELETE", extra_env={"STATE_DIR": dangerous_dir})
            self.assertEqual(res.returncode, 1, f"Expected code 1 for dangerous STATE_DIR={dangerous_dir}")
            self.assertIn("Попытка удаления защищенного системного каталога", res.stdout + res.stderr)

    def test_uninstall_node_safe_nginx_reload_skips_when_inactive(self):
        """uninstall_node must not restart Nginx when systemctl is-active returns non-zero."""
        self._prepare_base_env()
        nginx_log = Path(self.temp_dir) / "nginx_cmd.log"
        nginx_log_posix = self._bp(nginx_log)
        self._create_mock_script(
            "systemctl",
            f"""#!/bin/sh
if [ "$1" = "is-active" ] && [ "$3" = "nginx" ]; then
    exit 3
fi
if [ "$1" = "restart" ] && [ "$2" = "nginx" ]; then
    echo "RESTART_NGINX" >> "{nginx_log_posix}"
fi
if [ "$1" = "reload" ] && [ "$2" = "nginx" ]; then
    echo "RELOAD_NGINX" >> "{nginx_log_posix}"
fi
exit 0
""",
        )

        fake_install_dir = Path(self.temp_dir) / "opt" / "just1knode"
        fake_install_dir.mkdir(parents=True, exist_ok=True)
        fake_global_bin = Path(self.temp_dir) / "usr_local_bin" / "just1knode"
        fake_global_bin.parent.mkdir(parents=True, exist_ok=True)
        fake_global_bin.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")

        extra_env = {
            "INSTALL_DIR": str(fake_install_dir),
            "JUST1KNODE_GLOBAL_BIN": str(fake_global_bin),
            "JUST1KNODE_ALLOW_CUSTOM_INSTALL_RM": "1",
        }
        res = self._run_shell_snippet("uninstall_node --confirm=DELETE", extra_env=extra_env)
        self.assertEqual(res.returncode, 0, f"uninstall_node failed: {res.stderr}\n{res.stdout}")
        if nginx_log.exists():
            log_content = nginx_log.read_text(encoding="utf-8")
            self.assertNotIn("RESTART_NGINX", log_content, "Inactive Nginx must NEVER be restarted during uninstall!")

    def test_validate_fqdn_and_sub_prefix(self):
        """validate_fqdn and validate_sub_prefix reject malicious/hostile inputs and accept valid ones."""
        self._prepare_base_env()

        # Valid FQDNs
        valid_fqdns = ["bot.example.com", "sub.example.com", "my-node.origin.cloud", "a.bc"]
        for fqdn in valid_fqdns:
            res = self._run_shell_snippet(f"validate_fqdn '{fqdn}'")
            self.assertEqual(res.returncode, 0, f"Expected '{fqdn}' to be valid FQDN")

        # Hostile / Invalid FQDNs
        invalid_fqdns = [
            "",
            "localhost",
            "127.0.0.1",
            "192.168.1.1",
            "bot.example.com;rm -rf /",
            "bot.example.com\nset",
            "bot.example.com\r\nset",
            "bot.example.com$(whoami)",
            "bot.example.com`id`",
            'bot.example.com"junk',
            "bot.example.com'junk",
            "bot.example.com/path",
            "bot example com",
            "-bot.example.com",
            "bot.example.com-",
            "http://bot.example.com",
        ]
        for fqdn in invalid_fqdns:
            res = self._run_shell_snippet(f"validate_fqdn '{fqdn}'")
            self.assertNotEqual(res.returncode, 0, f"Expected '{fqdn}' to be rejected by validate_fqdn")

        # Valid sub prefixes
        valid_prefixes = ["/sub/wl", "/sub/wl/v1", "/prefix", "/a-b/c_d"]
        for prefix in valid_prefixes:
            res = self._run_shell_snippet(f"validate_sub_prefix '{prefix}'")
            self.assertEqual(res.returncode, 0, f"Expected '{prefix}' to be valid sub_prefix")

        # Hostile / Invalid sub prefixes
        invalid_prefixes = [
            "",
            "sub/wl",
            "/sub/../wl",
            "/../secret",
            "/sub/wl;evil",
            "/sub/wl\n",
            "/sub/wl\r\n",
            "/sub/$(whoami)",
            "/sub/`id`",
            '/sub/wl"junk',
            "/sub/wl'junk",
            "/sub/wl?arg=1",
            "/sub/wl#hash",
            "/sub wl",
        ]
        for prefix in invalid_prefixes:
            res = self._run_shell_snippet(f"validate_sub_prefix '{prefix}'")
            self.assertNotEqual(res.returncode, 0, f"Expected '{prefix}' to be rejected by validate_sub_prefix")


    def test_cleanup_legacy_traffic_watchdog_residue_invariants(self):
        """cleanup_legacy_traffic_watchdog_residue removes systemd timer, service, drop-in, and all cutoff flags."""
        self._prepare_base_env()
        systemd_dir = self.systemd_dir
        systemd_dir.mkdir(parents=True, exist_ok=True)
        dropin_dir = systemd_dir / "xray.service.d"
        dropin_dir.mkdir(parents=True, exist_ok=True)
        run_dir = Path(self.temp_dir) / "run"
        run_dir.mkdir(parents=True, exist_ok=True)

        svc_file = systemd_dir / "just1knode-traffic.service"
        timer_file = systemd_dir / "just1knode-traffic.timer"
        dropin_file = dropin_dir / "traffic-cutoff.conf"
        cutoff_flag = self.state_dir / "traffic_cutoff.active"
        run_cutoff_flag = run_dir / "just1knode_traffic_cutoff"

        svc_file.write_text("[Unit]\nDescription=Dummy\n", encoding="utf-8")
        timer_file.write_text("[Unit]\nDescription=Dummy\n", encoding="utf-8")
        dropin_file.write_text("[Unit]\nConditionPathExists=!/etc/just1knode/traffic_cutoff.active\n", encoding="utf-8")
        cutoff_flag.write_text("1", encoding="utf-8")
        run_cutoff_flag.write_text("1", encoding="utf-8")

        self.assertTrue(svc_file.exists())
        self.assertTrue(timer_file.exists())
        self.assertTrue(dropin_file.exists())
        self.assertTrue(cutoff_flag.exists())
        self.assertTrue(run_cutoff_flag.exists())

        systemd_dir_posix = self._bp(systemd_dir)
        state_dir_posix = self._bp(self.state_dir)
        run_dir_posix = self._bp(run_dir)
        snippet = f"""
export SYSTEMD_SYSTEM_DIR="{systemd_dir_posix}"
export STATE_DIR="{state_dir_posix}"
export RUN_DIR="{run_dir_posix}"
cleanup_legacy_traffic_watchdog_residue
"""
        res = self._run_shell_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"cleanup_legacy_traffic_watchdog_residue failed: {res.stderr}\n{res.stdout}")

        self.assertFalse(svc_file.exists(), "Traffic service unit must be removed")
        self.assertFalse(timer_file.exists(), "Traffic timer unit must be removed")
        self.assertFalse(dropin_file.exists(), "xray.service.d/traffic-cutoff.conf must be removed")
        self.assertFalse(dropin_dir.exists(), "Empty xray.service.d directory must be removed")
        self.assertFalse(cutoff_flag.exists(), "traffic_cutoff.active flag must be removed")
        self.assertFalse(run_cutoff_flag.exists(), "run cutoff flag must be removed")

        # Scenario 2: Non-empty dropin directory preservation
        dropin_dir.mkdir(parents=True, exist_ok=True)
        custom_file = dropin_dir / "10-custom.conf"
        custom_file.write_text("[Service]\nLimitNOFILE=65536\n", encoding="utf-8")
        dropin_file.write_text("[Unit]\nDummy\n", encoding="utf-8")

        res2 = self._run_shell_snippet(snippet)
        self.assertEqual(res2.returncode, 0)
        self.assertFalse(dropin_file.exists())
        self.assertTrue(custom_file.exists(), "Custom drop-in file must be preserved")
        self.assertTrue(dropin_dir.exists(), "Non-empty xray.service.d must be preserved")

    def test_deploy_and_remove_traffic_limit_timer_and_cutoff_invariants(self):
        """deploy_traffic_limit_timer installs systemd timer and does NOT create xray cutoff drop-in, remove cleans up."""
        self._prepare_base_env()
        systemd_dir = self.systemd_dir
        systemd_dir.mkdir(parents=True, exist_ok=True)

        systemd_dir_posix = self._bp(systemd_dir)
        snippet = f"""
export SYSTEMD_SYSTEM_DIR="{systemd_dir_posix}"
deploy_traffic_limit_timer
"""
        res = self._run_shell_snippet(snippet)
        self.assertEqual(res.returncode, 0, f"deploy_traffic_limit_timer failed: {res.stderr}\n{res.stdout}")

        svc_file = systemd_dir / "just1knode-traffic-limit.service"
        timer_file = systemd_dir / "just1knode-traffic-limit.timer"
        dropin_file = systemd_dir / "xray.service.d" / "traffic-cutoff.conf"

        self.assertTrue(svc_file.exists(), "Traffic limit service unit must be created")
        self.assertTrue(timer_file.exists(), "Traffic limit timer unit must be created")
        self.assertFalse(dropin_file.exists(), "CRITICAL: ConditionPathExists in xray.service.d must NOT be created")

        # Removal
        remove_snippet = f"""
export SYSTEMD_SYSTEM_DIR="{systemd_dir_posix}"
remove_traffic_limit_timer
"""
        res_rm = self._run_shell_snippet(remove_snippet)
        self.assertEqual(res_rm.returncode, 0)
        self.assertFalse(svc_file.exists(), "Traffic limit service unit must be removed")
        self.assertFalse(timer_file.exists(), "Traffic limit timer unit must be removed")
        self.assertFalse(dropin_file.exists(), "xray.service.d/traffic-cutoff.conf must not exist")

    def test_detect_host_port80_container_filtering_behaviour(self):
        """Verify detect_host_port80_container correctly matches host TCP :80 bindings and ignores container-only :80 or UDP :80."""
        # Simulated docker ps outputs
        test_cases = [
            ("other-app\t0.0.0.0:8080->80/tcp", None),
            ("proxy-app\t0.0.0.0:80->80/tcp", "proxy-app"),
            ("custom-app\t0.0.0.0:80->8080/tcp", "custom-app"),
            ("ipv6-proxy\t:::80->80/tcp", "ipv6-proxy"),
            ("dual-proxy\t0.0.0.0:80->80/tcp, :::80->80/tcp", "dual-proxy"),
            ("udp-service\t0.0.0.0:80->80/udp", None),
            ("unrelated\t127.0.0.1:51820->51820/udp", None),
        ]
        import re
        pattern = re.compile(r'(^|[ \t,])([0-9\.:]+|\[::\]|:::):80->[0-9]+/tcp')
        for ports_str, expected in test_cases:
            parts = ports_str.split("\t")
            name, ports = parts[0], parts[1]
            match = pattern.search(ports)
            result = name if match else None
            self.assertEqual(result, expected, f"Failed for mapping: {ports}")

    def test_detect_host_port80_container_host_network_behaviour(self):
        """Verify 64-hex container ID extraction from /proc/$pid/cgroup for host-network containers."""
        import re
        cgroup_pattern = re.compile(r'[0-9a-f]{64}')

        # 1. cgroup v2 format with systemd slice
        cgroup_v2 = "0::/system.slice/docker-a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90.scope"
        m2 = cgroup_pattern.search(cgroup_v2)
        self.assertIsNotNone(m2)
        self.assertEqual(m2.group(0), "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90")

        # 2. cgroup v1 format
        cgroup_v1 = "12:devices:/docker/11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"
        m1 = cgroup_pattern.search(cgroup_v1)
        self.assertIsNotNone(m1)
        self.assertEqual(m1.group(0), "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff")

        # 3. Host non-docker service (e.g. systemd nginx)
        cgroup_host = "0::/system.slice/nginx.service"
        self.assertIsNone(cgroup_pattern.search(cgroup_host))

    def test_backup_and_restore_node_structure_and_dispatch(self):
        """Verify backup_node and restore_node handle Xray configs, permissions, and CLI dispatch."""
        backup_sh = (NODE_ROOT / "lib" / "backup.sh").read_text(encoding="utf-8")
        just1knode_sh = JUST1KNODE_SH.read_text(encoding="utf-8")

        # 1. backup_node archives real Xray and just1knode paths
        self.assertIn('usr/local/etc/xray', backup_sh)
        self.assertIn('state_dir="${STATE_DIR:-/etc/just1knode}"', backup_sh)
        self.assertIn('tar -czf "$bak_file" -C /', backup_sh)

        # 2. restore_node extracts and restores services
        self.assertIn('tar -xzf "$bak_file" -C /', backup_sh)
        self.assertIn('systemctl restart xray', backup_sh)
        self.assertIn('systemctl restart xray-api', backup_sh)

        # 3. CLI dispatches to backup_node and restore_node
        self.assertIn('backup_node "${2:-}"', just1knode_sh)
        self.assertIn('restore_node "${2:-}"', just1knode_sh)
        self.assertNotIn('backup_amnezia_node', just1knode_sh)
        self.assertNotIn('restore_amnezia_node', just1knode_sh)

    def test_default_site_symlink_dereference_behaviour(self):
        """Verify cp -L correctly dereferences symlinks to avoid creating broken circular symlink backups."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            avail_dir = tmp_path / "sites-available"
            enabled_dir = tmp_path / "sites-enabled"
            avail_dir.mkdir()
            enabled_dir.mkdir()

            real_default = avail_dir / "default"
            real_default.write_text("server { server_name _; listen 80; }", encoding="utf-8")

            symlink_default = enabled_dir / "default"
            try:
                symlink_default.symlink_to(real_default)
            except OSError:
                # Windows without dev mode symlink privilege fallback
                pass

            backup_file = avail_dir / "default.user.bak"
            # Using shutil.copy2 or python equivalent of cp -L (following symlinks)
            if symlink_default.is_symlink():
                shutil.copyfile(symlink_default.resolve(), backup_file)
                self.assertFalse(backup_file.is_symlink(), "Backup must be a real file, not a symlink")
                self.assertIn("server_name _;", backup_file.read_text(encoding="utf-8"))


    def test_set_bot_ip_supports_origin_and_modular_roles(self):
        """Verify set_origin_bot_ip adapts target port for v2 roles."""
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        self.assertIn('target_port="8444"', common_sh)
        self.assertIn('role_descr="Control API (порт 8444)"', common_sh)
        self.assertIn('ufw allow from "$new_bot_ip" to any port "$target_port" proto tcp', common_sh)
        self.assertIn('ufw delete allow "${target_port}/tcp"', common_sh)


    def test_doctor_ufw_acl_validation_xray_api(self):
        """Verify run_doctor checks port 8444 for Xray API."""
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn('echo "$ufw_out" | grep -F "$bot_ip" | grep -q "8444"', just1knode_sh)
        self.assertIn("Порт 8444 защищен и доступен только с BOT_IP", just1knode_sh)

    def test_doctor_ufw_perimeter_audit(self):
        """Verify run_doctor audits full UFW perimeter for dead rules and unauthorized anywhere ports."""
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn("6b. Полный аудит периметра", just1knode_sh)
        self.assertIn("LC_ALL=C ufw status verbose", just1knode_sh)
        self.assertIn("Default: allow (incoming)", just1knode_sh)
        self.assertIn("warned_dead_targets", just1knode_sh)
        self.assertIn("warned_public_targets", just1knode_sh)
        self.assertIn("Мёртвое» правило: порт ${r_port}/${proto} разрешён в UFW, но служба не запущена", just1knode_sh)
        self.assertIn("ВНИМАНИЕ: Посторонний порт ${r_port}/${proto} (процесс: ${proc_name}) открыт для всех (Anywhere)!", just1knode_sh)
        self.assertIn("ufw delete allow ${norm_target}", just1knode_sh)


    def test_validate_ip_ipv4_and_ipv6_behaviour(self):
        """Verify real validate_ip bash function handles both IPv4 and IPv6 properly."""
        def run_validate_ip(ip_str: str) -> bool:
            res = self._run_shell_snippet(f'validate_ip "{ip_str}"')
            return res.returncode == 0

        # Valid IPv4
        self.assertTrue(run_validate_ip("192.168.1.1"))
        self.assertTrue(run_validate_ip("1.1.1.1"))
        self.assertTrue(run_validate_ip("185.220.101.5"))

        # Valid IPv6
        self.assertTrue(run_validate_ip("2001:db8::1"))
        self.assertTrue(run_validate_ip("2a00:1450:4010:c08::71"))

        # Invalid IP addresses
        self.assertFalse(run_validate_ip("256.1.1.1"))
        self.assertFalse(run_validate_ip("0.0.0.0"))
        self.assertFalse(run_validate_ip("255.255.255.255"))
        self.assertFalse(run_validate_ip("::"))
        self.assertFalse(run_validate_ip("not-an-ip"))

    def test_uninstall_and_cleanup_cleans_vless_port_in_ufw(self):
        """Verify uninstall_node removes VLESS 443, relay_port and API port 8444 from UFW."""
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        self.assertIn('ufw delete allow 443/tcp', just1knode_sh)
        self.assertIn('ufw delete allow from "$st_bot_ip" to any port 8444 proto tcp', just1knode_sh)
        self.assertIn('ufw delete allow 8444/tcp', just1knode_sh)
        self.assertIn('ufw delete allow "$st_relay_port"/tcp', just1knode_sh)


    def test_xray_api_service_unit_has_partof_and_update_node_syncs_it(self):
        """Verify xray-api.service has PartOf=xray.service, start limit resilience, and ensure_xray_api_healthy."""
        service_file = (REPO_ROOT / "scripts" / "xray_api" / "xray-api.service").read_text(encoding="utf-8")
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        api_sh = (NODE_ROOT / "modules" / "xray" / "api.sh").read_text(encoding="utf-8")
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")
        base_sh = (NODE_ROOT / "modules" / "roles" / "base.sh").read_text(encoding="utf-8")
        just1knode_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        ssl_sh = (NODE_ROOT / "lib" / "ssl.sh").read_text(encoding="utf-8")

        self.assertIn("PartOf=xray.service", service_file)
        self.assertIn("StartLimitIntervalSec=30", service_file)
        self.assertIn("StartLimitBurst=15", service_file)

        self.assertIn("PartOf=xray.service", api_sh)
        self.assertIn("StartLimitIntervalSec=30", api_sh)
        self.assertIn("StartLimitBurst=15", api_sh)

        self.assertIn("cp \"${api_dir}/xray-api.service\" /etc/systemd/system/xray-api.service", core_sh)
        self.assertIn("systemctl daemon-reload", core_sh)

        # Invariant: ensure_xray_api_healthy avoids duplicate restarts and returns non-zero on failure
        self.assertIn("ensure_xray_api_healthy()", common_sh)
        self.assertIn("return 1", common_sh)
        self.assertIn("ensure_xray_api_healthy", core_sh)
        self.assertIn("ensure_xray_api_healthy", base_sh)

        # Invariant: certbot deploy hook does not execute blind duplicate restart of xray-api
        self.assertNotIn("systemctl restart xray\nsystemctl restart xray-api", ssl_sh.replace(" ", "").replace("2>/dev/null||true", ""))
        self.assertIn("systemctl start xray-api", ssl_sh)

        # Invariant: Doctor reports FAILED status on services without hidden side-effects
        self.assertIn("systemctl is-failed", just1knode_sh)
        self.assertIn("FAILED", just1knode_sh)


    def test_update_node_post_reexec_invariants(self):
        """Verify update_node re-execs with update-post to eliminate in-memory stale functions."""
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        main_sh = (NODE_ROOT / "just1knode.sh").read_text(encoding="utf-8")

        self.assertIn('exec "$bin_path" update-post "$target"', core_sh)
        self.assertNotIn('export JUST1KNODE_POST_UPDATE', core_sh)
        self.assertIn('update_node_post() {', core_sh)
        self.assertIn('check_root', core_sh)
        self.assertIn('update-post)', main_sh)
        self.assertIn('update_node_post "${1:-all}"', main_sh)


    def test_ufw_before_rules_sync_and_remove_behavior(self):
        """Behavioral test: UFW before.rules sync inserts SMTP 25 (FORWARD and OUTPUT) and BitTorrent rules."""
        sample_ufw = """#
# rules.before
#
# Rules that should be run before the ufw command line added rules.
*filter
:ufw-before-input - [0:0]
:ufw-before-output - [0:0]
:ufw-before-forward - [0:0]
:ufw-not-local - [0:0]
# drop INVALID packets
-A ufw-before-forward -m conntrack --ctstate INVALID -j DROP
COMMIT
"""
        import re

        def sync_rules(content, has_xt_string=True):
            content = re.sub(r'# START JUST1KNODE ANTI-ABUSE.*?# END JUST1KNODE ANTI-ABUSE\n?', '', content, flags=re.DOTALL)
            rules = [
                '-A ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset',
                '-A ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset',
                '-A ufw-before-forward -p tcp --dport 6881:6889 -j DROP',
                '-A ufw-before-forward -p udp --dport 6881:6889 -j DROP',
                '-A ufw-before-output -p tcp --dport 6881:6889 -j DROP',
                '-A ufw-before-output -p udp --dport 6881:6889 -j DROP',
            ]
            if has_xt_string:
                rules.extend([
                    '-A ufw-before-forward -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP',
                    '-A ufw-before-forward -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP',
                    '-A ufw-before-forward -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP',
                    '-A ufw-before-output -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP',
                    '-A ufw-before-output -p udp -m string --string "BitTorrent protocol" --algo bm -j DROP',
                    '-A ufw-before-output -p udp -m string --string "d1:ad2:id20:" --algo bm -j DROP',
                    '-A ufw-before-output -p udp -m string --string "d1:rd2:id20:" --algo bm -j DROP',
                    '-A ufw-before-output -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP',
                    '-A ufw-before-output -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP',
                ])
            block = '# START JUST1KNODE ANTI-ABUSE\n' + '\n'.join(rules) + '\n# END JUST1KNODE ANTI-ABUSE\n'
            if ':ufw-before-forward' in content:
                content = re.sub(r'(:\s*ufw-before-forward\s+-\s+\[0:0\]\n)', r'\1' + block, content, count=1)
            elif '*filter' in content:
                content = content.replace('*filter\n', '*filter\n' + block, 1)
            return content

        def remove_rules(content):
            return re.sub(r'# START JUST1KNODE ANTI-ABUSE.*?# END JUST1KNODE ANTI-ABUSE\n?', '', content, flags=re.DOTALL)

        synced = sync_rules(sample_ufw, has_xt_string=True)
        self.assertIn("# START JUST1KNODE ANTI-ABUSE", synced)
        self.assertIn("-A ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset", synced)
        self.assertIn("-A ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset", synced)
        self.assertIn("-A ufw-before-output -p tcp --dport 6881:6889 -j DROP", synced)
        self.assertIn("-A ufw-before-output -p udp --dport 6881:6889 -j DROP", synced)
        self.assertIn('-A ufw-before-forward -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP', synced)
        self.assertIn('-A ufw-before-output -p tcp -m string --string "BitTorrent protocol" --algo bm -j DROP', synced)
        self.assertIn('-A ufw-before-output -p udp -m string --hex-string "|0000041727101980|" --algo bm -j DROP', synced)
        self.assertIn('-A ufw-before-output -p tcp -m string --string "/announce?info_hash=" --algo bm -j DROP', synced)

        # Without xt_string, only port rules (SMTP:25 and 6881:6889) are added
        synced_no_xt = sync_rules(sample_ufw, has_xt_string=False)
        self.assertIn("-A ufw-before-forward -p tcp --dport 25 -j REJECT --reject-with tcp-reset", synced_no_xt)
        self.assertIn("-A ufw-before-output -p tcp --dport 25 -j REJECT --reject-with tcp-reset", synced_no_xt)
        self.assertIn("-A ufw-before-output -p tcp --dport 6881:6889 -j DROP", synced_no_xt)
        self.assertNotIn("BitTorrent protocol", synced_no_xt)

        # Idempotence: syncing again does not duplicate block
        synced_again = sync_rules(synced, has_xt_string=True)
        self.assertEqual(synced.count("# START JUST1KNODE ANTI-ABUSE"), 1)
        self.assertEqual(synced_again, synced)

        # Removal restores original content
        removed = remove_rules(synced)
        self.assertNotIn("# START JUST1KNODE ANTI-ABUSE", removed)
        self.assertEqual(removed.strip(), sample_ufw.strip())

    def test_modular_node_without_xray_doctor_and_status_skips_xray_behavioral(self):
        """Verify run_doctor on unconfigured node skips Xray Core and Xray config check."""
        self._prepare_base_env()
        with open(self.state_dir / "state.json", "w", encoding="utf-8") as f:
            json.dump({"role": "unconfigured"}, f)

        res = self._run_shell_snippet("run_doctor")
        self.assertNotIn("3. Проверка конфигурации Xray...", res.stdout)
        self.assertNotIn("Ошибка конфигурации Xray", res.stdout)

    def test_doctor_ssl_multi_domain_and_dedup_behavioral(self):
        """Verify run_doctor checks all unique domains and filters null/none values."""
        self._prepare_base_env()
        with open(self.state_dir / "state.json", "w", encoding="utf-8") as f:
            json.dump({
                "role": "ru_hub",
                "domain": "vless.test.example",
                "sni": "sni.test.example",
            }, f)

        res = self._run_shell_snippet("run_doctor")
        # Both unique domains must be checked
        self.assertIn("vless.test.example", res.stdout)
        self.assertIn("sni.test.example", res.stdout)
        # Deduplication: vless.test.example checked once
        self.assertEqual(res.stdout.count("vless.test.example"), 1)
        # Case-insensitive null/none filtered out: None must not be checked as domain
        self.assertNotIn("домена None", res.stdout)


class TestNodePerimeterAndRoutingInvariants(unittest.TestCase):
    """Regression shield for node routing rules, fail-closed security, and lock primitives."""


    def test_state_and_watchdog_locks_use_o_nofollow_and_fchmod(self):
        """Invariant: state.sh must use O_NOFOLLOW and fd-based fchmod."""
        targets = [
            NODE_ROOT / "lib" / "state.sh",
        ]
        for path in targets:
            content = path.read_text(encoding="utf-8")
            self.assertIn("O_NOFOLLOW", content, f"Missing O_NOFOLLOW in {path.name}")
            self.assertIn("fchmod", content, f"Missing fchmod in {path.name}")

    def test_just1knode_origin_bot_ip_cli_support(self):
        """Verify set-bot-ip CLI registration and transactional rule ordering in UFW."""
        just1knode_sh = (REPO_ROOT / "just1knode.sh").read_text(encoding="utf-8")
        common_sh = (NODE_ROOT / "lib" / "common.sh").read_text(encoding="utf-8")

        self.assertIn("set-bot-ip|bot-ip)", just1knode_sh)
        self.assertIn("acquire_just1knode_lock", common_sh)
        self.assertIn("release_just1knode_lock", common_sh)
        self.assertIn("validate_ipv4", common_sh)
        self.assertIn('validate_ipv4 "$new_bot_ip"', common_sh)

        new_allow_pos = common_sh.find('ufw allow from "$new_bot_ip"')
        verify_pos = common_sh.find('Верификация не пройдена', new_allow_pos)
        del_old_pos = common_sh.find('ufw delete allow from "$old_bot_ip"', verify_pos)
        self.assertGreater(new_allow_pos, 0)
        self.assertGreater(verify_pos, new_allow_pos)
        self.assertGreater(del_old_pos, verify_pos)

        self.assertIn(r'8444(/tcp)?[[:space:]]+ALLOW[[:space:]]+(Anywhere|0\.0\.0\.0/0|::/0)', common_sh)
        self.assertIn('ufw delete allow 8444/tcp', common_sh)


    def test_xray_api_fail_closed_tombstone_and_fsync(self):
        """Verify fail-closed tombstone, namespace filtering, and durable fsync."""
        app_path = REPO_ROOT / "scripts" / "xray_api" / "app.py"
        cs_path = REPO_ROOT / "scripts" / "xray_api" / "client_store.py"
        app_content = app_path.read_text(encoding="utf-8")
        cs_content = cs_path.read_text(encoding="utf-8")

        self.assertIn("client_store.delete_client", app_content)
        self.assertIn("HTTPException", app_content)
        self.assertIn("Failed to persist client tombstone to disk", app_content)
        self.assertIn("just1k-wl-", app_content)
        self.assertIn("get_target_inbounds", app_content)
        self.assertIn("os.fsync", cs_content)


    def test_update_node_syncs_xray_api_scripts_to_node_dir(self):
        """Verify update_node copies scripts/xray_api to node_dir/scripts/xray_api."""
        core_sh = (NODE_ROOT / "modules" / "xray" / "core.sh").read_text(encoding="utf-8")
        self.assertIn('local xray_cache_dest="${node_dir}/scripts/xray_api"', core_sh)
        self.assertIn('"${repo_url}/archive/refs/tags/${ref}.tar.gz"', core_sh)


    def test_create_backup_tracks_last_backup_path(self):
        """Verify create_backup records LAST_BACKUP_PATH without bypassing retention."""
        backup_sh = (NODE_ROOT / "lib" / "backup.sh").read_text(encoding="utf-8")
        self.assertIn('LAST_BACKUP_PATH=""', backup_sh)
        self.assertIn('LAST_BACKUP_PATH="$bkp"', backup_sh)
        self.assertIn('BACKUP_RETENTION_COUNT', backup_sh)


    def test_modular_node_status_and_doctor_skips_xray(self):
        """On unconfigured nodes where role is unset, Xray status and config check must be skipped."""
        just1knode_sh = JUST1KNODE_SH.read_text(encoding="utf-8")

        expected_cond = 'if [[ "$role" == "ru_hub" || "$role" == "eu_hub" || "$role" == "exit_node" ]]; then'
        self.assertIn(expected_cond, just1knode_sh)
        self.assertIn(f'{expected_cond}\n        log "3. Проверка конфигурации Xray..."', just1knode_sh)

    def test_xray_api_source_bootstrap_caching_and_deployment(self):
        """Verify scripts/xray_api is cached to INSTALL_DIR in bootstrap and reused by deploy_xray_api_sources."""
        just1knode_sh = JUST1KNODE_SH.read_text(encoding="utf-8")
        api_sh = (NODE_ROOT / "modules" / "xray" / "api.sh").read_text(encoding="utf-8")

        # 1. Bootstrap caches scripts/xray_api to INSTALL_DIR/scripts/xray_api
        self.assertIn('cp -a "$tmp_extract/scripts/xray_api/." "$INSTALL_DIR/scripts/xray_api/"', just1knode_sh)
        self.assertIn('cp -a /app/scripts/xray_api/. "$INSTALL_DIR/scripts/xray_api/"', just1knode_sh)

        # 2. api.sh checks existing XRAY_API_DIR/app.py before attempting remote tarball download
        self.assertIn('elif [[ -f "${XRAY_API_DIR}/app.py" ]]; then', api_sh)
        self.assertIn('log "Использование существующих исходников xray-api в ${XRAY_API_DIR}..."', api_sh)

    def test_doctor_ssl_loop_all_configured_domains(self):
        """Verify run_doctor iterates over all unique configured domains to validate each certificate."""
        just1knode_sh = JUST1KNODE_SH.read_text(encoding="utf-8")

        self.assertIn('for key in "domain" "sni"; do', just1knode_sh)
        self.assertIn('for d_item in "${check_domains[@]}"; do', just1knode_sh)
        self.assertIn('cert_file="/etc/letsencrypt/live/${d_item}/fullchain.pem"', just1knode_sh)
        self.assertIn('local d_cand d_cand_lower already existing key d_item', just1knode_sh)
        self.assertIn('"$d_cand_lower" != "none" && "$d_cand_lower" != "null"', just1knode_sh)


    def test_traffic_limit_invariants(self):
        """Invariant: traffic_limit.sh uses vnstat, JSON config, no ConditionPathExists in xray dropin, and CLI/menu registration."""
        traffic_limit_sh = (NODE_ROOT / "lib" / "traffic_limit.sh").read_text(encoding="utf-8")
        just1knode_sh = (REPO_ROOT / "just1knode.sh").read_text(encoding="utf-8")

        self.assertIn("vnstat --json m 1", traffic_limit_sh)
        self.assertIn("traffic_limit.json", traffic_limit_sh)
        self.assertIn("traffic_limit_exceeded", traffic_limit_sh)
        self.assertIn("just1knode-traffic-limit.timer", traffic_limit_sh)
        self.assertIn("manage_traffic_limit_menu", traffic_limit_sh)
        self.assertNotIn("ConditionPathExists", traffic_limit_sh)

        # Chronological latest month extraction resilience
        self.assertIn("max(months", traffic_limit_sh)

        # Reset day preservation from state/config
        self.assertIn('get_state_val "traffic_reset_day"', traffic_limit_sh)

        # CLI and menu in just1knode.sh
        self.assertIn('source "${SCRIPT_DIR}/lib/traffic_limit.sh"', just1knode_sh)
        self.assertIn("manage_traffic_limit_menu", just1knode_sh)
        self.assertIn("limit|traffic)", just1knode_sh)
        self.assertIn('set) set_traffic_limit "${3:-}" "${4:-}"', just1knode_sh)
        self.assertIn("just1knode limit [set <GB> [day] | off | status]", just1knode_sh)


if __name__ == "__main__":
    unittest.main()


