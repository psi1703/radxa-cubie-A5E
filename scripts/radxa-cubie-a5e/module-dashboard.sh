#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

: "${OWNER:=initbox}"
: "${DASHBOARD_PORT:=8080}"
: "${DASHBOARD_API_PORT:=8090}"
: "${TERMINAL_PORT:=7681}"
: "${TRACE_DIR:=/usr/tracefiles}"
: "${LOGFILE:=/var/log/initbox/initbox-install.log}"

DASH_ROOT="/opt/initbox-dashboard"
FRONTEND_DIR="${DASH_ROOT}/frontend"
API_DIR="${DASH_ROOT}/api"
WEB_ROOT="${DASH_ROOT}/dist"
NGINX_SITE="/etc/nginx/sites-available/initbox-dashboard.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/initbox-dashboard.conf"
MODULES_FILE="/etc/initbox-mods.conf"
ROLES_FILE="/etc/pi_roles.conf"

mkdir -p "$(dirname "$LOGFILE")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[DASH $(ts)] $*" | tee -a "$LOGFILE"; }
ok() { echo "[DASH $(ts)] [OK] $*" | tee -a "$LOGFILE"; }
warn() { echo "[DASH $(ts)] [WARN] $*" | tee -a "$LOGFILE" >&2; }
err() { echo "[DASH $(ts)] [ERR] $*" | tee -a "$LOGFILE" >&2; }

apt_safe() {
  apt-get -o Dpkg::Use-Pty=0 -o Acquire::Retries=5 "$@" 2>&1 | tee -a "$LOGFILE"
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

ensure_owner() {
  if ! id -u "$OWNER" >/dev/null 2>&1; then
    warn "User ${OWNER} does not exist yet. Run the A5E base module first."
    exit 1
  fi
}

set_flag() {
  local key="$1" value="$2"
  install -d -m 0755 /etc/initbox
  touch "$MODULES_FILE"
  if grep -q "^${key}=" "$MODULES_FILE" 2>/dev/null; then
    sed -i "s/^${key}=.*/${key}=${value}/" "$MODULES_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$MODULES_FILE"
  fi
}

install_packages() {
  log "Installing React dashboard runtime packages."
  apt_safe update -y
  apt_safe install -y --no-install-recommends ca-certificates curl nginx python3 nodejs npm

  if ! command -v ttyd >/dev/null 2>&1; then
    if apt_safe install -y --no-install-recommends ttyd; then
      ok "ttyd installed from APT."
    else
      warn "ttyd package was not available from APT; dashboard will still work without embedded terminal."
    fi
  fi
}

write_roles_default() {
  if [[ ! -f "$ROLES_FILE" ]]; then
    cat > "$ROLES_FILE" <<'EOR'
ROLES=""
EOR
    chmod 0644 "$ROLES_FILE"
  fi
}

write_mods_default() {
  install -d -m 0755 /etc/initbox
  touch "$MODULES_FILE"
  for key in DASHBOARD ISI FMS WSBR0 HOTSPOT RTC RTCSYNC A5E; do
    if ! grep -q "^${key}=" "$MODULES_FILE" 2>/dev/null; then
      printf '%s=0\n' "$key" >> "$MODULES_FILE"
    fi
  done
}

write_servsync() {
  log "Writing /usr/local/bin/pi-servsync.sh."
  cat > /usr/local/bin/pi-servsync.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

ROLE_FILE="${ROLE_FILE:-/etc/pi_roles.conf}"
SVC_ISI="isirunall.service"
SVC_FMS="fms.service"
SVC_SNIFF="wireshark-autostart.service"

log() {
  echo "[servsync] $*"
  logger -t pi-servsync -- "$*" || true
}

read_roles() {
  local roles=""
  if [[ -r "$ROLE_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ROLE_FILE" || true
    roles="${ROLES:-${roles:-}}"
    roles="${roles,,}"
    roles="${roles//$'\r'/}"
  fi
  printf '%s' "$roles"
}

unit_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q . || [[ -f "/etc/systemd/system/$1" ]]
}

start_enable() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    log "unit not installed: $unit"
    return 0
  fi
  systemctl enable --now "$unit" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "$unit"; then
    log "started $unit"
  else
    log "failed to start $unit"
  fi
}

stop_disable() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    log "unit not installed: $unit"
    return 0
  fi
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  log "stopped+disabled $unit"
}

mode="${1:-apply}"
force_stop=0
case "$mode" in
  stop|stopall|--force-stop) force_stop=1 ;;
  *) force_stop=0 ;;
esac

roles="$(read_roles)"
want_isi=0
want_fms=0
want_sniff=0

if (( force_stop == 0 )); then
  for word in $roles; do
    case "$word" in
      isi) want_isi=1 ;;
      fms) want_fms=1 ;;
      sniff|wsbr0|ws-br0) want_sniff=1 ;;
      *) ;;
    esac
  done
fi

log "parsed roles='${roles}' -> isi:${want_isi} fms:${want_fms} sniff:${want_sniff}"

(( want_sniff )) && start_enable "$SVC_SNIFF" || stop_disable "$SVC_SNIFF"
(( want_isi )) && start_enable "$SVC_ISI" || stop_disable "$SVC_ISI"
(( want_fms )) && start_enable "$SVC_FMS" || stop_disable "$SVC_FMS"
EOS
  chmod 0755 /usr/local/bin/pi-servsync.sh

  cat > /usr/local/bin/pi-rolectl.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/local/bin/pi-servsync.sh "$@"
EOS
  chmod 0755 /usr/local/bin/pi-rolectl.sh
}

write_api() {
  log "Writing dashboard API backend."
  install -d -m 0755 "$API_DIR"
  cat > "${API_DIR}/server.py" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

HOST = "127.0.0.1"
PORT = int(os.environ.get("DASHBOARD_API_PORT", "8090"))
ROLES_FILE = "/etc/pi_roles.conf"
MODULES_FILE = "/etc/initbox-mods.conf"
TRACE_DIR = os.environ.get("TRACE_DIR", "/usr/tracefiles")
SERVICES = {
    "dashboard_api": "initbox-dashboard-api.service",
    "nginx": "nginx.service",
    "terminal": "ttyd.service",
    "isi": "isirunall.service",
    "fms": "fms.service",
    "sniff": "wireshark-autostart.service",
    "hotspot": "hostapd.service",
    "dns": "dnsmasq.service",
}
ROLE_SERVICES = {"isi", "fms", "sniff"}


def run(cmd, timeout=4):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, timeout=timeout)
        return out.strip()
    except Exception:
        return ""


def read_key_file(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                data[key.strip()] = value.strip().strip('"')
    except FileNotFoundError:
        pass
    return data


def write_roles(roles):
    clean = []
    for role in roles:
        role = str(role).strip().lower()
        if role in ROLE_SERVICES and role not in clean:
            clean.append(role)
    tmp = f"{ROLES_FILE}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write('ROLES="{}"\n'.format(" ".join(clean)))
    os.chmod(tmp, 0o644)
    os.replace(tmp, ROLES_FILE)
    subprocess.call(["/usr/local/bin/pi-servsync.sh"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return clean


def service_state(unit):
    active = run(["systemctl", "is-active", unit]) or "unknown"
    enabled = run(["systemctl", "is-enabled", unit]) or "unknown"
    return {"unit": unit, "active": active, "enabled": enabled}


def cpu_percent():
    def snap():
        with open("/proc/stat", "r", encoding="utf-8") as handle:
            parts = handle.readline().split()[1:]
        vals = [int(x) for x in parts[:8]]
        idle = vals[3] + vals[4]
        total = sum(vals)
        return total, idle
    t1, i1 = snap()
    time.sleep(0.2)
    t2, i2 = snap()
    dt = max(t2 - t1, 1)
    di = max(i2 - i1, 0)
    return round(100.0 * (dt - di) / dt, 1)


def mem_percent():
    info = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as handle:
        for line in handle:
            key, value = line.split(":", 1)
            info[key] = int(value.strip().split()[0])
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", 0)
    return round(100.0 * (total - avail) / total, 1) if total else 0.0


def disk_info():
    usage = shutil.disk_usage("/")
    used_pct = round((usage.used / usage.total) * 100.0, 1) if usage.total else 0.0
    avail_gb = round(usage.free / (1024 ** 3), 1)
    return used_pct, avail_gb


def temperature():
    for path in ("/sys/class/thermal/thermal_zone0/temp", "/sys/class/hwmon/hwmon0/temp1_input"):
        try:
            raw = int(open(path, "r", encoding="utf-8").read().strip())
            return round(raw / 1000.0, 1)
        except Exception:
            continue
    return None


def model():
    for path in ("/proc/device-tree/model", "/sys/firmware/devicetree/base/model"):
        try:
            return open(path, "rb").read().replace(b"\x00", b"").decode("utf-8", "ignore").strip()
        except Exception:
            continue
    return platform.machine()


def serial():
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8") as handle:
            for line in handle:
                if line.lower().startswith("serial"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        pass
    machine_id = run(["cat", "/etc/machine-id"])
    return machine_id[:16] if machine_id else "unknown"


def primary_ip():
    out = run(["hostname", "-I"])
    if out:
        for item in out.split():
            if re.match(r"^\d+\.\d+\.\d+\.\d+$", item):
                return item
    return ""


def os_name():
    data = read_key_file("/etc/os-release")
    return data.get("PRETTY_NAME") or data.get("NAME") or platform.platform()


def uptime_seconds():
    try:
        return int(float(open("/proc/uptime", "r", encoding="utf-8").read().split()[0]))
    except Exception:
        return 0


def tracefiles():
    items = []
    if not os.path.isdir(TRACE_DIR):
        return items
    for name in sorted(os.listdir(TRACE_DIR)):
        path = os.path.join(TRACE_DIR, name)
        if not os.path.isfile(path):
            continue
        if not (name.endswith(".zip") or name.endswith(".pcap") or name.endswith(".pcapng")):
            continue
        st = os.stat(path)
        items.append({"name": name, "size": st.st_size, "mtime": int(st.st_mtime), "url": f"/tracefiles/{name}"})
    return list(reversed(items))[:50]


def status_payload():
    roles = read_key_file(ROLES_FILE).get("ROLES", "").split()
    modules = read_key_file(MODULES_FILE)
    used_pct, avail_gb = disk_info()
    return {
        "device": {
            "device_id": socket.gethostname(),
            "hostname": socket.gethostname(),
            "ip": primary_ip(),
            "os": os_name(),
            "model": model(),
            "serial": serial(),
            "uptime_s": uptime_seconds(),
        },
        "metrics": {
            "cpu_pct": cpu_percent(),
            "mem_used_pct": mem_percent(),
            "disk_used_pct": used_pct,
            "disk_avail_gb": avail_gb,
            "temp_c": temperature(),
            "load1": os.getloadavg()[0] if hasattr(os, "getloadavg") else 0,
        },
        "roles": roles,
        "modules": modules,
        "services": {name: service_state(unit) for name, unit in SERVICES.items()},
        "tracefiles": tracefiles(),
        "timestamp": int(time.time()),
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/api/status", "/status"):
            self._send(200, status_payload())
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/roles":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8") if length else "{}"
            try:
                payload = json.loads(body)
                roles = payload.get("roles", [])
                active = write_roles(roles)
                self._send(200, {"ok": True, "roles": active})
            except Exception as exc:
                self._send(400, {"ok": False, "error": str(exc)})
            return
        self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.serve_forever()
PYEOF
  chmod 0755 "${API_DIR}/server.py"
}

write_frontend() {
  log "Writing React dashboard source."
  install -d -m 0755 "$FRONTEND_DIR/src"

  cat > "${FRONTEND_DIR}/package.json" <<'PKGEOF'
{
  "scripts": {
    "build": "vite build --host 127.0.0.1"
  },
  "dependencies": {
    "@vitejs/plugin-react": "latest",
    "vite": "latest",
    "react": "latest",
    "react-dom": "latest",
    "lucide-react": "latest"
  },
  "devDependencies": {}
}
PKGEOF

  cat > "${FRONTEND_DIR}/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>InitBox Dashboard</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/App.jsx"></script>
  </body>
</html>
HTMLEOF

  cat > "${FRONTEND_DIR}/src/App.jsx" <<'APPEOF'
import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './style.css';

const roleLabels = [
  { id: 'isi', label: 'ISI' },
  { id: 'fms', label: 'FMS' },
  { id: 'sniff', label: 'Sniffer' },
];

function fmtUptime(seconds = 0) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return `${d}d ${h}h ${m}m`;
}

function pct(value) {
  return Number.isFinite(Number(value)) ? `${Number(value).toFixed(1)}%` : 'n/a';
}

function gb(value) {
  return Number.isFinite(Number(value)) ? `${Number(value).toFixed(1)} GB` : 'n/a';
}

function temp(value) {
  return value === null || value === undefined ? 'n/a' : `${Number(value).toFixed(1)} C`;
}

function Pill({ label, value }) {
  return (
    <div className="pill">
      <span>{label}</span>
      <strong>{value || 'n/a'}</strong>
    </div>
  );
}

function ServiceBadge({ state }) {
  const active = state?.active === 'active';
  return <span className={`badge ${active ? 'ok' : 'bad'}`}>{state?.active || 'unknown'}</span>;
}

function App() {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  async function load() {
    try {
      const res = await fetch('/api/status', { cache: 'no-store' });
      if (!res.ok) throw new Error(`status ${res.status}`);
      const next = await res.json();
      setData(next);
      setError('');
    } catch (err) {
      setError(String(err));
    }
  }

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 5000);
    return () => window.clearInterval(timer);
  }, []);

  const roles = useMemo(() => new Set(data?.roles || []), [data]);

  async function toggleRole(role) {
    if (!data || saving) return;
    const next = new Set(data.roles || []);
    if (next.has(role)) next.delete(role);
    else next.add(role);
    setSaving(true);
    try {
      const res = await fetch('/api/roles', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ roles: Array.from(next) }),
      });
      if (!res.ok) throw new Error(`save failed ${res.status}`);
      await load();
    } catch (err) {
      setError(String(err));
    } finally {
      setSaving(false);
    }
  }

  const device = data?.device || {};
  const metrics = data?.metrics || {};
  const services = data?.services || {};

  return (
    <main>
      <header className="topbar">
        <div>
          <h1>InitBox Dashboard</h1>
          <p>{device.model || 'Radxa Cubie A5E'} · {device.ip || 'no IP detected'}</p>
        </div>
        <button onClick={load}>Refresh</button>
      </header>

      {error && <div className="alert">{error}</div>}

      <section className="card system-card">
        <h2>System</h2>
        <div className="pill-grid">
          <Pill label="CPU" value={pct(metrics.cpu_pct)} />
          <Pill label="Memory" value={pct(metrics.mem_used_pct)} />
          <Pill label="Disk" value={pct(metrics.disk_used_pct)} />
          <Pill label="Free" value={gb(metrics.disk_avail_gb)} />
          <Pill label="Temp" value={temp(metrics.temp_c)} />
          <Pill label="Hostname" value={device.hostname} />
          <Pill label="IP" value={device.ip} />
          <Pill label="OS" value={device.os} />
          <Pill label="Serial" value={device.serial} />
          <Pill label="Uptime" value={fmtUptime(device.uptime_s)} />
        </div>
      </section>

      <section className="layout">
        <div className="left-stack">
          <section className="card compact-card">
            <h2>Roles</h2>
            <div className="role-row">
              {roleLabels.map((role) => (
                <button
                  key={role.id}
                  className={`role ${roles.has(role.id) ? 'on' : ''}`}
                  disabled={saving}
                  onClick={() => toggleRole(role.id)}
                >
                  {role.label}
                </button>
              ))}
            </div>
          </section>

          <section className="card terminal-card">
            <div className="card-title-row">
              <h2>Terminal</h2>
              <a href="/terminal/" target="_blank" rel="noreferrer">Open full page</a>
            </div>
            <iframe title="terminal" src="/terminal/" />
          </section>
        </div>

        <section className="card files-card">
          <h2>Files and ZIP</h2>
          {data?.tracefiles?.length ? (
            <div className="file-list">
              {data.tracefiles.map((file) => (
                <a key={file.name} href={file.url}>
                  <span>{file.name}</span>
                  <small>{Math.round(file.size / 1024)} KB</small>
                </a>
              ))}
            </div>
          ) : (
            <p className="muted">No trace files found in /usr/tracefiles.</p>
          )}
        </section>
      </section>

      <section className="card">
        <h2>Services</h2>
        <div className="services">
          {Object.entries(services).map(([name, state]) => (
            <div key={name} className="service-row">
              <span>{name}</span>
              <ServiceBadge state={state} />
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}

createRoot(document.getElementById('root')).render(<App />);
APPEOF

  cat > "${FRONTEND_DIR}/src/style.css" <<'CSSEOF'
:root {
  color-scheme: dark;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #0d1117;
  color: #e6edf3;
}

* { box-sizing: border-box; }
body { margin: 0; background: #0d1117; }
main { width: min(1480px, calc(100vw - 32px)); margin: 0 auto; padding: 18px 0 28px; }
h1, h2, p { margin: 0; }
h1 { font-size: 26px; }
h2 { font-size: 17px; margin-bottom: 14px; }
button, a { font: inherit; }

.topbar { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 16px; }
.topbar p { color: #8b949e; margin-top: 4px; }
.topbar button, .role { border: 1px solid #30363d; border-radius: 10px; background: #161b22; color: #e6edf3; padding: 9px 13px; cursor: pointer; }
.topbar button:hover, .role:hover { background: #1f2937; }
.alert { background: #3d1f1f; border: 1px solid #8b3434; color: #ffd5d5; padding: 10px 12px; border-radius: 12px; margin-bottom: 14px; }

.card { background: #161b22; border: 1px solid #30363d; border-radius: 18px; padding: 16px; box-shadow: 0 12px 26px rgba(0,0,0,.18); }
.system-card { margin-bottom: 16px; }
.pill-grid { display: grid; grid-template-columns: repeat(10, minmax(0, 1fr)); gap: 8px; }
.pill { min-width: 0; border: 1px solid #30363d; border-radius: 12px; padding: 9px 10px; background: #0d1117; overflow: hidden; }
.pill span { display: block; color: #8b949e; font-size: 11px; line-height: 1.1; white-space: nowrap; }
.pill strong { display: block; margin-top: 4px; font-size: 12px; line-height: 1.15; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

.layout { display: grid; grid-template-columns: minmax(0, 1.15fr) minmax(330px, .85fr); gap: 16px; align-items: start; margin-bottom: 16px; }
.left-stack { display: grid; grid-template-rows: auto auto; gap: 16px; min-width: 0; }
.compact-card { min-height: 116px; }
.role-row { display: flex; gap: 10px; flex-wrap: wrap; }
.role.on { background: #1f6feb; border-color: #58a6ff; }
.role:disabled { opacity: .6; cursor: wait; }

.terminal-card iframe { width: 100%; height: 390px; border: 1px solid #30363d; border-radius: 12px; background: #000; }
.card-title-row { display: flex; justify-content: space-between; align-items: center; gap: 12px; }
a { color: #58a6ff; text-decoration: none; }
a:hover { text-decoration: underline; }

.files-card { min-height: 522px; }
.file-list { display: grid; gap: 8px; }
.file-list a { display: flex; justify-content: space-between; gap: 10px; border: 1px solid #30363d; background: #0d1117; border-radius: 10px; padding: 9px 10px; color: #e6edf3; }
.file-list span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.file-list small { color: #8b949e; white-space: nowrap; }
.muted { color: #8b949e; }

.services { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 8px; }
.service-row { display: flex; justify-content: space-between; align-items: center; gap: 8px; border: 1px solid #30363d; background: #0d1117; border-radius: 10px; padding: 9px 10px; }
.service-row span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badge { border-radius: 999px; padding: 3px 8px; font-size: 12px; background: #30363d; color: #e6edf3; }
.badge.ok { background: #1f6f43; }
.badge.bad { background: #7d2828; }

@media (max-width: 1180px) {
  .pill-grid { grid-template-columns: repeat(5, minmax(0, 1fr)); }
  .layout { grid-template-columns: 1fr; }
  .files-card { min-height: auto; }
  .services { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}

@media (max-width: 720px) {
  main { width: min(100vw - 20px, 1480px); }
  .topbar { align-items: flex-start; flex-direction: column; }
  .pill-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .services { grid-template-columns: 1fr; }
}
CSSEOF
}

build_frontend() {
  log "Building React dashboard."
  cd "$FRONTEND_DIR"
  npm install 2>&1 | tee -a "$LOGFILE"
  npm run build 2>&1 | tee -a "$LOGFILE"
  rm -rf "$WEB_ROOT"
  cp -a "${FRONTEND_DIR}/dist" "$WEB_ROOT"
  chown -R root:root "$DASH_ROOT"
}

write_services() {
  log "Writing systemd services."
  cat > /etc/systemd/system/initbox-dashboard-api.service <<EOF2
[Unit]
Description=InitBox React Dashboard API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DASHBOARD_API_PORT=${DASHBOARD_API_PORT}
Environment=TRACE_DIR=${TRACE_DIR}
ExecStart=/usr/bin/python3 ${API_DIR}/server.py
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF2

  cat > /etc/systemd/system/pi-servsync.service <<'EOF2'
[Unit]
Description=Apply /etc/pi_roles.conf to InitBox services
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pi-servsync.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF2

  if command -v ttyd >/dev/null 2>&1; then
    cat > /etc/systemd/system/ttyd.service <<EOF2
[Unit]
Description=InitBox web terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${OWNER}
Group=${OWNER}
WorkingDirectory=/home/${OWNER}
ExecStart=$(command -v ttyd) -p ${TERMINAL_PORT} -i 127.0.0.1 --writable bash -l
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF2
  fi
}

write_nginx() {
  log "Writing nginx dashboard site."
  install -d -m 0755 "$TRACE_DIR"
  chown "$OWNER:$OWNER" "$TRACE_DIR" 2>/dev/null || true

  cat > "$NGINX_SITE" <<EOF2
server {
    listen 80 default_server;
    server_name _;
    return 302 http://\$host:${DASHBOARD_PORT}\$request_uri;
}

server {
    listen ${DASHBOARD_PORT} default_server;
    server_name _;

    root ${WEB_ROOT};
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:${DASHBOARD_API_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /terminal/ {
        proxy_pass http://127.0.0.1:${TERMINAL_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location /tracefiles/ {
        alias ${TRACE_DIR}/;
        autoindex on;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF2

  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$NGINX_SITE" "$NGINX_ENABLED"
  nginx -t 2>&1 | tee -a "$LOGFILE"
}

install_dashboard() {
  require_root
  ensure_owner
  log "Starting React dashboard module."
  install_packages
  write_roles_default
  write_mods_default
  write_servsync
  write_api
  write_frontend
  build_frontend
  write_services
  write_nginx

  systemctl daemon-reload
  systemctl enable --now initbox-dashboard-api.service nginx.service pi-servsync.service 2>/dev/null || true
  systemctl restart initbox-dashboard-api.service nginx.service 2>/dev/null || true
  if [[ -f /etc/systemd/system/ttyd.service ]]; then
    systemctl enable --now ttyd.service 2>/dev/null || true
    systemctl restart ttyd.service 2>/dev/null || true
  fi
  /usr/local/bin/pi-servsync.sh || true

  set_flag DASHBOARD 1
  ok "React dashboard installed: http://initbox.wlan:${DASHBOARD_PORT}/"
  ok "Same-host portal redirect is installed on port 80."
}

uninstall_dashboard() {
  require_root
  log "Uninstalling React dashboard module."
  systemctl stop initbox-dashboard-api.service ttyd.service pi-servsync.service 2>/dev/null || true
  systemctl disable initbox-dashboard-api.service ttyd.service pi-servsync.service 2>/dev/null || true
  rm -f /etc/systemd/system/initbox-dashboard-api.service \
        /etc/systemd/system/ttyd.service \
        /etc/systemd/system/pi-servsync.service
  rm -f "$NGINX_ENABLED" "$NGINX_SITE"
  systemctl reload nginx.service 2>/dev/null || true
  systemctl daemon-reload
  rm -rf "$DASH_ROOT"
  rm -f /usr/local/bin/pi-servsync.sh /usr/local/bin/pi-rolectl.sh
  set_flag DASHBOARD 0
  ok "React dashboard module uninstalled."
}

case "${1:-install}" in
  install) install_dashboard ;;
  uninstall|remove) uninstall_dashboard ;;
  *)
    err "Usage: $0 [install|uninstall]"
    exit 2
    ;;
esac
