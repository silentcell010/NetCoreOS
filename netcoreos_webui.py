#!/usr/bin/env python3
"""
NetCoreOS Web UI Server — 0.1 BETA
Author: Silent Cell
Every command typed in the web UI is executed via:
  bash netcoreos.sh --web-exec "<command>"
This means 100% of NetCoreOS commands work identically in the browser.
"""
import http.server
import socketserver
import subprocess
import json
import os
import sys
import time
import re
import hmac
import shlex
import ssl
from urllib.parse import urlparse, parse_qs
PORT = 7474
BASE_DIR  = "/var/lib/netcoreos"
LOG_FILE  = os.path.join(BASE_DIR, "netcoreos.log")
STATE_FILE = os.path.join(BASE_DIR, "webui_state.env")
SCRIPT_PATH = os.environ.get("SILENTOS_SCRIPT", "")
START_TIME  = time.time()
BIND_HOST = os.environ.get("NETCOREOS_WEBUI_HOST", "127.0.0.1")
TOKEN_FILE = os.environ.get("NETCOREOS_WEBUI_TOKEN_FILE", os.path.join(BASE_DIR, "webui_token"))
AUTH_TOKEN = ""
if os.path.isfile(TOKEN_FILE):
    try:
        with open(TOKEN_FILE) as _f:
            AUTH_TOKEN = _f.read().strip()
    except Exception:
        AUTH_TOKEN = ""
CERT_FILE = os.environ.get("NETCOREOS_WEBUI_CERT", os.path.join(BASE_DIR, "webui_cert.pem"))
KEY_FILE  = os.environ.get("NETCOREOS_WEBUI_KEY",  os.path.join(BASE_DIR, "webui_key.pem"))
def ensure_self_signed_cert():
    """Make sure CERT_FILE/KEY_FILE exist, generating a self-signed pair via
    openssl the first time the server runs on this machine. Returns False
    (with an explanatory message) if that isn't possible, so main() can
    refuse to start rather than silently falling back to plain HTTP."""
    if os.path.isfile(CERT_FILE) and os.path.isfile(KEY_FILE):
        return True
    try:
        os.makedirs(os.path.dirname(CERT_FILE) or ".", exist_ok=True)
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", KEY_FILE, "-out", CERT_FILE,
             "-days", "3650", "-subj", "/CN=netcoreos"],
            check=True, capture_output=True, timeout=30,
        )
        os.chmod(KEY_FILE, 0o600)
        os.chmod(CERT_FILE, 0o644)
        return True
    except FileNotFoundError:
        print("[NetCoreOS Web UI] ERROR: 'openssl' not found — can't generate a TLS cert.")
        print("  Install openssl, or set NETCOREOS_WEBUI_CERT / NETCOREOS_WEBUI_KEY "
              "to point at a cert/key you already have.")
        return False
    except Exception as e:
        print(f"[NetCoreOS Web UI] ERROR: TLS certificate generation failed ({e}).")
        return False
def find_script():
    global SCRIPT_PATH
    if SCRIPT_PATH and os.path.isfile(SCRIPT_PATH):
        return True
    candidates = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "netcoreos.sh"),
        "/usr/local/bin/netcoreos.sh",
        "/opt/netcoreos/netcoreos.sh",
        os.path.expanduser("~/netcoreos.sh"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            SCRIPT_PATH = c
            return True
    return False
_ANSI = re.compile(r'\x1B\[[0-9;]*[mKHJABCDEFG]')
def strip_ansi(s):
    return _ANSI.sub('', s)
def run_netcoreos(cmd):
    if not SCRIPT_PATH:
        return "[Error] netcoreos.sh not found. Set SILENTOS_SCRIPT env var."
    try:
        result = subprocess.run(
            ["bash", SCRIPT_PATH, "--web-exec", cmd],
            capture_output=True, text=True, timeout=20,
            env={**os.environ, "TERM": "dumb"}
        )
        out = result.stdout + result.stderr
        out = strip_ansi(out).strip()
        return out if out else "(command completed — no output)"
    except subprocess.TimeoutExpired:
        return "[Error] Command timed out after 20 seconds."
    except Exception as e:
        return f"[Error] {e}"
def run_shell(cmd):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=8,
                           env={**os.environ, "TERM": "dumb"})
        return (r.stdout + r.stderr).strip()
    except:
        return ""
def get_mode():
    if not os.path.exists(STATE_FILE):
        return "ncos"
    with open(STATE_FILE) as f:
        for line in f:
            if line.startswith("MODE="):
                return line.strip().split("=", 1)[1]
    return "ncos"
def get_interfaces():
    out = run_shell("ip -br link 2>/dev/null")
    result = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            result.append({"name": parts[0], "state": parts[1], "extra": " ".join(parts[2:])})
    return result
def get_addresses():
    out = run_shell("ip -br addr 2>/dev/null")
    result = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            result.append({"iface": parts[0], "state": parts[1], "ips": parts[2:] if len(parts) > 2 else []})
    return result
def get_routes():
    return run_shell("ip route 2>/dev/null").splitlines()
def get_arp():
    return run_shell("ip neigh show 2>/dev/null").splitlines()
def get_macs():
    return run_shell("bridge fdb show 2>/dev/null | grep -v permanent | head -40 || echo '(no bridge)'").splitlines()
def get_vlans():
    return run_shell("bridge vlan 2>/dev/null || echo '(no bridge)'").splitlines()
def get_firewall():
    return run_shell("iptables -L SILENTOS -v -n 2>/dev/null || echo '(not initialized)'").splitlines()
def get_log_tail(n=100):
    if not os.path.exists(LOG_FILE):
        return []
    return run_shell(f"tail -n {n} {LOG_FILE}").splitlines()
def get_bonds():
    bf = os.path.join(BASE_DIR, "bonds.list")
    if not os.path.exists(bf):
        return []
    result = []
    with open(bf) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 2:
                result.append({"bond": parts[0], "members": parts[1].split(",")})
    return result
def get_vxlans():
    vf = os.path.join(BASE_DIR, "vxlans.list")
    if not os.path.exists(vf):
        return []
    result = []
    with open(vf) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 3:
                result.append({"vni": parts[0], "local": parts[1], "remote": parts[2]})
    return result
def get_monitors():
    mf = os.path.join(BASE_DIR, "monitors.list")
    if not os.path.exists(mf):
        return []
    result = []
    with open(mf) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split("|")
            if len(parts) >= 4:
                pid = parts[3]
                try:
                    os.kill(int(pid), 0)
                    status = "running"
                except:
                    status = "dead"
                result.append({"target": parts[0], "interval": parts[1],
                               "action": parts[2], "pid": pid, "status": status})
    return result
def get_system_stats():
    uptime_s = int(time.time() - START_TIME)
    h, rem = divmod(uptime_s, 3600)
    m, s = divmod(rem, 60)
    cpu = run_shell("top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print $2}' | tr -d '%us,'")
    mem = run_shell("free -m 2>/dev/null | awk 'NR==2{printf \"%.0f\", $3*100/$2}'")
    return {
        "uptime": f"{h:02d}h:{m:02d}m:{s:02d}s",
        "cpu":    cpu.split()[0] if cpu.split() else "0",
        "mem":    mem.strip() or "0",
        "mode":   get_mode(),
    }
def vtysh(cmd):
    """Run a single vtysh command, return text output."""
    try:
        r = subprocess.run(["vtysh", "-c", cmd],
                           capture_output=True, text=True, timeout=8,
                           env={**os.environ, "TERM": "dumb"})
        return (r.stdout + r.stderr).strip()
    except:
        return ""
def frr_running():
    try:
        r = subprocess.run(["systemctl", "is-active", "frr"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "active"
    except:
        return False
def get_frr_status():
    if not frr_running():
        return {"running": False, "version": "", "uptime": ""}
    ver = vtysh("show version")
    ver_line = next((l for l in ver.splitlines() if "FRRouting" in l or "FRR" in l), "")
    return {"running": True, "version": ver_line.strip(), "uptime": ""}
def get_ospf_neighbors():
    if not frr_running(): return []
    raw = vtysh("show ip ospf neighbor")
    result = []
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) >= 6 and parts[0].count('.') == 3:
            result.append({
                "neighbor_id": parts[0],
                "priority":    parts[1],
                "state":       parts[2],
                "dead_time":   parts[3],
                "interface":   parts[4] if len(parts) > 4 else "",
            })
    return result
def get_ospf_routes():
    if not frr_running(): return []
    raw = vtysh("show ip ospf route")
    result = []
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("=") and not line.startswith("Codes"):
            result.append(line)
    return result
def get_bgp_summary():
    if not frr_running(): return {"asn": "", "router_id": "", "peers": []}
    raw = vtysh("show bgp summary")
    asn = ""
    router_id = ""
    peers = []
    in_peers = False
    for line in raw.splitlines():
        if "local AS number" in line:
            try: asn = line.split()[-1]
            except: pass
        if "BGP router identifier" in line:
            try: router_id = line.split()[3].rstrip(",")
            except: pass
        if line.strip().startswith("Neighbor"):
            in_peers = True
            continue
        if in_peers and line.strip():
            parts = line.split()
            if len(parts) >= 9 and parts[0].count('.') == 3:
                peers.append({
                    "neighbor":  parts[0],
                    "version":   parts[1],
                    "remote_as": parts[2],
                    "msg_rcvd":  parts[3],
                    "msg_sent":  parts[4],
                    "up_down":   parts[8] if len(parts) > 8 else "",
                    "state":     parts[9] if len(parts) > 9 else "",
                })
    if not asn:
        bgp_file = os.path.join(BASE_DIR, "bgp.conf")
        if os.path.exists(bgp_file):
            with open(bgp_file) as f:
                for line in f:
                    if line.startswith("BGP_ASN="):
                        asn = line.strip().split("=", 1)[1]
    return {"asn": asn, "router_id": router_id, "peers": peers}
def get_bgp_routes():
    if not frr_running(): return []
    raw = vtysh("show bgp ipv4 unicast")
    result = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("BGP") or line.startswith("Origin") or line.startswith("Status"):
            continue
        if line and line[0] in "*isShdruR ":
            result.append(line)
    return result
def get_prefix_lists():
    raw = vtysh("show ip prefix-list") if frr_running() else ""
    if not raw:
        pf = os.path.join(BASE_DIR, "prefixlists.list")
        if os.path.exists(pf):
            with open(pf) as f:
                return [{"name": l.split("|")[0], "action": l.split("|")[1] if "|" in l else "",
                         "prefix": l.split("|")[2] if l.count("|") >= 2 else ""}
                        for l in f.read().splitlines() if l.strip()]
        return []
    result = []
    current = None
    for line in raw.splitlines():
        if line.startswith("ip prefix-list"):
            parts = line.split()
            if len(parts) >= 5:
                current = {"name": parts[2], "action": parts[4],
                           "prefix": parts[5] if len(parts) > 5 else ""}
                result.append(current)
    return result
def get_route_maps():
    raw = vtysh("show route-map") if frr_running() else ""
    if not raw:
        rmf = os.path.join(BASE_DIR, "routemaps.list")
        if os.path.exists(rmf):
            with open(rmf) as f:
                return [{"name": l.split("|")[0], "action": l.split("|")[1] if "|" in l else "",
                         "seq": l.split("|")[2] if l.count("|") >= 2 else ""}
                        for l in f.read().splitlines() if l.strip()]
        return []
    result = []
    for line in raw.splitlines():
        if line.startswith("RPKI") or line.startswith("route-map"):
            parts = line.split()
            if len(parts) >= 4:
                result.append({"name": parts[1], "action": parts[2], "seq": parts[3]})
    return result
def get_vrrp_instances():
    vf = os.path.join(BASE_DIR, "vrrp.list")
    if not os.path.exists(vf): return []
    result = []
    with open(vf) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            parts = line.split("|")
            if len(parts) >= 4:
                vrid, iface, vip, prio = parts[0], parts[1], parts[2], parts[3]
                addrs = run_shell(f"ip addr show {shlex.quote(iface)} 2>/dev/null")
                state = "MASTER" if vip in addrs else "BACKUP"
                result.append({"vrid": vrid, "iface": iface, "vip": vip,
                               "priority": prio, "state": state})
    return result
def get_bfd_peers():
    """Return BFD peer status from FRR."""
    if not frr_running():
        return []
    raw = vtysh("show bfd peers")
    result = []
    current = {}
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("BFD Peer:") or line.startswith("peer"):
            if current:
                result.append(current)
            ip = line.split()[-1].strip("()")
            current = {"peer": ip, "state": "unknown", "tx": "", "rx": "", "mult": ""}
        elif "Status:" in line or "state:" in line.lower():
            current["state"] = line.split(":")[-1].strip()
        elif "Transmit interval:" in line or "TX:" in line:
            current["tx"] = line.split(":")[-1].strip()
        elif "Receive interval:" in line or "RX:" in line:
            current["rx"] = line.split(":")[-1].strip()
    if current:
        result.append(current)
    return result
def get_topology():
    """Build a complete network topology graph for the web UI."""
    nodes = []
    edges = []
    node_ids = set()
    def add_node(nid, label, ntype, extra=None):
        if nid not in node_ids:
            node_ids.add(nid)
            nodes.append({"id": nid, "label": label, "type": ntype, **(extra or {})})
    ifaces = get_interfaces()
    addrs  = get_addresses()
    addr_map = {a["iface"]: a["ips"] for a in addrs}
    for iface in ifaces:
        name  = iface["name"]
        state = iface["state"].lower()
        ips   = addr_map.get(name, [])
        if name == "lo":
            itype = "loopback"
        elif name.startswith("vxlan"):
            itype = "vxlan"
        elif name.startswith("bond"):
            itype = "bond"
        elif name.startswith("br"):
            itype = "bridge"
        elif "." in name:
            itype = "vlan"
        else:
            itype = "physical"
        add_node(name, name, itype, {"state": state, "ips": ips})
    bridge_members_raw = run_shell("bridge link show 2>/dev/null")
    for line in bridge_members_raw.splitlines():
        m_master = __import__("re").search(r"master\s+(\S+)", line)
        m_iface  = __import__("re").search(r"^\d+:\s+(\S+?)[@:]", line)
        if m_master and m_iface:
            member = m_iface.group(1).split("@")[0]
            bridge = m_master.group(1)
            if member in node_ids and bridge in node_ids:
                edges.append({"from": bridge, "to": member, "label": "member", "etype": "bridge"})
    for iface in ifaces:
        name = iface["name"]
        if "." in name:
            parent = name.rsplit(".", 1)[0]
            vlan_id = name.rsplit(".", 1)[1]
            if parent in node_ids:
                edges.append({"from": parent, "to": name, "label": f"VLAN {vlan_id}", "etype": "vlan"})
    bonds_file = os.path.join(BASE_DIR, "bonds.list")
    if os.path.exists(bonds_file):
        with open(bonds_file) as f:
            for line in f:
                line = line.strip()
                if not line: continue
                parts = line.split("|")
                if len(parts) >= 2:
                    bond = parts[0]
                    for member in parts[1].split(","):
                        member = member.strip()
                        if bond in node_ids and member in node_ids:
                            edges.append({"from": bond, "to": member, "label": "bond member", "etype": "bond"})
    vxlans = get_vxlans()
    for vx in vxlans:
        vxname = f"vxlan{vx['vni']}"
        remote_id = f"remote:{vx['remote']}"
        add_node(remote_id, vx["remote"], "remote", {"state": "up", "ips": [vx["remote"]]})
        if vxname in node_ids:
            edges.append({"from": vxname, "to": remote_id, "label": f"VNI {vx['vni']}", "etype": "vxlan"})
    routes = get_routes()
    gw_seen = set()
    for route in routes:
        parts = route.split()
        if "via" in parts:
            via_idx = parts.index("via")
            gw = parts[via_idx + 1] if via_idx + 1 < len(parts) else None
            dev = parts[parts.index("dev") + 1] if "dev" in parts else None
            dest = parts[0]
            if gw and gw not in gw_seen:
                gw_seen.add(gw)
                gw_id = f"gw:{gw}"
                add_node(gw_id, f"GW\n{gw}", "gateway", {"state": "up", "ips": [gw]})
                if dev and dev in node_ids:
                    edges.append({"from": dev, "to": gw_id, "label": dest, "etype": "route"})
    monitors = get_monitors()
    for mon in monitors:
        mon_id = f"mon:{mon['target']}"
        add_node(mon_id, f"👁 {mon['target']}", "monitor",
                 {"state": mon["status"], "ips": [mon["target"]]})
        edges.append({"from": "lo", "to": mon_id, "label": "SLA", "etype": "monitor"})
    fw_rules = get_firewall()
    if fw_rules and "(not initialized)" not in fw_rules[0]:
        add_node("__fw__", "🛡 Firewall", "firewall", {"state": "up", "ips": []})
    return {"nodes": nodes, "edges": edges}
def log_web(cmd):
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    try:
        os.makedirs(BASE_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"[{ts}] [WEB] {cmd}\n")
    except:
        pass
HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>NetCoreOS — Network Control Panel</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;600;700&family=Syne:wght@400;700;800&display=swap" rel="stylesheet">
<style>
:root{--bg:#1a1b1e;--bg2:#222428;--bg3:#2a2d32;--border:#333740;--border2:#444b57;--text:#d4d8e2;--text2:#8b92a5;--text3:#555e70;--green:#39d98a;--green2:#1f7a4d;--cyan:#38bdf8;--cyan2:#0c4a6e;--yellow:#fbbf24;--yellow2:#78350f;--red:#f87171;--red2:#7f1d1d;--purple:#a78bfa;--orange:#fb923c;--font-mono:'JetBrains Mono',monospace;--font-head:'Syne',sans-serif}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--font-mono);font-size:13px;height:100vh;overflow:hidden;display:flex;flex-direction:column}
header{background:var(--bg2);border-bottom:1px solid var(--border);padding:0 20px;height:52px;display:flex;align-items:center;gap:20px;flex-shrink:0}
.logo{font-family:var(--font-head);font-size:18px;font-weight:800;color:#fff;display:flex;align-items:center;gap:8px}
.logo span{color:var(--cyan)}.logo-dot{width:8px;height:8px;background:var(--green);border-radius:50%;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.5;transform:scale(.8)}}
.header-stats{display:flex;gap:16px;margin-left:auto;align-items:center}
.stat-pill{display:flex;align-items:center;gap:6px;background:var(--bg3);border:1px solid var(--border);border-radius:20px;padding:4px 12px;font-size:11px;color:var(--text2)}
.stat-pill .val{color:var(--text);font-weight:600}
.mode-badge{padding:4px 14px;border-radius:20px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:1px;border:1px solid}
.mode-ncos{background:#1a2e22;border-color:var(--green2);color:var(--green)}
.mode-switch{background:var(--cyan2);border-color:#075985;color:var(--cyan)}
.mode-switchmls{background:#0c4060;border-color:#075985;color:#7dd3fc}
.mode-router{background:var(--yellow2);border-color:#92400e;color:var(--yellow)}
.mode-firewall{background:var(--red2);border-color:#991b1b;color:var(--red)}
.layout{display:grid;grid-template-columns:220px 1fr 330px;flex:1;overflow:hidden}
.sidebar{background:var(--bg2);border-right:1px solid var(--border);overflow-y:auto;padding:12px 0}
.sidebar::-webkit-scrollbar{width:4px}.sidebar::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
.nav-section{padding:4px 12px;margin-bottom:2px}
.nav-section-label{font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:1.5px;color:var(--text3);padding:8px 0 4px}
.nav-item{display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:6px;cursor:pointer;color:var(--text2);font-size:12px;transition:all .15s;border:1px solid transparent;user-select:none}
.nav-item:hover{background:var(--bg3);color:var(--text)}.nav-item.active{background:#1a2e22;border-color:var(--green2);color:var(--green)}
.nav-icon{font-size:14px;width:18px;text-align:center}
.main{overflow:hidden;display:flex;flex-direction:column}
.panel{display:none;flex-direction:column;height:100%;overflow:hidden}.panel.active{display:flex}
.panel-header{padding:16px 20px 12px;border-bottom:1px solid var(--border);flex-shrink:0}
.panel-title{font-family:var(--font-head);font-size:16px;font-weight:700;color:#fff;display:flex;align-items:center;gap:8px}
.panel-subtitle{color:var(--text2);font-size:11px;margin-top:2px}
.panel-body{flex:1;overflow-y:auto;padding:16px 20px}
.panel-body::-webkit-scrollbar{width:4px}.panel-body::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
.card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;margin-bottom:12px;overflow:hidden}
.card-header{padding:10px 14px;background:var(--bg3);border-bottom:1px solid var(--border);font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.8px;color:var(--text2)}
.card-body{padding:14px}
.data-table{width:100%;border-collapse:collapse;font-size:12px}
.data-table th{text-align:left;padding:6px 10px;color:var(--text3);font-weight:600;font-size:10px;text-transform:uppercase;letter-spacing:.8px;border-bottom:1px solid var(--border)}
.data-table td{padding:8px 10px;border-bottom:1px solid var(--border);color:var(--text);vertical-align:middle}
.data-table tr:last-child td{border-bottom:none}.data-table tr:hover td{background:var(--bg3)}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.5px}
.badge-up{background:#1a2e22;color:var(--green);border:1px solid var(--green2)}
.badge-down{background:var(--red2);color:var(--red);border:1px solid #991b1b}
.badge-unknown{background:var(--bg3);color:var(--text3);border:1px solid var(--border)}
.badge-running{background:#1a2e22;color:var(--green)}.badge-dead{background:var(--red2);color:var(--red)}
.form-group{margin-bottom:12px}.form-row{display:flex;gap:10px}.form-row .form-group{flex:1}
label{display:block;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.8px;color:var(--text2);margin-bottom:5px}
.hint{font-size:10px;color:var(--text3);margin-top:3px}
input,select{width:100%;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);padding:7px 10px;font-family:var(--font-mono);font-size:12px;outline:none;transition:border-color .15s}
input:focus,select:focus{border-color:var(--cyan)}select option{background:var(--bg2)}
.btn{padding:8px 16px;border:none;border-radius:5px;cursor:pointer;font-family:var(--font-mono);font-size:12px;font-weight:600;transition:all .15s;display:inline-flex;align-items:center;gap:6px}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btn-primary{background:var(--cyan);color:#000}.btn-primary:hover:not(:disabled){background:#7dd3fc}
.btn-success{background:var(--green);color:#000}.btn-success:hover:not(:disabled){background:#6ee7b7}
.btn-danger{background:var(--red);color:#000}.btn-danger:hover:not(:disabled){background:#fca5a5}
.btn-ghost{background:transparent;border:1px solid var(--border);color:var(--text2)}
.btn-ghost:hover{border-color:var(--border2);color:var(--text);background:var(--bg3)}
.btn-sm{padding:5px 10px;font-size:11px}
.terminal{background:#111316;border:1px solid var(--border);border-radius:8px;font-family:var(--font-mono);font-size:12px;overflow:hidden;display:flex;flex-direction:column}
.terminal-bar{background:var(--bg3);border-bottom:1px solid var(--border);padding:8px 14px;display:flex;align-items:center;gap:8px}
.terminal-dots{display:flex;gap:5px}.terminal-dot{width:10px;height:10px;border-radius:50%}
.d1{background:#f87171}.d2{background:#fbbf24}.d3{background:#34d399}
.terminal-title{color:var(--text3);font-size:11px;margin-left:4px}
.terminal-output{padding:12px 14px;overflow-y:auto;flex:1;min-height:100px;max-height:300px;color:#a8b4c8;line-height:1.7;white-space:pre-wrap;word-break:break-all}
.terminal-output::-webkit-scrollbar{width:4px}.terminal-output::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
.t-ok{color:var(--green)}.t-warn{color:var(--yellow)}.t-error{color:var(--red)}.t-info{color:var(--cyan)}.t-cmd{color:var(--purple)}
.cmd-bar{background:var(--bg2);border-top:1px solid var(--border);padding:10px 20px;display:flex;gap:10px;align-items:center;flex-shrink:0}
.cmd-prompt{color:var(--green);font-size:13px;white-space:nowrap;min-width:90px}
.cmd-input{flex:1;background:var(--bg);border:1px solid var(--border);border-radius:5px;color:var(--text);padding:7px 12px;font-family:var(--font-mono);font-size:13px;outline:none}
.cmd-input:focus{border-color:var(--cyan)}
.cmd-run-btn{background:var(--cyan);color:#000;border:none;border-radius:5px;padding:7px 16px;font-family:var(--font-mono);font-size:12px;font-weight:700;cursor:pointer;transition:background .15s;white-space:nowrap}
.cmd-run-btn:hover{background:#7dd3fc}
.right-panel{background:var(--bg2);border-left:1px solid var(--border);display:flex;flex-direction:column;overflow:hidden}
.right-tabs{display:flex;border-bottom:1px solid var(--border);flex-shrink:0}
.right-tab{flex:1;padding:10px 8px;text-align:center;cursor:pointer;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;color:var(--text3);border-bottom:2px solid transparent;transition:all .15s;user-select:none}
.right-tab:hover{color:var(--text2)}.right-tab.active{color:var(--cyan);border-bottom-color:var(--cyan)}
.right-content{flex:1;overflow-y:auto;padding:10px 12px;display:none}
.right-content.active{display:block}
.right-content::-webkit-scrollbar{width:4px}.right-content::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
.log-entry{display:flex;gap:6px;padding:3px 0;border-bottom:1px solid var(--border);font-size:11px;line-height:1.5}
.log-entry:last-child{border-bottom:none}
.log-ts{color:var(--text3);white-space:nowrap;flex-shrink:0;font-size:10px}
.log-level{font-weight:700;white-space:nowrap;flex-shrink:0;min-width:38px;font-size:10px}
.log-msg{color:var(--text2);word-break:break-word}
.lv-OK{color:var(--green)}.lv-INFO{color:var(--cyan)}.lv-WARN{color:var(--yellow)}.lv-ERROR{color:var(--red)}.lv-CMD{color:var(--purple)}.lv-WEB{color:var(--orange)}
.overview-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-bottom:14px}
.metric-card{background:var(--bg3);border:1px solid var(--border);border-radius:8px;padding:14px}
.metric-label{font-size:9px;text-transform:uppercase;letter-spacing:1px;color:var(--text3);margin-bottom:4px}
.metric-value{font-family:var(--font-head);font-size:22px;font-weight:800;color:#fff}
.metric-sub{font-size:10px;color:var(--text3);margin-top:2px}
.section-label{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:1px;color:var(--text3);margin-bottom:10px;margin-top:18px;display:flex;align-items:center;gap:8px}
.section-label:first-child{margin-top:0}
.section-label::after{content:'';flex:1;height:1px;background:var(--border)}
.iface-row{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--border)}
.iface-row:last-child{border-bottom:none}
.iface-name{color:var(--cyan);font-weight:600;min-width:90px}
.iface-ips{color:var(--text2);font-size:11px;flex:1}
.iface-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.iface-dot.up{background:var(--green);box-shadow:0 0 5px var(--green)}.iface-dot.down{background:var(--red)}.iface-dot.unknown{background:var(--text3)}
.explain-box{background:var(--bg3);border:1px solid var(--border);border-left:3px solid var(--cyan);border-radius:6px;padding:10px 14px;margin-bottom:14px;font-size:11px;color:var(--text2);line-height:1.6}
.explain-box strong{color:var(--cyan)}
.empty{color:var(--text3);font-size:11px;padding:8px 0}
code{color:var(--orange);font-family:var(--font-mono)}
.mode-guard-banner{background:var(--yellow2);border:1px solid var(--yellow);border-radius:8px;padding:14px 18px;margin-bottom:16px;display:flex;align-items:center;gap:12px;font-size:12px;color:var(--yellow);line-height:1.5}
.mode-guard-banner .mgb-icon{font-size:20px;flex-shrink:0}
.mode-guard-banner .mgb-text strong{color:#fff;display:block;margin-bottom:4px}
.mode-guard-banner button{margin-left:auto;background:var(--yellow);color:#000;border:none;border-radius:5px;padding:7px 14px;font-family:var(--font-mono);font-size:11px;font-weight:700;cursor:pointer;white-space:nowrap;flex-shrink:0}
.mode-switcher{display:flex;gap:4px;background:var(--bg3);border:1px solid var(--border);border-radius:24px;padding:3px}
.mode-btn{background:transparent;border:none;border-radius:20px;padding:5px 14px;font-family:var(--font-mono);font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.8px;color:var(--text3);cursor:pointer;transition:all .2s;white-space:nowrap}
.mode-btn:hover{color:var(--text);background:var(--bg2)}
.mode-btn.active{color:#000;font-weight:800}
.mode-btn[data-mode="ncos"].active{background:var(--green)}
.mode-btn[data-mode="switch"].active,.mode-btn[data-mode="switch-mls"].active{background:var(--cyan)}
.mode-btn[data-mode="router"].active{background:var(--yellow)}
.mode-btn[data-mode="firewall"].active{background:var(--red)}
.mode-locked{opacity:.45;pointer-events:none;position:relative}
.mode-locked::after{content:"⚠ wrong mode";position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);background:var(--bg2);border:1px solid var(--border);border-radius:6px;padding:6px 10px;font-size:10px;color:var(--yellow);white-space:nowrap;z-index:10}
#toast{position:fixed;bottom:24px;right:24px;padding:12px 20px;border-radius:8px;font-size:13px;font-weight:600;z-index:9999;display:none;animation:toastIn .2s ease;max-width:360px}
@keyframes toastIn{from{transform:translateY(10px);opacity:0}to{transform:translateY(0);opacity:1}}
.toast-ok{background:var(--green);color:#000}.toast-error{background:var(--red);color:#000}.toast-warn{background:var(--yellow);color:#000}
.spin{display:inline-block;width:12px;height:12px;border:2px solid var(--border);border-top-color:var(--cyan);border-radius:50%;animation:spin .7s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.run-ind{display:none;align-items:center;gap:6px;color:var(--cyan);font-size:11px}.run-ind.show{display:flex}
.cheat-item{padding:4px 0;border-bottom:1px solid var(--border);font-size:11px;display:flex;gap:8px}
.cheat-item:last-child{border-bottom:none}
.cheat-cmd{color:var(--orange);min-width:180px;flex-shrink:0}.cheat-desc{color:var(--text3)}
</style>
</head>
<body>
<header>
  <div class="logo"><div class="logo-dot"></div>Net<span>CoreOS</span><small style="font-weight:400;font-size:11px;opacity:.55;margin-left:8px">0.1 BETA · by Silent Cell</small></div>
  <div class="mode-switcher" id="mode-switcher">
    <button class="mode-btn active" data-mode="ncos"     onclick="switchMode('ncos')">NCOS</button>
    <button class="mode-btn"        data-mode="switch"   onclick="switchMode('switch')">Switch</button>
    <button class="mode-btn"        data-mode="switch-mls" onclick="switchMode('switch-mls')">MLS</button>
    <button class="mode-btn"        data-mode="router"   onclick="switchMode('router')">Router</button>
    <button class="mode-btn"        data-mode="firewall" onclick="switchMode('firewall')">Firewall</button>
  </div>
  <div class="header-stats">
    <div class="stat-pill">⏱ <span class="val" id="hdr-uptime">—</span></div>
    <div class="stat-pill">CPU <span class="val" id="hdr-cpu">—</span>%</div>
    <div class="stat-pill">RAM <span class="val" id="hdr-mem">—</span>%</div>
    <div class="mode-badge mode-ncos" id="hdr-mode">ncos</div>
  </div>
</header>
<div class="layout">
  <nav class="sidebar">
    <div class="nav-section">
      <div class="nav-section-label">Overview</div>
      <div class="nav-item active" onclick="showPanel('dashboard',this)">📊 Dashboard</div>
      <div class="nav-item" onclick="showPanel('interfaces',this)">🔌 Interfaces</div>
      <div class="nav-item" onclick="showPanel('routing',this)">🗺 Routes</div>
    </div>
    <div class="nav-section">
      <div class="nav-section-label">Switch</div>
      <div class="nav-item" onclick="showPanel('vlans',this)">🏷 VLANs</div>
      <div class="nav-item" onclick="showPanel('lacp',this)">🔗 LACP / Bonds</div>
      <div class="nav-item" onclick="showPanel('vxlan',this)">🌐 VXLAN Tunnels</div>
    </div>
    <div class="nav-section">
      <div class="nav-section-label">Routing Protocols</div>
      <div class="nav-item" onclick="showPanel('ospf',this)">🔄 OSPF</div>
      <div class="nav-item" onclick="showPanel('bgp',this)">🌍 BGP</div>
      <div class="nav-item" onclick="showPanel('routepolicy',this)">📋 Route Policy</div>
      <div class="nav-item" onclick="showPanel('vrrp',this)">🔁 VRRP / HA</div>
      <div class="nav-item" onclick="showPanel('bfd',this)">⚡ BFD Fast Failover</div>
    </div>
    <div class="nav-section">
      <div class="nav-section-label">Security</div>
      <div class="nav-item" onclick="showPanel('firewall',this)">🛡 Firewall</div>
      <div class="nav-item" onclick="showPanel('acl',this)">🚦 ACL Rules</div>
    </div>
    <div class="nav-section">
      <div class="nav-section-label">Tools</div>
      <div class="nav-item" onclick="showPanel('tools',this)">🔧 Ping / Trace</div>
      <div class="nav-item" onclick="showPanel('monitor',this)">👁 IP-SLA Monitor</div>
      <div class="nav-item" onclick="showPanel('qos',this)">⚡ QoS</div>
    </div>
    <div class="nav-section">
      <div class="nav-section-label">Terminal</div>
      <div class="nav-item" onclick="showPanel('topology',this)">🕸 Topology Map</div>
      <div class="nav-item" onclick="showPanel('terminal',this)">💻 Command Line</div>
    </div>
  </nav>
  <div class="main">

    <!-- DASHBOARD -->
    <div class="panel active" id="panel-dashboard">
      <div class="panel-header"><div class="panel-title">📊 Dashboard</div><div class="panel-subtitle">Live overview — auto-refreshes every 5 seconds</div></div>
      <div class="panel-body">
        <div class="overview-grid">
          <div class="metric-card"><div class="metric-label">Mode</div><div class="metric-value" id="dash-mode" style="color:var(--green);font-size:16px">—</div><div class="metric-sub">Operational context</div></div>
          <div class="metric-card"><div class="metric-label">Interfaces</div><div class="metric-value" id="dash-ifaces" style="color:var(--cyan)">—</div><div class="metric-sub">Network interfaces</div></div>
          <div class="metric-card"><div class="metric-label">Routes</div><div class="metric-value" id="dash-routes" style="color:var(--yellow)">—</div><div class="metric-sub">Routing table entries</div></div>
          <div class="metric-card"><div class="metric-label">Log Events</div><div class="metric-value" id="dash-logs" style="color:var(--purple)">—</div><div class="metric-sub">Since startup</div></div>
        </div>
        <div class="section-label">Interface Status</div>
        <div class="card"><div class="card-body" id="dash-iface-list"><div class="empty">Loading…</div></div></div>
        <div class="section-label">Active Routes</div>
        <div class="card"><div class="card-body" id="dash-route-list"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- INTERFACES -->
    <div class="panel" id="panel-interfaces">
      <div class="panel-header"><div class="panel-title">🔌 Interfaces & Addresses</div><div class="panel-subtitle">View and configure network interfaces</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>Quick tip:</strong> Assign IPs with the form below, or type <code>ipaddr &lt;iface&gt; &lt;ip/prefix&gt;</code> in the command bar. Requires <strong>router</strong> or <strong>switch-mls</strong> mode.</div>
        <div class="section-label">Assign IP</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Interface</label><select id="ip-iface"></select></div>
            <div class="form-group"><label>IP / Prefix</label><input id="ip-addr" placeholder="192.168.1.1/24"/><div class="hint">/24 = 255.255.255.0</div></div>
          </div>
          <button class="btn btn-success" onclick="qc('ipaddr '+g('ip-iface')+' '+g('ip-addr'))">Assign IP</button>
        </div></div>
        <div class="section-label">All Interfaces</div>
        <div class="card"><div class="card-body" id="iface-table-body"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- ROUTING -->
    <div class="panel" id="panel-routing">
      <div class="panel-header"><div class="panel-title">🗺 Routing Table</div><div class="panel-subtitle">Control where packets go</div></div>
      <div class="panel-body">
        <div id="route-guard" class="mode-guard-banner" style="display:none"></div>
        <div class="explain-box"><strong>Routing:</strong> A route like <code>10.0.0.0/8 via 192.168.1.1</code> means "send 10.x.x.x traffic through 192.168.1.1". Requires <strong>router</strong> or <strong>switch-mls</strong> mode.</div>
        <div class="section-label">Add Route</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Destination</label><input id="rt-dest" placeholder="10.10.0.0/16"/></div>
            <div class="form-group"><label>Gateway (via)</label><input id="rt-gw" placeholder="192.168.1.1"/></div>
          </div>
          <button class="btn btn-success" onclick="qc('route '+g('rt-dest')+' '+g('rt-gw'))">Add Route</button>
        </div></div>
        <div class="section-label">Current Routes</div>
        <div class="card"><div class="card-body" id="route-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- VLANS -->
    <div class="panel" id="panel-vlans">
      <div class="panel-header"><div class="panel-title">🏷 VLAN Management</div><div class="panel-subtitle">Isolate network segments</div></div>
      <div class="panel-body">
        <div id="vlan-guard" class="mode-guard-banner" style="display:none"></div>
        <div class="explain-box"><strong>VLANs</strong> create isolated segments on the same switch. Requires <strong>switch</strong> or <strong>switch-mls</strong> mode.</div>
        <div class="section-label">Create / Delete VLAN</div>
        <div class="card"><div class="card-body">
          <div class="form-row"><div class="form-group"><label>VLAN ID (1–4094)</label><input id="vlan-id" type="number" min="1" max="4094" placeholder="10"/></div></div>
          <div style="display:flex;gap:8px">
            <button class="btn btn-success" onclick="qc('vlan create '+g('vlan-id'))">+ Create</button>
            <button class="btn btn-danger" onclick="qc('vlan delete '+g('vlan-id'))">Delete</button>
          </div>
        </div></div>
        <div class="section-label">Assign Port to VLAN</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Interface</label><select id="vlan-iface-sel"></select></div>
            <div class="form-group"><label>VLAN ID</label><input id="vlan-port-id" type="number" placeholder="10"/></div>
            <div class="form-group"><label>Mode</label><select id="vlan-port-mode"><option value="access">Access (untagged)</option><option value="trunk">Trunk (tagged)</option></select></div>
          </div>
          <button class="btn btn-primary" onclick="setPortVLAN()">Apply</button>
        </div></div>
        <div class="section-label">VLAN Table</div>
        <div class="card"><div class="card-body" id="vlan-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- LACP -->
    <div class="panel" id="panel-lacp">
      <div class="panel-header"><div class="panel-title">🔗 LACP / Bonding</div><div class="panel-subtitle">Combine links for speed + redundancy</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>LACP</strong> bundles multiple cables into one fast, redundant link. Command: <code>lacp create bond0 eth1 eth2</code></div>
        <div class="section-label">Create Bond</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Bond Name</label><input id="bond-name" placeholder="bond0"/></div>
            <div class="form-group"><label>Members (space-separated)</label><input id="bond-members" placeholder="eth1 eth2"/></div>
          </div>
          <button class="btn btn-success" onclick="qc('lacp create '+g('bond-name')+' '+g('bond-members'))">+ Create Bond</button>
        </div></div>
        <div class="section-label">Active Bonds</div>
        <div class="card"><div class="card-body" id="bond-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- VXLAN -->
    <div class="panel" id="panel-vxlan">
      <div class="panel-header"><div class="panel-title">🌐 VXLAN Tunnels</div><div class="panel-subtitle">Layer 2 over Layer 3 — bridge sites across the internet</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>VXLAN</strong> creates a virtual cable between two locations over the internet. Command: <code>vxlan create &lt;vni&gt; &lt;local_ip&gt; &lt;remote_ip&gt;</code></div>
        <div class="section-label">Create Tunnel</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>VNI (Tunnel ID)</label><input id="vx-vni" type="number" placeholder="100"/></div>
            <div class="form-group"><label>Local WAN IP</label><input id="vx-local" placeholder="1.2.3.4"/></div>
            <div class="form-group"><label>Remote WAN IP</label><input id="vx-remote" placeholder="5.6.7.8"/></div>
          </div>
          <button class="btn btn-success" onclick="qc('vxlan create '+g('vx-vni')+' '+g('vx-local')+' '+g('vx-remote'))">+ Create Tunnel</button>
        </div></div>
        <div class="section-label">Active Tunnels</div>
        <div class="card"><div class="card-body" id="vxlan-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- FIREWALL -->
    <div class="panel" id="panel-firewall">
      <div class="panel-header"><div class="panel-title">🛡 Firewall</div><div class="panel-subtitle">Control what traffic is allowed or blocked</div></div>
      <div class="panel-body">
        <div id="fw-guard" class="mode-guard-banner" style="display:none"></div>
        <div class="explain-box"><strong>Setup order:</strong> (1) <strong>Initialize</strong> chains first, (2) then add rules. Commands: <code>firewall init</code> → <code>firewall allow wan</code> → <code>acl deny…</code></div>
        <div class="section-label">Setup</div>
        <div class="card"><div class="card-body" style="display:flex;gap:10px;flex-wrap:wrap">
          <button class="btn btn-primary" onclick="qc('firewall init')">🔧 Initialize Firewall</button>
          <button class="btn btn-success" onclick="qc('firewall allow wan')">🌍 Enable NAT / WAN</button>
        </div></div>
        <div class="section-label">Current Rules</div>
        <div class="card"><div class="card-body" id="fw-rules"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- ACL -->
    <div class="panel" id="panel-acl">
      <div class="panel-header"><div class="panel-title">🚦 ACL Rules</div><div class="panel-subtitle">Allow or deny traffic between interfaces</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>ACL = Access Control List.</strong> Define who can talk to who. Requires firewall to be initialized first.</div>
        <div class="section-label">Block Traffic</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>From Interface</label><input id="acl-deny-src" placeholder="br0.10"/></div>
            <div class="form-group"><label>To Interface</label><input id="acl-deny-dst" placeholder="br0.20"/></div>
          </div>
          <button class="btn btn-danger" onclick="qc('acl deny '+g('acl-deny-src')+' '+g('acl-deny-dst'))">🚫 Block</button>
        </div></div>
        <div class="section-label">Allow Specific Port</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>From</label><input id="acl-allow-src" placeholder="br0.10"/></div>
            <div class="form-group"><label>To</label><input id="acl-allow-dst" placeholder="br0.20"/></div>
            <div class="form-group"><label>Protocol</label><select id="acl-allow-proto"><option>tcp</option><option>udp</option><option>icmp</option></select></div>
            <div class="form-group"><label>Port</label><input id="acl-allow-port" type="number" placeholder="80"/><div class="hint">80=HTTP 443=HTTPS 22=SSH</div></div>
          </div>
          <button class="btn btn-success" onclick="qc('acl allow '+g('acl-allow-src')+' '+g('acl-allow-dst')+' '+g('acl-allow-proto')+' '+g('acl-allow-port'))">✔ Allow</button>
        </div></div>
      </div>
    </div>

    <!-- TOOLS -->
    <div class="panel" id="panel-tools">
      <div class="panel-header"><div class="panel-title">🔧 Network Tools</div><div class="panel-subtitle">Test connectivity and measure performance</div></div>
      <div class="panel-body">
        <div class="section-label">Ping</div>
        <div class="card"><div class="card-body">
          <div class="explain-box" style="margin-bottom:10px"><strong>Ping</strong> checks if a host is reachable. No reply = connection problem.</div>
          <div class="form-row">
            <div class="form-group"><label>Target IP</label><input id="ping-target" placeholder="8.8.8.8"/></div>
            <div class="form-group"><label>Count</label><input id="ping-count" type="number" value="4" min="1" max="20"/></div>
          </div>
          <button class="btn btn-primary" onclick="toolCmd('ping '+g('ping-target')+' '+g('ping-count'))">Ping</button>
        </div></div>
        <div class="section-label">Traceroute</div>
        <div class="card"><div class="card-body">
          <div class="explain-box" style="margin-bottom:10px"><strong>Traceroute</strong> shows every router your packet passes through.</div>
          <div class="form-group"><label>Target IP</label><input id="trace-target" placeholder="1.1.1.1"/></div>
          <button class="btn btn-primary" onclick="toolCmd('traceroute '+g('trace-target'))">Trace</button>
        </div></div>
        <div class="section-label">Bandwidth</div>
        <div class="card"><div class="card-body">
          <div class="form-row"><div class="form-group"><label>Interface</label><select id="bw-iface"></select></div></div>
          <button class="btn btn-primary" onclick="toolCmd('bandwidth '+g('bw-iface'))">Measure (2s)</button>
        </div></div>
        <div class="section-label">Output</div>
        <div class="terminal">
          <div class="terminal-bar"><div class="terminal-dots"><div class="terminal-dot d1"></div><div class="terminal-dot d2"></div><div class="terminal-dot d3"></div></div><span class="terminal-title">tools output</span></div>
          <div class="terminal-output" id="tools-output">Run a tool above to see results.</div>
        </div>
      </div>
    </div>

    <!-- MONITOR -->
    <div class="panel" id="panel-monitor">
      <div class="panel-header"><div class="panel-title">👁 IP-SLA Monitor</div><div class="panel-subtitle">Watch if hosts stay reachable</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>IP-SLA</strong> pings a target continuously in the background. If it fails too many times, it fires an action. Command: <code>monitor add &lt;ip&gt; [interval] [threshold]</code></div>
        <div class="section-label">Add Monitor</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Target IP</label><input id="mon-ip" placeholder="8.8.8.8"/></div>
            <div class="form-group"><label>Interval (s)</label><input id="mon-interval" type="number" value="5"/></div>
            <div class="form-group"><label>Threshold</label><input id="mon-threshold" type="number" value="3"/></div>
          </div>
          <button class="btn btn-success" onclick="qc('monitor add '+g('mon-ip')+' '+g('mon-interval')+' '+g('mon-threshold'))">+ Add Monitor</button>
        </div></div>
        <div class="section-label">Active Monitors</div>
        <div class="card"><div class="card-body" id="monitor-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- QoS -->
    <div class="panel" id="panel-qos">
      <div class="panel-header"><div class="panel-title">⚡ QoS — Traffic Shaping</div><div class="panel-subtitle">Prioritize important traffic</div></div>
      <div class="panel-body">
        <div class="explain-box"><strong>QoS workflow:</strong> <code>qos policy myPolicy 100</code> → <code>qos class eth0 myPolicy 10 50 80 1</code> → <code>qos apply eth0 myPolicy</code></div>
        <div class="section-label">Create Policy</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Policy Name</label><input id="qos-name" placeholder="myPolicy"/></div>
            <div class="form-group"><label>Total Rate (mbit)</label><input id="qos-rate" type="number" placeholder="100"/></div>
          </div>
          <button class="btn btn-success" onclick="qc('qos policy '+g('qos-name')+' '+g('qos-rate'))">+ Create Policy</button>
        </div></div>
        <div class="section-label">Show on Interface</div>
        <div class="card"><div class="card-body">
          <div class="form-row"><div class="form-group"><label>Interface</label><select id="qos-iface"></select></div></div>
          <button class="btn btn-primary" onclick="toolCmd('qos show '+g('qos-iface'), 'qos-output')">Show</button>
        </div></div>
        <div class="section-label">Output</div>
        <div class="terminal">
          <div class="terminal-bar"><div class="terminal-dots"><div class="terminal-dot d1"></div><div class="terminal-dot d2"></div><div class="terminal-dot d3"></div></div><span class="terminal-title">qos output</span></div>
          <div class="terminal-output" id="qos-output">Run a command to see output.</div>
        </div>
      </div>
    </div>

    <!-- ══════════════════════════════════════════════════════
         OSPF PANEL
    ═══════════════════════════════════════════════════════ -->
    <div class="panel" id="panel-ospf">
      <div class="panel-header">
        <div class="panel-title">🔄 OSPF — Open Shortest Path First</div>
        <div class="panel-subtitle">Link-state interior routing — automatic route exchange between routers</div>
      </div>
      <div class="panel-body">
        <div id="ospf-guard" class="mode-guard-banner" style="display:none"></div>
        <div id="frr-not-installed" class="explain-box" style="display:none;border-left-color:var(--red)">
          <strong>FRR not installed.</strong> Install with: <code>apt install frr frr-pythontools</code>
          then run <code>frr status</code> to verify.
        </div>

        <!-- FRR Status Bar -->
        <div id="frr-status-bar" style="display:flex;align-items:center;gap:12px;padding:10px 14px;background:var(--bg3);border:1px solid var(--border);border-radius:8px;margin-bottom:14px;font-size:12px">
          <div id="frr-dot" style="width:10px;height:10px;border-radius:50%;background:var(--text3)"></div>
          <span id="frr-status-text" style="color:var(--text2)">Checking FRR…</span>
          <button class="btn btn-ghost btn-sm" style="margin-left:auto" onclick="qc('frr restart')">Restart FRR</button>
          <button class="btn btn-ghost btn-sm" onclick="qc('frr status')">Status</button>
        </div>

        <!-- Quick Setup -->
        <div class="section-label">Quick Setup</div>
        <div class="card"><div class="card-body">
          <div class="explain-box" style="margin-bottom:12px"><strong>Setup order:</strong>
            (1) Enable OSPF → (2) Set router-id → (3) Add network statements → (4) Tune interfaces if needed
          </div>
          <div class="form-row">
            <div class="form-group">
              <label>Router ID (usually your loopback IP)</label>
              <input id="ospf-rid" placeholder="1.1.1.1"/>
            </div>
            <div class="form-group">
              <label>Network prefix to advertise</label>
              <input id="ospf-net" placeholder="10.0.0.0/24"/>
            </div>
            <div class="form-group">
              <label>Area</label>
              <input id="ospf-area" placeholder="0" value="0"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-success" onclick="ospfEnable()">▶ Enable OSPF</button>
            <button class="btn btn-primary" onclick="qc('ospf router-id '+g('ospf-rid'))">Set Router-ID</button>
            <button class="btn btn-primary" onclick="qc('ospf network '+g('ospf-net')+' area '+g('ospf-area'))">Advertise Network</button>
            <button class="btn btn-danger"  onclick="qc('ospf disable')">■ Disable</button>
          </div>
        </div></div>

        <!-- Interface Tuning -->
        <div class="section-label">Interface Tuning</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group"><label>Interface</label><select id="ospf-iface-sel"></select></div>
            <div class="form-group"><label>Cost (1–65535, lower = preferred)</label><input id="ospf-cost" type="number" placeholder="10" min="1" max="65535"/></div>
            <div class="form-group"><label>Hello Interval (secs)</label><input id="ospf-hello" type="number" placeholder="10" min="1"/></div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-primary" onclick="qc('ospf cost '+g('ospf-iface-sel')+' '+g('ospf-cost'))">Set Cost</button>
            <button class="btn btn-primary" onclick="qc('ospf hello '+g('ospf-iface-sel')+' '+g('ospf-hello'))">Set Hello</button>
            <button class="btn btn-ghost"   onclick="qc('ospf passive '+g('ospf-iface-sel'))">Set Passive</button>
          </div>
        </div></div>

        <!-- Redistribution -->
        <div class="section-label">Route Redistribution</div>
        <div class="card"><div class="card-body">
          <div class="explain-box">Redistribution injects routes from other sources into OSPF so all routers learn them.</div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-ghost btn-sm" onclick="qc('ospf redistribute connected')">+ Connected</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('ospf redistribute static')">+ Static</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('ospf redistribute bgp')">+ BGP</button>
          </div>
        </div></div>

        <!-- Neighbor Table -->
        <div class="section-label">OSPF Neighbors <button class="btn btn-ghost btn-sm" style="margin-left:8px" onclick="loadOSPF()">↻ Refresh</button></div>
        <div class="card"><div class="card-body" id="ospf-neighbor-table"><div class="empty">Loading…</div></div></div>

        <!-- OSPF Routes -->
        <div class="section-label">OSPF Route Table</div>
        <div class="card"><div class="card-body" id="ospf-route-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- ══════════════════════════════════════════════════════
         BGP PANEL
    ═══════════════════════════════════════════════════════ -->
    <div class="panel" id="panel-bgp">
      <div class="panel-header">
        <div class="panel-title">🌍 BGP — Border Gateway Protocol</div>
        <div class="panel-subtitle">The routing protocol of the internet — exchange routes between autonomous systems</div>
      </div>
      <div class="panel-body">
        <div id="bgp-guard" class="mode-guard-banner" style="display:none"></div>

        <!-- AS Setup -->
        <div class="section-label">Autonomous System Setup</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>Local AS Number</label>
              <input id="bgp-asn" type="number" placeholder="65001" min="1" max="4294967295"/>
              <div class="hint">Private AS: 64512–65534 (eBGP) or 4200000000–4294967294 (32-bit)</div>
            </div>
            <div class="form-group">
              <label>BGP Router-ID</label>
              <input id="bgp-rid" placeholder="1.1.1.1"/>
              <div class="hint">Usually your loopback or WAN IP</div>
            </div>
          </div>
          <div style="display:flex;gap:8px">
            <button class="btn btn-success" onclick="bgpEnable()">▶ Configure AS</button>
            <button class="btn btn-primary" onclick="qc('bgp router-id '+g('bgp-rid'))">Set Router-ID</button>
            <button class="btn btn-danger"  onclick="qc('bgp disable')">■ Disable BGP</button>
          </div>
        </div></div>

        <!-- Add Neighbor -->
        <div class="section-label">Add BGP Neighbor (Peer)</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>Neighbor IP</label>
              <input id="bgp-nbr-ip" placeholder="203.0.113.1"/>
            </div>
            <div class="form-group">
              <label>Remote AS</label>
              <input id="bgp-nbr-as" type="number" placeholder="65002"/>
              <div class="hint">Same AS = iBGP, different AS = eBGP</div>
            </div>
            <div class="form-group">
              <label>Description (optional)</label>
              <input id="bgp-nbr-desc" placeholder="Upstream provider"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-success" onclick="bgpAddNeighbor()">+ Add Neighbor</button>
            <button class="btn btn-ghost btn-sm" onclick="bgpShutdownNeighbor()">Shutdown Neighbor</button>
            <button class="btn btn-ghost btn-sm" onclick="bgpActivateNeighbor()">Activate Neighbor</button>
            <button class="btn btn-danger btn-sm" onclick="bgpRemoveNeighbor()">Remove Neighbor</button>
          </div>
        </div></div>

        <!-- Advertise Networks -->
        <div class="section-label">Advertise Networks</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>Prefix to advertise</label>
              <input id="bgp-net" placeholder="192.0.2.0/24"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-primary" onclick="qc('bgp network '+g('bgp-net'))">Advertise Prefix</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('bgp redistribute connected')">+ Connected</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('bgp redistribute ospf')">+ OSPF</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('bgp redistribute static')">+ Static</button>
          </div>
        </div></div>

        <!-- BGP Summary -->
        <div class="section-label">BGP Peer Summary <button class="btn btn-ghost btn-sm" style="margin-left:8px" onclick="loadBGP()">↻ Refresh</button></div>
        <div id="bgp-summary-bar" style="display:flex;gap:20px;padding:10px 0;font-size:12px;flex-wrap:wrap;margin-bottom:8px">
          <span>AS: <strong id="bgp-asn-display" style="color:var(--cyan)">—</strong></span>
          <span>Router-ID: <strong id="bgp-rid-display" style="color:var(--cyan)">—</strong></span>
          <span>Peers: <strong id="bgp-peer-count" style="color:var(--green)">—</strong></span>
        </div>
        <div class="card"><div class="card-body" id="bgp-peer-table"><div class="empty">Loading…</div></div></div>

        <!-- BGP Routes -->
        <div class="section-label">BGP Route Table (first 100)</div>
        <div class="card"><div class="card-body" id="bgp-route-table"><div class="empty">Loading…</div></div></div>
      </div>
    </div>

    <!-- ══════════════════════════════════════════════════════
         ROUTE POLICY PANEL (Route Maps + Prefix Lists + RPKI)
    ═══════════════════════════════════════════════════════ -->
    <div class="panel" id="panel-routepolicy">
      <div class="panel-header">
        <div class="panel-title">📋 Route Policy</div>
        <div class="panel-subtitle">Prefix lists, route maps, and RPKI — filter and shape what routes you accept and advertise</div>
      </div>
      <div class="panel-body">
        <div id="rp-guard" class="mode-guard-banner" style="display:none"></div>

        <!-- Prefix Lists -->
        <div class="section-label">Prefix Lists — filter by IP prefix</div>
        <div class="card"><div class="card-body">
          <div class="explain-box">A prefix-list named <code>DENY-DEFAULT</code> with <code>deny 0.0.0.0/0</code> applied inbound on a BGP neighbor will stop that peer from sending you a default route.</div>
          <div class="form-row">
            <div class="form-group"><label>List Name</label><input id="pl-name" placeholder="MY-PREFIXES"/></div>
            <div class="form-group"><label>Action</label>
              <select id="pl-action"><option value="permit">permit</option><option value="deny">deny</option></select>
            </div>
            <div class="form-group"><label>Prefix</label><input id="pl-prefix" placeholder="192.168.0.0/16"/></div>
            <div class="form-group"><label>le (max len, optional)</label><input id="pl-le" placeholder="24"/></div>
          </div>
          <div style="display:flex;gap:8px">
            <button class="btn btn-success" onclick="createPrefixList()">+ Create Entry</button>
            <button class="btn btn-danger btn-sm" onclick="qc('prefix-list delete '+g('pl-name'))">Delete List</button>
          </div>
        </div></div>
        <div class="section-label">Active Prefix Lists</div>
        <div class="card"><div class="card-body" id="pl-table"><div class="empty">Loading…</div></div></div>

        <!-- Route Maps -->
        <div class="section-label">Route Maps — match and set BGP attributes</div>
        <div class="card"><div class="card-body">
          <div class="explain-box">Route maps are the most powerful BGP tool. They let you match incoming/outgoing routes and change attributes like local-preference, MED, communities, and AS-path.</div>
          <div class="form-row">
            <div class="form-group"><label>Map Name</label><input id="rm-name" placeholder="SET-LOCAL-PREF"/></div>
            <div class="form-group"><label>Action</label>
              <select id="rm-action"><option value="permit">permit</option><option value="deny">deny</option></select>
            </div>
            <div class="form-group"><label>Sequence</label><input id="rm-seq" type="number" value="10" min="1" max="65535"/></div>
          </div>
          <div class="form-row">
            <div class="form-group"><label>Match: prefix-list name (optional)</label><input id="rm-match-pl" placeholder="MY-PREFIXES"/></div>
            <div class="form-group"><label>Set: local-preference</label><input id="rm-set-lp" type="number" placeholder="200"/></div>
            <div class="form-group"><label>Set: community</label><input id="rm-set-comm" placeholder="65001:100"/></div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-success" onclick="createRouteMap()">+ Create Map</button>
            <button class="btn btn-ghost btn-sm" onclick="applyRouteMapMatch()">Apply Match</button>
            <button class="btn btn-ghost btn-sm" onclick="applyRouteMapSet()">Apply Set</button>
            <button class="btn btn-danger btn-sm" onclick="qc('routemap delete '+g('rm-name'))">Delete Map</button>
          </div>
        </div></div>
        <div class="section-label">Active Route Maps</div>
        <div class="card"><div class="card-body" id="rm-table"><div class="empty">Loading…</div></div></div>

        <!-- RPKI -->
        <div class="section-label">RPKI — BGP Route Origin Validation</div>
        <div class="card"><div class="card-body">
          <div class="explain-box"><strong>RPKI</strong> validates that a BGP prefix is being announced by its legitimate owner using cryptographic certificates stored in ARIN/RIPE/APNIC.
          It stops BGP hijacks (like the famous Pakistan Telecom / YouTube incident).</div>
          <div class="form-row">
            <div class="form-group">
              <label>RTR Validator IP</label>
              <input id="rpki-ip" placeholder="192.0.2.1"/>
              <div class="hint">Cloudflare: use rtr.rpki.cloudflare.com | or run your own with Routinator/rpki-client</div>
            </div>
            <div class="form-group">
              <label>Port (default 8282)</label>
              <input id="rpki-port" value="8282" type="number"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-success" onclick="qc('rpki enable '+g('rpki-ip')+' '+g('rpki-port'))">▶ Enable RPKI</button>
            <button class="btn btn-primary" onclick="qc('rpki enforce')">🛡 Create Enforcement Map</button>
            <button class="btn btn-danger"  onclick="qc('rpki disable')">■ Disable</button>
            <button class="btn btn-ghost btn-sm" onclick="qc('show rpki')">Show Status</button>
          </div>
        </div></div>
      </div>
    </div>

    <!-- ══════════════════════════════════════════════════════
         VRRP / HA PANEL
    ═══════════════════════════════════════════════════════ -->
    <div class="panel" id="panel-vrrp">
      <div class="panel-header">
        <div class="panel-title">🔁 VRRP — Virtual Router Redundancy</div>
        <div class="panel-subtitle">High availability failover — two routers share one virtual IP, failover in &lt;1 second</div>
      </div>
      <div class="panel-body">
        <div id="vrrp-guard" class="mode-guard-banner" style="display:none"></div>
        <div class="explain-box">
          <strong>How VRRP works:</strong> Two machines share a Virtual IP (VIP). The MASTER holds the VIP.
          If the MASTER dies, the BACKUP takes over in &lt;1 second. Your clients always use the VIP — they never need to change their gateway.
          <br><br>Set the MASTER with <strong>priority ≥ 100</strong> (default 100). BACKUP should be lower (e.g. 90).
          Run this command on <em>both</em> machines with the same VRID and VIP.
        </div>

        <!-- Create VRRP -->
        <div class="section-label">Create VRRP Group</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>VRID (1–255, same on both machines)</label>
              <input id="vrrp-vrid" type="number" placeholder="1" min="1" max="255"/>
            </div>
            <div class="form-group">
              <label>Interface</label>
              <select id="vrrp-iface"></select>
            </div>
            <div class="form-group">
              <label>Virtual IP (VIP)</label>
              <input id="vrrp-vip" placeholder="192.168.1.100"/>
            </div>
            <div class="form-group">
              <label>Priority (100=MASTER, 90=BACKUP)</label>
              <input id="vrrp-prio" type="number" value="100" min="1" max="254"/>
            </div>
          </div>
          <div style="display:flex;gap:8px">
            <button class="btn btn-success" onclick="createVRRP()">+ Create VRRP Group</button>
            <button class="btn btn-danger btn-sm" onclick="qc('vrrp remove '+g('vrrp-vrid'))">Remove</button>
          </div>
        </div></div>

        <!-- Active instances -->
        <div class="section-label">Active VRRP Groups <button class="btn btn-ghost btn-sm" style="margin-left:8px" onclick="loadVRRP()">↻ Refresh</button></div>
        <div class="card"><div class="card-body" id="vrrp-table"><div class="empty">Loading…</div></div></div>

        <!-- Docs box -->
        <div class="section-label">Production Setup Checklist</div>
        <div class="card"><div class="card-body" style="font-size:12px;color:var(--text2);line-height:1.8">
          <div>✅ <strong>Machine A (MASTER):</strong> <code>vrrp create 1 eth0 192.168.1.100 priority 110</code></div>
          <div>✅ <strong>Machine B (BACKUP):</strong> <code>vrrp create 1 eth0 192.168.1.100 priority 90</code></div>
          <div>✅ Both machines must have <strong>keepalived installed</strong>: <code>apt install keepalived</code></div>
          <div>✅ Both machines need a <strong>real IP on the same subnet</strong> as the VIP</div>
          <div>✅ Test failover: <code>systemctl stop keepalived</code> on MASTER → BACKUP takes VIP within 3s</div>
          <div style="margin-top:8px;color:var(--text3)">Log: <code>/var/log/netcoreos/vrrp.log</code></div>
        </div></div>
      </div>
    </div>

    <!-- BFD PANEL -->
    <div class="panel" id="panel-bfd">
      <div class="panel-header">
        <div class="panel-title">⚡ BFD — Bidirectional Forwarding Detection</div>
        <div class="panel-subtitle">Sub-second link failure detection — makes OSPF and BGP react in milliseconds, not seconds</div>
      </div>
      <div class="panel-body">
        <div id="bfd-guard" class="mode-guard-banner" style="display:none"></div>
        <div class="explain-box">
          <strong>BFD without it:</strong> OSPF detects failures in ~40 seconds (4 × hello interval). BGP detects in 90–180 seconds.<br>
          <strong>BFD with it:</strong> Failures detected in 300ms–1s. Traffic reroutes almost instantly.
          BFD runs as a lightweight UDP heartbeat between routers and signals OSPF/BGP to converge immediately.
        </div>

        <!-- Enable + add peer -->
        <div class="section-label">Enable BFD</div>
        <div class="card"><div class="card-body">
          <button class="btn btn-success" onclick="qc('bfd enable');setTimeout(loadBFD,1500)">▶ Enable BFD Daemon</button>
          <div class="explain-box" style="margin-top:10px;margin-bottom:0">Must be enabled before adding peers or binding to OSPF/BGP interfaces.</div>
        </div></div>

        <!-- Add peer -->
        <div class="section-label">Add BFD Peer</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>Peer IP address</label>
              <input id="bfd-peer-ip" placeholder="10.0.0.2"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-primary" onclick="qc('bfd peer '+g('bfd-peer-ip'));setTimeout(loadBFD,1500)">+ Add Peer</button>
            <button class="btn btn-danger btn-sm" onclick="qc('bfd remove '+g('bfd-peer-ip'));setTimeout(loadBFD,1500)">Remove</button>
          </div>
        </div></div>

        <!-- Bind to protocol -->
        <div class="section-label">Bind BFD to OSPF / BGP</div>
        <div class="card"><div class="card-body">
          <div class="form-row">
            <div class="form-group">
              <label>Interface (for OSPF binding)</label>
              <select id="bfd-iface-sel"></select>
            </div>
            <div class="form-group">
              <label>BGP neighbor IP</label>
              <input id="bfd-bgp-peer" placeholder="203.0.113.1"/>
            </div>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap">
            <button class="btn btn-primary" onclick="qc('bfd ospf '+g('bfd-iface-sel'))">⚡ Enable on OSPF Interface</button>
            <button class="btn btn-primary" onclick="qc('bfd bgp '+g('bfd-bgp-peer'))">⚡ Enable on BGP Neighbor</button>
          </div>
        </div></div>

        <!-- BFD Peer table -->
        <div class="section-label">BFD Peers <button class="btn btn-ghost btn-sm" style="margin-left:8px" onclick="loadBFD()">↻ Refresh</button></div>
        <div class="card"><div class="card-body" id="bfd-peer-table"><div class="empty">Loading…</div></div></div>

        <!-- Checklist -->
        <div class="section-label">Production Setup</div>
        <div class="card"><div class="card-body" style="font-size:12px;color:var(--text2);line-height:1.8">
          <div>✅ <code>bfd enable</code> — start the BFD daemon</div>
          <div>✅ <code>ospf enable</code> then <code>bfd ospf &lt;iface&gt;</code> — bind to OSPF</div>
          <div>✅ <code>bgp as &lt;ASN&gt;</code> then <code>bfd bgp &lt;peer&gt;</code> — bind to BGP neighbor</div>
          <div>✅ Both ends must run BFD for detection to work</div>
          <div style="margin-top:8px;color:var(--text3)">BFD defaults: TX/RX 300ms, multiplier 3 (= 900ms detection time)</div>
        </div></div>
      </div>
    </div>

    <!-- TERMINAL -->
    <div class="panel" id="panel-terminal">
      <div class="panel-header"><div class="panel-title">💻 Command Terminal</div><div class="panel-subtitle">Every NetCoreOS command works here — exact same engine as the CLI</div></div>
      <div class="panel-body" style="display:flex;flex-direction:column;gap:12px">
        <div class="explain-box">Type any command and press Enter. Mode changes (<code>switch</code>, <code>router</code>, etc.) persist. Use ↑/↓ arrows for history.</div>
        <div class="section-label">Command Cheat Sheet</div>
        <div class="card"><div class="card-body" style="columns:2;gap:20px">
          <div class="cheat-item"><span class="cheat-cmd">switch</span><span class="cheat-desc">Enter L2 switch mode</span></div>
          <div class="cheat-item"><span class="cheat-cmd">switch-mls</span><span class="cheat-desc">Enter L3 switch mode</span></div>
          <div class="cheat-item"><span class="cheat-cmd">router</span><span class="cheat-desc">Enter router mode</span></div>
          <div class="cheat-item"><span class="cheat-cmd">firewall</span><span class="cheat-desc">Enter firewall mode</span></div>
          <div class="cheat-item"><span class="cheat-cmd">back</span><span class="cheat-desc">Return to ncos mode</span></div>
          <div class="cheat-item"><span class="cheat-cmd">status</span><span class="cheat-desc">Full system status</span></div>
          <div class="cheat-item"><span class="cheat-cmd">show interfaces</span><span class="cheat-desc">List all interfaces</span></div>
          <div class="cheat-item"><span class="cheat-cmd">show ip route</span><span class="cheat-desc">Routing table</span></div>
          <div class="cheat-item"><span class="cheat-cmd">show vlan</span><span class="cheat-desc">VLAN table</span></div>
          <div class="cheat-item"><span class="cheat-cmd">show firewall</span><span class="cheat-desc">Firewall rules</span></div>
          <div class="cheat-item"><span class="cheat-cmd">vlan create 10</span><span class="cheat-desc">Create VLAN 10</span></div>
          <div class="cheat-item"><span class="cheat-cmd">access eth1 10</span><span class="cheat-desc">Port to VLAN 10</span></div>
          <div class="cheat-item"><span class="cheat-cmd">trunk eth2 10,20</span><span class="cheat-desc">Trunk port</span></div>
          <div class="cheat-item"><span class="cheat-cmd">ipaddr eth0 10.0.0.1/24</span><span class="cheat-desc">Assign IP</span></div>
          <div class="cheat-item"><span class="cheat-cmd">route 0.0.0.0/0 10.0.0.1</span><span class="cheat-desc">Default route</span></div>
          <div class="cheat-item"><span class="cheat-cmd">ping 8.8.8.8 4</span><span class="cheat-desc">Ping 4 times</span></div>
          <div class="cheat-item"><span class="cheat-cmd">firewall init</span><span class="cheat-desc">Init firewall</span></div>
          <div class="cheat-item"><span class="cheat-cmd">firewall allow wan</span><span class="cheat-desc">Enable NAT</span></div>
          <div class="cheat-item"><span class="cheat-cmd">acl deny br0.10 br0.20</span><span class="cheat-desc">Block inter-VLAN</span></div>
          <div class="cheat-item"><span class="cheat-cmd">lacp create bond0 eth1 eth2</span><span class="cheat-desc">Create bond</span></div>
          <div class="cheat-item"><span class="cheat-cmd">vxlan create 100 1.2.3.4 5.6.7.8</span><span class="cheat-desc">VXLAN tunnel</span></div>
          <div class="cheat-item"><span class="cheat-cmd">monitor add 8.8.8.8 5 3</span><span class="cheat-desc">Watch host</span></div>
          <div class="cheat-item"><span class="cheat-cmd">arp</span><span class="cheat-desc">ARP table</span></div>
          <div class="cheat-item"><span class="cheat-cmd">netstat</span><span class="cheat-desc">Open connections</span></div>
          <div class="cheat-item"><span class="cheat-cmd">bandwidth eth0</span><span class="cheat-desc">Measure speed</span></div>
          <div class="cheat-item"><span class="cheat-cmd">help</span><span class="cheat-desc">All commands</span></div>
        </div></div>
        <div class="terminal" style="flex:1;min-height:180px">
          <div class="terminal-bar">
            <div class="terminal-dots"><div class="terminal-dot d1"></div><div class="terminal-dot d2"></div><div class="terminal-dot d3"></div></div>
            <span class="terminal-title" id="term-title">netcoreos — ncos mode</span>
            <div class="run-ind" id="term-running"><div class="spin"></div> running…</div>
            <button class="btn btn-ghost btn-sm" style="margin-left:auto" onclick="clearTerminal()">Clear</button>
          </div>
          <div class="terminal-output" id="term-output">Welcome to NetCoreOS Web Terminal.
Every command runs through the real NetCoreOS engine.
Type a command in the bar below and press Enter.
</div>
        </div>
      </div>
    </div>


    <!-- TOPOLOGY MAP -->
    <div class="panel" id="panel-topology">
      <div class="panel-header">
        <div class="panel-title">🕸 Network Topology Map</div>
        <div class="panel-subtitle">Live visual diagram of your network — interfaces, VLANs, bonds, tunnels, routes</div>
      </div>
      <div class="panel-body" style="padding:0;display:flex;flex-direction:column;height:100%">
        <!-- toolbar -->
        <div style="display:flex;align-items:center;gap:10px;padding:10px 16px;background:var(--bg2);border-bottom:1px solid var(--border);flex-shrink:0">
          <button class="btn btn-ghost btn-sm" onclick="topoZoomIn()">＋ Zoom In</button>
          <button class="btn btn-ghost btn-sm" onclick="topoZoomOut()">－ Zoom Out</button>
          <button class="btn btn-ghost btn-sm" onclick="topoFit()">⊡ Fit All</button>
          <button class="btn btn-ghost btn-sm" onclick="topoReset()">↺ Reset</button>
          <button class="btn btn-primary btn-sm" onclick="loadTopology()">⟳ Refresh</button>
          <div style="margin-left:auto;display:flex;gap:12px;font-size:11px;color:var(--text3)">
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--cyan);margin-right:4px"></span>Physical</span>
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--green);margin-right:4px"></span>Bridge</span>
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--yellow);margin-right:4px"></span>VLAN</span>
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--purple);margin-right:4px"></span>Bond</span>
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--orange);margin-right:4px"></span>VXLAN/Tunnel</span>
            <span><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--red);margin-right:4px"></span>DOWN</span>
          </div>
        </div>
        <!-- canvas -->
        <div style="flex:1;position:relative;overflow:hidden">
          <canvas id="topo-canvas" style="width:100%;height:100%;display:block;cursor:grab"></canvas>
          <!-- node tooltip -->
          <div id="topo-tooltip" style="position:absolute;display:none;background:var(--bg3);border:1px solid var(--border2);border-radius:8px;padding:10px 14px;font-size:11px;color:var(--text);pointer-events:none;min-width:160px;box-shadow:0 4px 20px rgba(0,0,0,.4)">
            <div id="tt-name" style="font-weight:700;color:var(--cyan);margin-bottom:6px;font-size:13px"></div>
            <div id="tt-type" style="color:var(--text3);margin-bottom:4px"></div>
            <div id="tt-state"></div>
            <div id="tt-ips" style="color:var(--text2);margin-top:4px"></div>
          </div>
          <!-- empty state -->
          <div id="topo-empty" style="display:none;position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;color:var(--text3)">
            <div style="font-size:48px;margin-bottom:12px">🕸</div>
            <div style="font-size:14px">No network data found</div>
            <div style="font-size:11px;margin-top:6px">Make sure NetCoreOS is running and interfaces are up</div>
          </div>
        </div>
      </div>
    </div>

  </div>

  <!-- RIGHT PANEL -->
  <div class="right-panel">
    <div class="right-tabs">
      <div class="right-tab active" onclick="showRightTab('log',this)">Log</div>
      <div class="right-tab" onclick="showRightTab('arp',this)">ARP</div>
      <div class="right-tab" onclick="showRightTab('mac',this)">MAC</div>
    </div>
    <div class="right-content active" id="right-log"></div>
    <div class="right-content" id="right-arp"></div>
    <div class="right-content" id="right-mac"></div>
  </div>
</div>

<!-- COMMAND BAR -->
<div class="cmd-bar">
  <span class="cmd-prompt" id="cmd-prompt">ncos#</span>
  <div class="run-ind" id="bar-running"><div class="spin"></div></div>
  <input class="cmd-input" id="cmd-input" placeholder="Type any NetCoreOS command here and press Enter…"
         onkeydown="onCmdKey(event)"/>
  <button class="cmd-run-btn" onclick="runBarCmd()">▶ Run</button>
</div>

<div id="toast"></div>

<script>
let currentMode='ncos',currentPanel='dashboard';
let cmdHistory=[],histIdx=-1;
let authToken=localStorage.getItem('netcoreos_token')||'';

// ── Auth: this Web UI can now be reached from other devices on the LAN,
// so every /api/* call must carry the access token shown in the netcoreos
// console when 'web' was run. Prompted once, then cached in localStorage.
async function promptForToken(){
  const t=prompt('NetCoreOS Web UI\\n\\nEnter the access token shown in the netcoreos console (after typing "web"):');
  if(t){authToken=t.trim();localStorage.setItem('netcoreos_token',authToken);}
  return authToken;
}

// ── helpers ──────────────────────────────────────────────────────────────────
function g(id){return(document.getElementById(id)||{}).value||'';}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function colorize(t){
  return t
    .replace(/(\\[\\+\\][^\\n]*)/g,'<span class="t-info">$1</span>')
    .replace(/(\\[\✔\\][^\\n]*)/g,'<span class="t-ok">$1</span>')
    .replace(/(\\[!\\][^\\n]*)/g,'<span class="t-warn">$1</span>')
    .replace(/(\\[-\\][^\\n]*)/g,'<span class="t-error">$1</span>')
    .replace(/(\\[>\\][^\\n]*)/g,'<span class="t-cmd">$1</span>')
    .replace(/\\[Error\\][^\\n]*/g,m=>'<span class="t-error">'+m+'</span>');
}

// ── API ───────────────────────────────────────────────────────────────────────
async function api(path,params={}){
  const qs=new URLSearchParams(params).toString();
  const opts={headers:{'X-Auth-Token':authToken}};
  try{
    const r=await fetch(qs?path+'?'+qs:path,opts);
    if(r.status===401){
      await promptForToken();
      opts.headers['X-Auth-Token']=authToken;
      const r2=await fetch(qs?path+'?'+qs:path,opts);
      return await r2.json();
    }
    return await r.json();
  }
  catch(e){return{error:String(e)};}
}
// Command execution is state-changing (can reboot, change firewall rules,
// etc.), so it goes over POST with the token in a header — never a GET with
// the token in the URL, which would be vulnerable to CSRF via a bare link
// and would leak the token into logs/history/Referer.
async function apiPost(path,bodyObj={}){
  const opts={method:'POST',headers:{'Content-Type':'application/json','X-Auth-Token':authToken},body:JSON.stringify(bodyObj)};
  try{
    const r=await fetch(path,opts);
    if(r.status===401){
      await promptForToken();
      opts.headers['X-Auth-Token']=authToken;
      const r2=await fetch(path,opts);
      return await r2.json();
    }
    return await r.json();
  }
  catch(e){return{error:String(e)};}
}
async function silosCmd(cmd){
  const r=await apiPost('/api/run',{cmd});
  return r.output||r.error||'(no output)';
}

// ── command runner ────────────────────────────────────────────────────────────
async function qc(cmd){
  if(!cmd||!cmd.trim()){toast('Fill in all fields first','warn');return;}
  appendTerm('\\n$ '+cmd+'\\n');
  setRunning(true);
  const out=await silosCmd(cmd);
  setRunning(false);
  appendTerm(out+'\\n');
  const isErr=/error|unknown|invalid|not found|failed/i.test(out);
  toast(isErr?out.split('\\n')[0].slice(0,80):'\✔ '+cmd.split(' ').slice(0,3).join(' '),isErr?'error':'ok');
  await refreshCurrentPanel();
  await loadLog();
  await updateStats();
}

// tools output to specific terminal
async function toolCmd(cmd,outId='tools-output'){
  if(!cmd||!cmd.trim()){toast('Fill in all fields first','warn');return;}
  document.getElementById(outId).textContent='Running: '+cmd+'...';
  const out=await silosCmd(cmd);
  document.getElementById(outId).textContent=out;
}

async function runBarCmd(){
  const inp=document.getElementById('cmd-input');
  const cmd=inp.value.trim();
  if(!cmd)return;
  cmdHistory.unshift(cmd);if(cmdHistory.length>50)cmdHistory.pop();histIdx=-1;
  inp.value='';
  appendTerm('\\n$ '+cmd+'\\n');
  document.getElementById('bar-running').classList.add('show');
  const out=await silosCmd(cmd);
  document.getElementById('bar-running').classList.remove('show');
  appendTerm(out+'\\n');
  const isErr=/error|unknown|invalid/i.test(out);
  toast(isErr?out.split('\\n')[0].slice(0,80):'\✔ Done','ok');
  await updateStats();await refreshCurrentPanel();await loadLog();
}

function onCmdKey(e){
  if(e.key==='Enter'){runBarCmd();return;}
  if(e.key==='ArrowUp'){histIdx=Math.min(histIdx+1,cmdHistory.length-1);document.getElementById('cmd-input').value=cmdHistory[histIdx]||'';e.preventDefault();}
  if(e.key==='ArrowDown'){histIdx=Math.max(histIdx-1,-1);document.getElementById('cmd-input').value=histIdx>=0?cmdHistory[histIdx]:'';e.preventDefault();}
}

// ── terminal ──────────────────────────────────────────────────────────────────
function appendTerm(text){
  const el=document.getElementById('term-output');
  const sp=document.createElement('span');
  sp.innerHTML=colorize(esc(text));
  el.appendChild(sp);el.scrollTop=el.scrollHeight;
}
function clearTerminal(){document.getElementById('term-output').innerHTML='';}
function setRunning(on){document.getElementById('term-running').classList.toggle('show',on);}

// ── nav ───────────────────────────────────────────────────────────────────────
function showPanel(id,el){
  document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
  document.getElementById('panel-'+id).classList.add('active');
  document.querySelectorAll('.nav-item').forEach(n=>n.classList.remove('active'));
  if(el)el.classList.add('active');
  currentPanel=id;refreshPanel(id);
}
function showRightTab(tab,el){
  document.querySelectorAll('.right-content').forEach(c=>c.classList.remove('active'));
  document.getElementById('right-'+tab).classList.add('active');
  document.querySelectorAll('.right-tab').forEach(t=>t.classList.remove('active'));
  if(el)el.classList.add('active');
  if(tab==='arp')loadARP();if(tab==='mac')loadMAC();
}
async function refreshCurrentPanel(){await refreshPanel(currentPanel);}

// ── toast ─────────────────────────────────────────────────────────────────────
function toast(msg,type='ok'){
  const t=document.getElementById('toast');
  t.textContent=msg;t.className='toast-'+type;t.style.display='block';
  clearTimeout(t._t);t._t=setTimeout(()=>t.style.display='none',3500);
}

// ── stats ─────────────────────────────────────────────────────────────────────
async function updateStats(){
  const s=await api('/api/stats');if(s.error)return;
  document.getElementById('hdr-uptime').textContent=s.uptime;
  document.getElementById('hdr-cpu').textContent=s.cpu;
  document.getElementById('hdr-mem').textContent=s.mem;
  const newMode=s.mode||'ncos';
  if(newMode!==currentMode){currentMode=newMode;applyModeUI();}
}

// ── Apply mode to all UI elements ────────────────────────────────────────────
function applyModeUI(){
  const m=currentMode;

  // Header badge
  const mb=document.getElementById('hdr-mode');
  mb.textContent=m;mb.className='mode-badge mode-'+m.replace('-','');

  // Mode switcher buttons
  document.querySelectorAll('.mode-btn').forEach(btn=>{
    btn.classList.toggle('active',btn.dataset.mode===m);
  });

  // Bottom cmd-bar prompt — colored per mode, same style as the CLI
  const promptEl=document.getElementById('cmd-prompt');
  if(promptEl){
    const modeColors={
      'ncos':     'var(--green)',
      'switch':   'var(--cyan)',
      'switch-mls':'var(--cyan)',
      'router':   'var(--yellow)',
      'firewall': 'var(--red)',
    };
    const col=modeColors[m]||'var(--green)';
    promptEl.textContent=m+'#';
    promptEl.style.color=col;
  }

  // Terminal title
  document.getElementById('term-title').textContent='netcoreos \u2014 '+m+' mode';

  // Dashboard mode value
  document.getElementById('dash-mode').textContent=m;

  // ── Mode-aware guards ───────────────────────────────────────────────────────
  const needSwitch=m==='switch'||m==='switch-mls';
  const needRouter=m==='switch-mls'||m==='router';
  const needFW=m==='firewall';

  setGuard('vlan-guard',   !needSwitch, 'switch or switch-mls',   ['switch','switch-mls']);
  setGuard('route-guard',  !needRouter, 'switch-mls or router',   ['switch-mls','router']);
  setGuard('fw-guard',     !needFW,     'firewall',               ['firewall']);
  setGuard('ospf-guard',   !needRouter, 'switch-mls or router',   ['switch-mls','router']);
  setGuard('bgp-guard',    !needRouter, 'switch-mls or router',   ['switch-mls','router']);
  setGuard('rp-guard',     !needRouter, 'switch-mls or router',   ['switch-mls','router']);
  setGuard('vrrp-guard',   !needRouter, 'switch-mls or router',   ['switch-mls','router']);
  setGuard('bfd-guard',    !needRouter, 'switch-mls or router',   ['switch-mls','router']);
}

function setGuard(id, locked, modeNeeded, targets){
  const el=document.getElementById(id);
  if(!el)return;
  if(locked){
    const tgt=targets[0];
    el.style.display='flex';
    el.innerHTML='<div class="mgb-icon">\u26a0\ufe0f</div><div class="mgb-text"><strong>Wrong mode — currently in '+currentMode+' mode</strong>This panel requires <strong>'+modeNeeded+'</strong> mode. Switch now to enable all features.</div><button onclick="switchMode(\''+tgt+'\')">Switch to '+tgt+'</button>';
  } else {
    el.style.display='none';
  }
}

// ── Switch mode (sends command + waits for confirmation) ─────────────────────
async function switchMode(mode){
  if(mode===currentMode){toast('Already in '+mode+' mode','warn');return;}
  const confirmed=await confirmDialog(
    'Switch to '+mode+' mode?',
    'This will clean up the current '+currentMode+' configuration. Continue?'
  );
  if(!confirmed)return;

  // Immediately update UI so user gets instant feedback
  currentMode=mode;
  applyModeUI();

  appendTerm('\n$ '+mode+'\n');
  setRunning(true);
  const out=await silosCmd(mode==='ncos' ? 'back' : mode);
  setRunning(false);
  appendTerm(out+'\n');

  // Re-sync from server to confirm the actual new mode
  await updateStats();
  applyModeUI();
  toast('\u2714 Switched to '+mode+' mode','ok');
  await refreshCurrentPanel();
}

// ── Confirmation dialog (replaces window.confirm for async safety) ────────────
function confirmDialog(title, msg){
  return new Promise(resolve=>{
    const ov=document.createElement('div');
    ov.style.cssText='position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:9000;display:flex;align-items:center;justify-content:center';
    ov.innerHTML=`<div style="background:var(--bg2);border:1px solid var(--border);border-radius:12px;padding:28px 32px;max-width:380px;width:90%">
      <div style="font-family:var(--font-head);font-size:16px;font-weight:700;color:#fff;margin-bottom:8px">${esc(title)}</div>
      <div style="color:var(--text2);font-size:12px;margin-bottom:24px;line-height:1.6">${esc(msg)}</div>
      <div style="display:flex;gap:10px;justify-content:flex-end">
        <button id="dlg-cancel" style="background:transparent;border:1px solid var(--border);border-radius:5px;padding:8px 18px;color:var(--text2);font-family:var(--font-mono);cursor:pointer">Cancel</button>
        <button id="dlg-ok" style="background:var(--cyan);border:none;border-radius:5px;padding:8px 18px;color:#000;font-family:var(--font-mono);font-weight:700;cursor:pointer">Confirm</button>
      </div>
    </div>`;
    document.body.appendChild(ov);
    ov.querySelector('#dlg-ok').onclick=()=>{document.body.removeChild(ov);resolve(true);};
    ov.querySelector('#dlg-cancel').onclick=()=>{document.body.removeChild(ov);resolve(false);};
    ov.onclick=e=>{if(e.target===ov){document.body.removeChild(ov);resolve(false);}};
  });
}

// ── data loaders ──────────────────────────────────────────────────────────────
async function loadDashboard(){
  const[ifaces,addrs,routes,logD]=await Promise.all([api('/api/interfaces'),api('/api/addresses'),api('/api/routes'),api('/api/log',{n:500})]);
  const addrMap={};(addrs.data||[]).forEach(a=>{addrMap[a.iface]=a.ips;});
  document.getElementById('dash-ifaces').textContent=(ifaces.data||[]).length;
  document.getElementById('dash-routes').textContent=(routes.data||[]).length;
  document.getElementById('dash-logs').textContent=(logD.data||[]).length;
  const ifList=document.getElementById('dash-iface-list');
  const il=ifaces.data||[];
  ifList.innerHTML=il.length?il.map(i=>{
    const st=i.state.toLowerCase();
    const ips=(addrMap[i.name]||[]).join(' ')||'<span style="color:var(--text3)">no IP</span>';
    return '<div class="iface-row"><div class="iface-dot '+(st==='up'?'up':st==='down'?'down':'unknown')+'"></div><div class="iface-name">'+esc(i.name)+'</div><div class="iface-ips">'+ips+'</div><span class="badge badge-'+(st==='up'?'up':'down')+'">'+esc(i.state)+'</span></div>';
  }).join(''):'<div class="empty">No interfaces.</div>';
  const rList=document.getElementById('dash-route-list');
  const rd=routes.data||[];
  rList.innerHTML=rd.length?rd.map(r=>'<div style="padding:4px 0;border-bottom:1px solid var(--border);color:var(--text2);font-size:11px">'+esc(r)+'</div>').join(''):'<div class="empty">No routes.</div>';
}

async function loadInterfaces(){
  const[ifaces,addrs]=await Promise.all([api('/api/interfaces'),api('/api/addresses')]);
  const addrMap={};(addrs.data||[]).forEach(a=>{addrMap[a.iface]=a.ips;});
  const opts=(ifaces.data||[]).map(i=>'<option value="'+esc(i.name)+'">'+esc(i.name)+' ('+i.state+')</option>').join('');
  ['ip-iface','vlan-iface-sel','bw-iface','qos-iface'].forEach(id=>{const el=document.getElementById(id);if(el)el.innerHTML=opts||'<option>none</option>';});
  const tb=document.getElementById('iface-table-body');
  if(tb)tb.innerHTML='<table class="data-table"><thead><tr><th>Interface</th><th>State</th><th>IPs</th></tr></thead><tbody>'+(ifaces.data||[]).map(i=>{
    const st=i.state.toLowerCase();
    return '<tr><td style="color:var(--cyan);font-weight:600">'+esc(i.name)+'</td><td><span class="badge badge-'+(st==='up'?'up':'down')+'">'+esc(i.state)+'</span></td><td style="color:var(--text2)">'+esc((addrMap[i.name]||[]).join(', ')||'\—')+'</td></tr>';
  }).join('')+'</tbody></table>';
}

async function loadRoutes(){
  const r=await api('/api/routes');
  const el=document.getElementById('route-table');if(!el)return;
  el.innerHTML=(r.data||[]).length?(r.data||[]).map(l=>'<div style="padding:5px 0;border-bottom:1px solid var(--border);font-size:12px;color:var(--text2)">'+esc(l)+'</div>').join(''):'<div class="empty">No routes.</div>';
}

async function loadVLANs(){
  const r=await api('/api/vlans');const el=document.getElementById('vlan-table');if(!el)return;
  const d=r.data||[];
  el.innerHTML=(!d.length||d[0].includes('no bridge'))?'<div class="empty">No bridge or VLANs. Type <code>switch</code> first.</div>':'<div style="font-size:12px;color:var(--text2);white-space:pre;line-height:1.9;font-family:var(--font-mono)">'+esc(d.join('\\n'))+'</div>';
}

function setPortVLAN(){
  const iface=g('vlan-iface-sel'),vlan=g('vlan-port-id'),mode=g('vlan-port-mode');
  if(!vlan){toast('Enter a VLAN ID','warn');return;}
  qc(mode==='access'?'access '+iface+' '+vlan:'trunk '+iface+' '+vlan);
}

async function loadBonds(){
  const r=await api('/api/bonds');const el=document.getElementById('bond-table');if(!el)return;
  el.innerHTML=(r.data||[]).length?'<table class="data-table"><thead><tr><th>Bond</th><th>Members</th><th>Action</th></tr></thead><tbody>'+(r.data||[]).map(b=>'<tr><td style="color:var(--cyan);font-weight:600">'+esc(b.bond)+'</td><td style="color:var(--text2)">'+esc(b.members.join(', '))+'</td><td><button class="btn btn-danger btn-sm" onclick="qc(\\\'lacp remove '+esc(b.bond)+'\\\')">Remove</button></td></tr>').join('')+'</tbody></table>':'<div class="empty">No bonds.</div>';
}

async function loadVXLANs(){
  const r=await api('/api/vxlans');const el=document.getElementById('vxlan-table');if(!el)return;
  el.innerHTML=(r.data||[]).length?'<table class="data-table"><thead><tr><th>VNI</th><th>Local</th><th>Remote</th><th>Action</th></tr></thead><tbody>'+(r.data||[]).map(v=>'<tr><td style="color:var(--yellow);font-weight:600">'+esc(v.vni)+'</td><td style="color:var(--cyan)">'+esc(v.local)+'</td><td style="color:var(--cyan)">'+esc(v.remote)+'</td><td><button class="btn btn-danger btn-sm" onclick="qc(\\\'vxlan remove '+esc(v.vni)+'\\\')">Remove</button></td></tr>').join('')+'</tbody></table>':'<div class="empty">No tunnels.</div>';
}

async function loadFirewall(){
  const r=await api('/api/firewall');const el=document.getElementById('fw-rules');if(!el)return;
  el.innerHTML='<div style="font-size:11px;color:var(--text2);white-space:pre;line-height:1.8;font-family:var(--font-mono)">'+esc((r.data||['(not initialized)']).join('\\n'))+'</div>';
}

async function loadMonitors(){
  const r=await api('/api/monitors');const el=document.getElementById('monitor-table');if(!el)return;
  el.innerHTML=(r.data||[]).length?'<table class="data-table"><thead><tr><th>Target</th><th>Interval</th><th>Status</th><th>Action</th></tr></thead><tbody>'+(r.data||[]).map(m=>'<tr><td style="color:var(--cyan)">'+esc(m.target)+'</td><td>'+esc(m.interval)+'s</td><td><span class="badge badge-'+m.status+'">'+esc(m.status)+'</span></td><td><button class="btn btn-danger btn-sm" onclick="qc(\\\'monitor remove '+esc(m.target)+'\\\')">Remove</button></td></tr>').join('')+'</tbody></table>':'<div class="empty">No monitors running.</div>';
}

async function loadLog(){
  const r=await api('/api/log',{n:100});const el=document.getElementById('right-log');if(!el)return;
  const lines=(r.data||[]).reverse();
  el.innerHTML=lines.length?lines.map(line=>{
    const m=line.match(/^\\[(.+?)\\] \\[(.+?)\\] (.*)$/);
    if(!m)return'<div class="log-entry"><div class="log-msg" style="color:var(--text3);font-size:10px">'+esc(line)+'</div></div>';
    const[,ts,level,msg]=m;const shortTs=ts.split(' ')[1]||ts;
    return'<div class="log-entry"><div class="log-ts">'+esc(shortTs)+'</div><div class="log-level lv-'+esc(level)+'">'+esc(level)+'</div><div class="log-msg">'+esc(msg)+'</div></div>';
  }).join(''):'<div class="empty">No log entries yet.</div>';
}

async function loadARP(){
  const r=await api('/api/arp');
  document.getElementById('right-arp').innerHTML=(r.data||[]).length?(r.data||[]).map(l=>'<div style="padding:3px 0;border-bottom:1px solid var(--border);font-size:11px;color:var(--text2)">'+esc(l)+'</div>').join(''):'<div class="empty">ARP table empty.</div>';
}
async function loadMAC(){
  const r=await api('/api/macs');const d=r.data||[];
  document.getElementById('right-mac').innerHTML=(!d.length||d[0].includes('no bridge'))?'<div class="empty">No bridge MAC table (switch mode needed).</div>':d.map(l=>'<div style="padding:3px 0;border-bottom:1px solid var(--border);font-size:11px;color:var(--text2)">'+esc(l)+'</div>').join('');
}

// ══════════════════════════════════════════════════════════════════
// FRR — OSPF / BGP / BFD / VRRP / Route Policy LOADERS
// ══════════════════════════════════════════════════════════════════

// ── FRR status bar shared update ─────────────────────────────────
async function updateFRRBar(){
  const s=await api('/api/frr/status');
  const dot=document.getElementById('frr-dot');
  const txt=document.getElementById('frr-status-text');
  const banner=document.getElementById('frr-not-installed');
  if(!s||s.error){if(dot)dot.style.background='var(--text3)';return;}
  if(banner){banner.style.display=s.running?'none':'block';}
  if(dot){dot.style.background=s.running?'var(--green)':'var(--red)';}
  if(txt){txt.textContent=s.running?(s.version||'FRR running'):'FRR stopped — type: frr restart';}
}

// ── OSPF ──────────────────────────────────────────────────────────
async function ospfEnable(){
  const rid=g('ospf-rid');const net=g('ospf-net');const area=g('ospf-area')||'0';
  await qc('ospf enable');
  if(rid)await qc('ospf router-id '+rid);
  if(net)await qc('ospf network '+net+' area '+area);
  await loadOSPF();
}

async function loadOSPF(){
  await updateFRRBar();
  // Neighbors
  const nb=await api('/api/frr/ospf/neighbors');
  const ntbl=document.getElementById('ospf-neighbor-table');
  if(ntbl){
    const peers=nb.data||[];
    ntbl.innerHTML=peers.length?
      '<table class="data-table"><thead><tr><th>Neighbor ID</th><th>Priority</th><th>State</th><th>Dead Time</th><th>Interface</th></tr></thead><tbody>'+
      peers.map(p=>{
        const up=p.state.includes('Full')||p.state.includes('2-Way');
        return '<tr><td style="color:var(--cyan);font-weight:600">'+esc(p.neighbor_id)+'</td>'+
          '<td>'+esc(p.priority)+'</td>'+
          '<td><span class="badge badge-'+(up?'up':'warn')+'">'+esc(p.state)+'</span></td>'+
          '<td>'+esc(p.dead_time)+'</td>'+
          '<td style="color:var(--text2)">'+esc(p.interface)+'</td></tr>';
      }).join('')+'</tbody></table>':
      '<div class="empty">No OSPF neighbors. Run <code>ospf enable</code> and <code>ospf network &lt;prefix&gt; area 0</code>.</div>';
  }
  // Routes
  const rt=await api('/api/frr/ospf/routes');
  const rtbl=document.getElementById('ospf-route-table');
  if(rtbl){
    const routes=rt.data||[];
    rtbl.innerHTML=routes.length?
      '<div style="font-size:11px;color:var(--text2);font-family:var(--font-mono);line-height:1.9">'+
      routes.map(r=>'<div style="padding:2px 0;border-bottom:1px solid var(--border)">'+esc(r)+'</div>').join('')+'</div>':
      '<div class="empty">No OSPF routes learned.</div>';
  }
  // Also populate OSPF iface selector
  const isel=document.getElementById('ospf-iface-sel');
  if(isel&&!isel.innerHTML.includes('<option')){
    const ifaces=await api('/api/interfaces');
    isel.innerHTML=(ifaces.data||[]).map(i=>'<option>'+esc(i.name)+'</option>').join('');
  }
}

// ── BGP ───────────────────────────────────────────────────────────
async function bgpEnable(){
  const asn=g('bgp-asn');const rid=g('bgp-rid');
  if(!asn){toast('Enter an AS number','warn');return;}
  await qc('bgp as '+asn);
  if(rid)await qc('bgp router-id '+rid);
  await loadBGP();
}

async function bgpAddNeighbor(){
  const ip=g('bgp-nbr-ip');const as=g('bgp-nbr-as');const desc=g('bgp-nbr-desc');
  if(!ip||!as){toast('Enter neighbor IP and remote AS','warn');return;}
  await qc('bgp neighbor '+ip+' remote-as '+as);
  if(desc)await qc('bgp neighbor '+ip+' description '+desc);
  await loadBGP();
}
function bgpShutdownNeighbor(){const ip=g('bgp-nbr-ip');if(!ip){toast('Enter neighbor IP','warn');return;}qc('bgp neighbor '+ip+' shutdown');}
function bgpActivateNeighbor(){const ip=g('bgp-nbr-ip');if(!ip){toast('Enter neighbor IP','warn');return;}qc('bgp neighbor '+ip+' activate');}
function bgpRemoveNeighbor(){const ip=g('bgp-nbr-ip');if(!ip){toast('Enter neighbor IP','warn');return;}qc('bgp neighbor '+ip+' remove');}

async function loadBGP(){
  await updateFRRBar();
  const sum=await api('/api/frr/bgp/summary');
  document.getElementById('bgp-asn-display').textContent=sum.asn||'—';
  document.getElementById('bgp-rid-display').textContent=sum.router_id||'—';
  document.getElementById('bgp-peer-count').textContent=(sum.peers||[]).length;
  const ptbl=document.getElementById('bgp-peer-table');
  if(ptbl){
    const peers=sum.peers||[];
    ptbl.innerHTML=peers.length?
      '<table class="data-table"><thead><tr><th>Neighbor</th><th>Remote AS</th><th>Up/Down</th><th>State / Prefixes</th><th>Actions</th></tr></thead><tbody>'+
      peers.map(p=>{
        const established=!isNaN(parseInt(p.state));
        const stateLabel=established?p.state+' pfx':'<span style="color:var(--yellow)">'+esc(p.state)+'</span>';
        return '<tr>'+
          '<td style="color:var(--cyan);font-weight:600">'+esc(p.neighbor)+'</td>'+
          '<td>AS'+esc(p.remote_as)+'</td>'+
          '<td style="color:var(--text2)">'+esc(p.up_down)+'</td>'+
          '<td>'+stateLabel+'</td>'+
          '<td style="display:flex;gap:4px">'+
            '<button class="btn btn-ghost btn-sm" onclick="qc(\'show bgp advertised '+esc(p.neighbor)+'\')">Adv</button>'+
            '<button class="btn btn-ghost btn-sm" onclick="qc(\'show bgp received '+esc(p.neighbor)+'\')">Rcv</button>'+
            '<button class="btn btn-danger btn-sm" onclick="qc(\'bgp neighbor '+esc(p.neighbor)+' shutdown\')">Shut</button>'+
          '</td></tr>';
      }).join('')+'</tbody></table>':
      '<div class="empty">No BGP peers. Run <code>bgp as &lt;ASN&gt;</code> then <code>bgp neighbor &lt;ip&gt; remote-as &lt;asn&gt;</code>.</div>';
  }
  // BGP route table
  const rt=await api('/api/frr/bgp/routes');
  const rtbl=document.getElementById('bgp-route-table');
  if(rtbl){
    const routes=rt.data||[];
    rtbl.innerHTML=routes.length?
      '<div style="font-size:11px;color:var(--text2);font-family:var(--font-mono);line-height:1.8;overflow-x:auto">'+
      routes.map(r=>{
        const best=r.startsWith('*>');
        return '<div style="padding:2px 0;border-bottom:1px solid var(--border);'+(best?'color:var(--green)':'')+'">'
          +esc(r)+'</div>';
      }).join('')+'</div>':
      '<div class="empty">No BGP routes.</div>';
  }
}

// ── Route Policy (Prefix Lists + Route Maps + RPKI) ───────────────
function createPrefixList(){
  const name=g('pl-name');const action=g('pl-action');const prefix=g('pl-prefix');const le=g('pl-le');
  if(!name||!prefix){toast('Enter list name and prefix','warn');return;}
  let cmd='prefix-list create '+name+' '+action+' '+prefix;
  if(le)cmd+=' le '+le;
  qc(cmd);setTimeout(loadRoutePol,1000);
}

async function loadRoutePol(){
  // Prefix lists
  const pl=await api('/api/frr/prefix-lists');
  const ptbl=document.getElementById('pl-table');
  if(ptbl){
    const lists=pl.data||[];
    ptbl.innerHTML=lists.length?
      '<table class="data-table"><thead><tr><th>Name</th><th>Action</th><th>Prefix</th><th>Del</th></tr></thead><tbody>'+
      lists.map(p=>'<tr>'+
        '<td style="color:var(--cyan);font-weight:600">'+esc(p.name)+'</td>'+
        '<td><span class="badge badge-'+(p.action==='permit'?'up':'down')+'">'+esc(p.action)+'</span></td>'+
        '<td style="font-family:var(--font-mono);font-size:11px">'+esc(p.prefix)+'</td>'+
        '<td><button class="btn btn-danger btn-sm" onclick="qc(\'prefix-list delete '+esc(p.name)+'\')">✕</button></td></tr>'
      ).join('')+'</tbody></table>':
      '<div class="empty">No prefix lists.</div>';
  }
  // Route maps
  const rm=await api('/api/frr/route-maps');
  const rtbl=document.getElementById('rm-table');
  if(rtbl){
    const maps=rm.data||[];
    rtbl.innerHTML=maps.length?
      '<table class="data-table"><thead><tr><th>Name</th><th>Action</th><th>Seq</th><th>Del</th></tr></thead><tbody>'+
      maps.map(m=>'<tr>'+
        '<td style="color:var(--cyan);font-weight:600">'+esc(m.name)+'</td>'+
        '<td><span class="badge badge-'+(m.action==='permit'?'up':'down')+'">'+esc(m.action)+'</span></td>'+
        '<td>'+esc(m.seq)+'</td>'+
        '<td><button class="btn btn-danger btn-sm" onclick="qc(\'routemap delete '+esc(m.name)+'\')">✕</button></td></tr>'
      ).join('')+'</tbody></table>':
      '<div class="empty">No route maps.</div>';
  }
}

// ── VRRP ─────────────────────────────────────────────────────────
async function loadVRRP(){
  const r=await api('/api/frr/vrrp');
  const tbl=document.getElementById('vrrp-table');
  if(!tbl)return;
  const data=r.data||[];
  tbl.innerHTML=data.length?
    '<table class="data-table"><thead><tr><th>VRID</th><th>Interface</th><th>VIP</th><th>Priority</th><th>State</th><th>Del</th></tr></thead><tbody>'+
    data.map(v=>'<tr>'+
      '<td style="color:var(--yellow);font-weight:600">'+esc(v.vrid)+'</td>'+
      '<td>'+esc(v.iface)+'</td>'+
      '<td style="color:var(--cyan);font-family:var(--font-mono)">'+esc(v.vip)+'</td>'+
      '<td>'+esc(v.priority)+'</td>'+
      '<td><span class="badge badge-'+(v.state==='MASTER'?'up':'warn')+'">'+esc(v.state)+'</span></td>'+
      '<td><button class="btn btn-danger btn-sm" onclick="qc(\'vrrp remove '+esc(v.vrid)+'\')">✕</button></td></tr>'
    ).join('')+'</tbody></table>':
    '<div class="empty">No VRRP groups. Use: <code>vrrp create &lt;vrid&gt; &lt;iface&gt; &lt;vip&gt; priority &lt;n&gt;</code></div>';
  // Check keepalived status
  const kst=document.getElementById('vrrp-kstatus');
  if(kst){const out=await silosCmd('vrrp show');kst.textContent=out.includes('running')?'keepalived: running':'keepalived: stopped';}
}

// ── BFD ──────────────────────────────────────────────────────────
function createVRRP(){
  const vrid=g('vrrp-vrid');const iface=g('vrrp-iface');const vip=g('vrrp-vip');const prio=g('vrrp-prio')||'100';
  if(!vrid||!vip){toast('Enter VRID and VIP','warn');return;}
  qc('vrrp create '+vrid+' '+iface+' '+vip+' priority '+prio);
  setTimeout(loadVRRP,1500);
}

async function loadBFD(){
  await updateFRRBar();
  // Populate interface selectors
  const ifaces=await api('/api/interfaces');
  const opts=(ifaces.data||[]).map(i=>'<option>'+esc(i.name)+'</option>').join('');
  ['bfd-iface-sel','vrrp-iface','ospf-iface-sel'].forEach(id=>{
    const el=document.getElementById(id);
    if(el&&!el.innerHTML.includes('<option value'))el.innerHTML=opts||'<option>none</option>';
  });
  const r=await api('/api/frr/bfd');
  const tbl=document.getElementById('bfd-peer-table');
  if(!tbl)return;
  const peers=r.data||[];
  tbl.innerHTML=peers.length?
    '<table class="data-table"><thead><tr><th>Peer IP</th><th>State</th><th>TX Interval</th><th>RX Interval</th></tr></thead><tbody>'+
    peers.map(p=>'<tr>'+
      '<td style="color:var(--cyan);font-weight:600;font-family:var(--font-mono)">'+esc(p.peer)+'</td>'+
      '<td><span class="badge badge-'+(p.state.toLowerCase()==='up'?'up':'warn')+'">'+esc(p.state)+'</span></td>'+
      '<td style="color:var(--text2)">'+esc(p.tx||'—')+'</td>'+
      '<td style="color:var(--text2)">'+esc(p.rx||'—')+'</td></tr>'
    ).join('')+'</tbody></table>':
    '<div class="empty">No BFD peers. Run <code>bfd enable</code> then <code>bfd peer &lt;ip&gt;</code>.</div>';
}


async function refreshPanel(id){
  switch(id){
    case'dashboard':await loadDashboard();break;
    case'interfaces':await loadInterfaces();break;
    case'routing':await loadRoutes();break;
    case'vlans':await loadVLANs();await loadInterfaces();break;
    case'lacp':await loadBonds();break;
    case'vxlan':await loadVXLANs();break;
    case'firewall':await loadFirewall();break;
    case'tools':await loadInterfaces();break;
    case'monitor':await loadMonitors();break;
    case'qos':await loadInterfaces();break;
    case'topology':await loadTopology();break;
    case'ospf':await loadOSPF();break;
    case'bgp':await loadBGP();break;
    case'routepolicy':await loadRoutePol();break;
    case'vrrp':await loadVRRP();break;
    case'bfd':await loadBFD();break;
  }
}

// ══════════════════════════════════════════════════════════════════
// TOPOLOGY MAP ENGINE — force-directed canvas graph
// ══════════════════════════════════════════════════════════════════
let topoNodes=[],topoEdges=[];
let topoZoom=1,topoPan={x:0,y:0};
let topoDragNode=null,topoPanStart=null,topoIsPanning=false;
let topoHover=null,topoSimActive=false;

const NODE_STYLE={
  physical: {color:'#38bdf8',icon:'🔌',r:28},
  bridge:   {color:'#39d98a',icon:'🔀',r:32},
  vlan:     {color:'#fbbf24',icon:'🏷',r:24},
  bond:     {color:'#a78bfa',icon:'🔗',r:26},
  vxlan:    {color:'#fb923c',icon:'🌐',r:26},
  gateway:  {color:'#f87171',icon:'🌍',r:30},
  remote:   {color:'#fb923c',icon:'📡',r:26},
  loopback: {color:'#555e70',icon:'↩',r:20},
  monitor:  {color:'#f87171',icon:'👁',r:22},
  firewall: {color:'#f87171',icon:'🛡',r:28},
};
const EDGE_STYLE={
  bridge: {color:'#39d98a',dash:[]},
  vlan:   {color:'#fbbf24',dash:[6,3]},
  bond:   {color:'#a78bfa',dash:[]},
  vxlan:  {color:'#fb923c',dash:[10,4]},
  route:  {color:'#38bdf8',dash:[4,4]},
  monitor:{color:'#f87171',dash:[3,3]},
};

function topoCanvas(){return document.getElementById('topo-canvas');}
function topoCtx(){const c=topoCanvas();return c?c.getContext('2d'):null;}

async function loadTopology(){
  const r=await api('/api/topology');
  if(!r.nodes)return;
  const canvas=topoCanvas();
  if(!canvas)return;
  const dpr=window.devicePixelRatio||1;
  const rect=canvas.getBoundingClientRect();
  canvas.width=rect.width*dpr; canvas.height=rect.height*dpr;
  topoNodes=r.nodes; topoEdges=r.edges;
  document.getElementById('topo-empty').style.display=topoNodes.length?'none':'flex';
  if(!topoNodes.length)return;
  const cx=rect.width/2,cy=rect.height/2,rad=Math.min(cx,cy)*0.6;
  topoNodes.forEach((n,i)=>{
    const a=(2*Math.PI*i/topoNodes.length)-Math.PI/2;
    n.x=cx+rad*Math.cos(a); n.y=cy+rad*Math.sin(a);
    n.vx=0;n.vy=0;n.pinned=false;
  });
  topoZoom=1;topoPan={x:0,y:0};
  topoBindEvents(canvas);
  topoSimActive=true;
  topoSimulate(0);
}

function topoSimulate(iter){
  if(!topoSimActive)return;
  const K=2800,SPRING=0.035,LEN=150,DAMP=0.80,CAP=9;
  topoNodes.forEach((a,i)=>{
    if(a.pinned)return;
    let fx=0,fy=0;
    topoNodes.forEach((b,j)=>{
      if(i===j)return;
      const dx=a.x-b.x,dy=a.y-b.y,d=Math.sqrt(dx*dx+dy*dy)||1;
      const f=K/(d*d); fx+=dx/d*f; fy+=dy/d*f;
    });
    topoEdges.forEach(e=>{
      const other=e.from===a.id?topoNodes.find(n=>n.id===e.to):e.to===a.id?topoNodes.find(n=>n.id===e.from):null;
      if(!other)return;
      const dx=other.x-a.x,dy=other.y-a.y,d=Math.sqrt(dx*dx+dy*dy)||1;
      const f=SPRING*(d-LEN); fx+=dx/d*f; fy+=dy/d*f;
    });
    a.vx=Math.max(-CAP,Math.min(CAP,(a.vx+fx)*DAMP));
    a.vy=Math.max(-CAP,Math.min(CAP,(a.vy+fy)*DAMP));
    a.x+=a.vx; a.y+=a.vy;
  });
  topoDraw();
  if(iter<150)requestAnimationFrame(()=>topoSimulate(iter+1));
  else topoSimActive=false;
}

function topoDraw(){
  const canvas=topoCanvas(),ctx=topoCtx();
  if(!canvas||!ctx)return;
  const dpr=window.devicePixelRatio||1;
  const W=canvas.width,H=canvas.height;
  ctx.save();
  ctx.clearRect(0,0,W,H);

  // Grid background
  const gs=40*topoZoom*dpr;
  const ox=((topoPan.x*topoZoom)%40)*dpr,oy=((topoPan.y*topoZoom)%40)*dpr;
  ctx.strokeStyle='rgba(51,55,64,0.35)';ctx.lineWidth=1;
  for(let x=ox;x<W;x+=gs){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,H);ctx.stroke();}
  for(let y=oy;y<H;y+=gs){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(W,y);ctx.stroke();}

  ctx.scale(dpr,dpr);
  ctx.translate(topoPan.x,topoPan.y);
  ctx.scale(topoZoom,topoZoom);

  // Edges
  topoEdges.forEach(e=>{
    const A=topoNodes.find(n=>n.id===e.from),B=topoNodes.find(n=>n.id===e.to);
    if(!A||!B)return;
    const es=EDGE_STYLE[e.etype]||{color:'#444b57',dash:[]};
    ctx.save();
    ctx.strokeStyle=es.color; ctx.lineWidth=1.5/topoZoom;
    ctx.setLineDash(es.dash); ctx.globalAlpha=0.55;
    ctx.beginPath(); ctx.moveTo(A.x,A.y); ctx.lineTo(B.x,B.y); ctx.stroke();
    if(e.label){
      const mx=(A.x+B.x)/2,my=(A.y+B.y)/2;
      const fs=10/topoZoom;
      ctx.font=`${fs}px JetBrains Mono,monospace`;
      const tw=ctx.measureText(e.label).width+8/topoZoom;
      const th=fs*1.4;
      ctx.globalAlpha=0.9; ctx.fillStyle='#111316';
      ctx.beginPath();
      if(ctx.roundRect)ctx.roundRect(mx-tw/2,my-th/2,tw,th,3/topoZoom);
      else ctx.rect(mx-tw/2,my-th/2,tw,th);
      ctx.fill();
      ctx.fillStyle=es.color; ctx.globalAlpha=1;
      ctx.textAlign='center'; ctx.textBaseline='middle';
      ctx.fillText(e.label,mx,my);
    }
    ctx.restore();
  });

  // Nodes
  topoNodes.forEach(node=>{
    const ns=NODE_STYLE[node.type]||NODE_STYLE.physical;
    const down=node.state==='down'||node.state==='dead';
    const hover=topoHover===node.id;
    const r=ns.r/topoZoom;
    ctx.save();
    if(hover){ctx.shadowColor=ns.color;ctx.shadowBlur=20/topoZoom;}
    // Circle fill
    ctx.beginPath(); ctx.arc(node.x,node.y,r,0,Math.PI*2);
    ctx.fillStyle=down?'#2a1a1a':'#1e2128'; ctx.fill();
    ctx.strokeStyle=down?'#f87171':hover?'#ffffff':ns.color;
    ctx.lineWidth=(hover?2.5:1.5)/topoZoom; ctx.stroke();
    ctx.shadowBlur=0;
    // Status dot
    const dr=5/topoZoom;
    ctx.beginPath(); ctx.arc(node.x+r*0.68,node.y-r*0.68,dr,0,Math.PI*2);
    const dotC=down?'#f87171':'#39d98a';
    ctx.fillStyle=dotC; ctx.shadowColor=dotC; ctx.shadowBlur=6/topoZoom;
    ctx.fill(); ctx.shadowBlur=0;
    // Icon
    ctx.font=`${Math.round(ns.r*0.55/topoZoom)}px serif`;
    ctx.textAlign='center'; ctx.textBaseline='middle';
    ctx.fillText(ns.icon,node.x,node.y-2/topoZoom);
    // Name label
    ctx.font=`bold ${11/topoZoom}px JetBrains Mono,monospace`;
    ctx.fillStyle=down?'#f87171':hover?'#ffffff':'#d4d8e2';
    ctx.fillText(node.label,node.x,node.y+r+11/topoZoom);
    // IP (if zoomed in enough)
    if(node.ips&&node.ips.length&&topoZoom>0.55){
      ctx.font=`${9/topoZoom}px JetBrains Mono,monospace`;
      ctx.fillStyle='#555e70';
      ctx.fillText(node.ips[0],node.x,node.y+r+21/topoZoom);
    }
    ctx.restore();
  });
  ctx.restore();
}

function topoScreenToWorld(e,canvas){
  const rect=canvas.getBoundingClientRect();
  return{wx:(e.clientX-rect.left)/topoZoom-topoPan.x,wy:(e.clientY-rect.top)/topoZoom-topoPan.y};
}
function topoHitTest(wx,wy){
  return topoNodes.find(n=>{
    const s=NODE_STYLE[n.type]||NODE_STYLE.physical;
    return Math.hypot(n.x-wx,n.y-wy)<s.r/topoZoom;
  });
}

function topoBindEvents(canvas){
  const fresh=canvas.cloneNode(true);
  canvas.parentNode.replaceChild(fresh,canvas);
  const c=document.getElementById('topo-canvas');

  c.addEventListener('wheel',e=>{
    e.preventDefault();
    const f=e.deltaY<0?1.12:0.9;
    topoZoom=Math.max(0.15,Math.min(5,topoZoom*f));
    topoDraw();
  },{passive:false});

  c.addEventListener('mousedown',e=>{
    const{wx,wy}=topoScreenToWorld(e,c);
    const hit=topoHitTest(wx,wy);
    if(hit){topoDragNode=hit;hit.pinned=true;c.style.cursor='grabbing';}
    else{topoPanStart={x:e.clientX-topoPan.x*topoZoom,y:e.clientY-topoPan.y*topoZoom};topoIsPanning=true;c.style.cursor='grabbing';}
  });

  c.addEventListener('mousemove',e=>{
    if(topoDragNode){
      const{wx,wy}=topoScreenToWorld(e,c);
      topoDragNode.x=wx; topoDragNode.y=wy;
      topoDraw(); return;
    }
    if(topoIsPanning&&topoPanStart){
      topoPan.x=(e.clientX-topoPanStart.x)/topoZoom;
      topoPan.y=(e.clientY-topoPanStart.y)/topoZoom;
      topoDraw(); return;
    }
    const{wx,wy}=topoScreenToWorld(e,c);
    const hit=topoHitTest(wx,wy);
    const prev=topoHover;
    topoHover=hit?hit.id:null;
    if(topoHover!==prev)topoDraw();
    c.style.cursor=hit?'pointer':'grab';
    const tt=document.getElementById('topo-tooltip');
    if(hit){
      document.getElementById('tt-name').textContent=hit.label;
      document.getElementById('tt-type').textContent='Type: '+hit.type;
      const sc=hit.state==='up'||hit.state==='running'?'var(--green)':'var(--red)';
      document.getElementById('tt-state').innerHTML='State: <span style="color:'+sc+'">'+hit.state+'</span>';
      document.getElementById('tt-ips').textContent=hit.ips&&hit.ips.length?'IPs: '+hit.ips.join(', '):'';
      tt.style.display='block';
      tt.style.left=(e.offsetX+18)+'px'; tt.style.top=(e.offsetY-10)+'px';
    }else{tt.style.display='none';}
  });

  c.addEventListener('mouseup',()=>{
    if(topoDragNode){topoDragNode=null;}
    topoIsPanning=false; topoPanStart=null;
    c.style.cursor='grab';
  });
  c.addEventListener('mouseleave',()=>{
    topoDragNode=null; topoIsPanning=false; topoPanStart=null;
    topoHover=null; document.getElementById('topo-tooltip').style.display='none';
    c.style.cursor='grab'; topoDraw();
  });
  c.addEventListener('dblclick',e=>{
    const{wx,wy}=topoScreenToWorld(e,c);
    const hit=topoHitTest(wx,wy);
    if(hit){hit.pinned=false;topoSimActive=true;topoSimulate(0);}
  });
  window.addEventListener('resize',()=>{
    const dpr=window.devicePixelRatio||1;
    const rect=c.getBoundingClientRect();
    c.width=rect.width*dpr; c.height=rect.height*dpr;
    topoDraw();
  });
}

function topoZoomIn(){topoZoom=Math.min(5,topoZoom*1.2);topoDraw();}
function topoZoomOut(){topoZoom=Math.max(0.15,topoZoom/1.2);topoDraw();}
function topoFit(){
  if(!topoNodes.length)return;
  const canvas=topoCanvas();
  const dpr=window.devicePixelRatio||1;
  const W=canvas.width/dpr,H=canvas.height/dpr;
  const xs=topoNodes.map(n=>n.x),ys=topoNodes.map(n=>n.y);
  const x0=Math.min(...xs)-50,x1=Math.max(...xs)+50;
  const y0=Math.min(...ys)-50,y1=Math.max(...ys)+50;
  topoZoom=Math.max(0.15,Math.min(5,Math.min(W/(x1-x0),H/(y1-y0))*0.9));
  topoPan.x=W/(2*topoZoom)-(x0+x1)/2;
  topoPan.y=H/(2*topoZoom)-(y0+y1)/2;
  topoDraw();
}
function topoReset(){
  topoZoom=1;topoPan={x:0,y:0};
  topoNodes.forEach(n=>{n.vx=0;n.vy=0;n.pinned=false;});
  topoSimActive=true;topoSimulate(0);
}

// ── Smart auto-refresh: only updates data tables, NOT form fields ─────────────
// This prevents the 5s timer from wiping whatever the user is typing.
async function refreshPanelData(id){
  switch(id){
    case'dashboard':  await loadDashboard(); break;
    case'interfaces': await _refreshIfaceTable(); break;
    case'routing':    await loadRoutes(); break;
    case'vlans':      await loadVLANs(); await _refreshIfaceTable(); break;
    case'lacp':       await loadBonds(); break;
    case'vxlan':      await loadVXLANs(); break;
    case'firewall':   await loadFirewall(); break;
    case'monitor':    await loadMonitors(); break;
    case'topology':   await loadTopology(); break;
    case'ospf':       await loadOSPF(); break;
    case'bgp':        await loadBGP(); break;
    case'routepolicy':await loadRoutePol(); break;
    case'vrrp':       await loadVRRP(); break;
    case'bfd':        await loadBFD(); break;
    // 'tools', 'qos', 'acl', 'terminal' — no auto-refresh, user is interacting
  }
}

// Refresh only the interface TABLE (not the dropdowns/selects the user might have open)
async function _refreshIfaceTable(){
  const[ifaces,addrs]=await Promise.all([api('/api/interfaces'),api('/api/addresses')]);
  const addrMap={};(addrs.data||[]).forEach(a=>{addrMap[a.iface]=a.ips;});
  const tb=document.getElementById('iface-table-body');
  if(tb)tb.innerHTML='<table class="data-table"><thead><tr><th>Interface</th><th>State</th><th>IPs</th></tr></thead><tbody>'+(ifaces.data||[]).map(i=>{
    const st=i.state.toLowerCase();
    return '<tr><td style="color:var(--cyan);font-weight:600">'+esc(i.name)+'</td><td><span class="badge badge-'+(st==='up'?'up':'down')+'">'+esc(i.state)+'</span></td><td style="color:var(--text2)">'+esc((addrMap[i.name]||[]).join(', ')||'\u2014')+'</td></tr>';
  }).join('')+'</tbody></table>';
  // Also update dash iface list if visible
  const dash=document.getElementById('dash-iface-list');
  if(dash){
    dash.innerHTML=(ifaces.data||[]).map(i=>{
      const up=i.state.toLowerCase()==='up';
      const ips=(addrMap[i.name]||[]).join(' ');
      return '<div class="iface-row"><div class="iface-dot '+(up?'up':'down')+'"></div><div class="iface-name">'+esc(i.name)+'</div><span class="badge badge-'+(up?'up':'down')+'">'+esc(i.state)+'</span><div class="iface-ips">'+esc(ips||'—')+'</div></div>';
    }).join('') || '<div class="empty">No interfaces found.</div>';
  }
}

async function init(){await updateStats();applyModeUI();await loadDashboard();await loadInterfaces();await loadLog();}
setInterval(async()=>{
  await updateStats();
  // Only auto-refresh data — never touch tools/qos/acl/terminal panels mid-edit
  const noAutoRefresh=['tools','qos','acl','terminal'];
  if(!noAutoRefresh.includes(currentPanel)) await refreshPanelData(currentPanel);
  if(document.querySelector('.right-content.active')?.id==='right-log') await loadLog();
},5000);
document.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='`'){document.getElementById('cmd-input').focus();e.preventDefault();}});
init();
</script>
</body>
</html>"""
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _authorized(self):
        if not AUTH_TOKEN:
            return BIND_HOST in ("127.0.0.1", "localhost", "::1")
        supplied = self.headers.get("X-Auth-Token", "")
        return hmac.compare_digest(supplied, AUTH_TOKEN)
    def send_html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path
        params = {k: v[0] for k, v in parse_qs(parsed.query).items()}
        if path.startswith("/api/") and not self._authorized():
            self.send_json({"error": "unauthorized", "need_token": True}, status=401)
            return
        if path in ("/", "/index.html"):
            self.send_html(HTML_PAGE)
        elif path == "/api/stats":
            self.send_json(get_system_stats())
        elif path == "/api/interfaces":
            self.send_json({"data": get_interfaces()})
        elif path == "/api/addresses":
            self.send_json({"data": get_addresses()})
        elif path == "/api/routes":
            self.send_json({"data": get_routes()})
        elif path == "/api/arp":
            self.send_json({"data": get_arp()})
        elif path == "/api/macs":
            self.send_json({"data": get_macs()})
        elif path == "/api/vlans":
            self.send_json({"data": get_vlans()})
        elif path == "/api/firewall":
            self.send_json({"data": get_firewall()})
        elif path == "/api/log":
            self.send_json({"data": get_log_tail(int(params.get("n", 100)))})
        elif path == "/api/bonds":
            self.send_json({"data": get_bonds()})
        elif path == "/api/vxlans":
            self.send_json({"data": get_vxlans()})
        elif path == "/api/monitors":
            self.send_json({"data": get_monitors()})
        elif path == "/api/topology":
            self.send_json(get_topology())
        elif path == "/api/frr/status":
            self.send_json(get_frr_status())
        elif path == "/api/frr/ospf/neighbors":
            self.send_json({"data": get_ospf_neighbors()})
        elif path == "/api/frr/ospf/routes":
            self.send_json({"data": get_ospf_routes()})
        elif path == "/api/frr/bgp/summary":
            self.send_json(get_bgp_summary())
        elif path == "/api/frr/bgp/routes":
            self.send_json({"data": get_bgp_routes()})
        elif path == "/api/frr/prefix-lists":
            self.send_json({"data": get_prefix_lists()})
        elif path == "/api/frr/route-maps":
            self.send_json({"data": get_route_maps()})
        elif path == "/api/frr/vrrp":
            self.send_json({"data": get_vrrp_instances()})
        elif path == "/api/frr/bfd":
            self.send_json({"data": get_bfd_peers()})
        elif path == "/api/frr/ospf/neighbors":
            self.send_json({"data": get_ospf_neighbors()})
        elif path == "/api/frr/ospf/routes":
            self.send_json({"data": get_ospf_routes()})
        elif path == "/api/frr/bgp/summary":
            self.send_json(get_bgp_summary())
        elif path == "/api/frr/bgp/routes":
            self.send_json({"data": get_bgp_routes()})
        elif path == "/api/frr/prefix-lists":
            self.send_json({"data": get_prefix_lists()})
        elif path == "/api/frr/route-maps":
            self.send_json({"data": get_route_maps()})
        elif path == "/api/frr/vrrp":
            self.send_json({"data": get_vrrp_instances()})
        else:
            self.send_json({"error": "Not found"}, 404)
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path != "/api/run":
            self.send_json({"error": "Not found"}, 404)
            return
        if not self._authorized():
            self.send_json({"error": "unauthorized", "need_token": True}, status=401)
            return
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = 0
        if length > 65536:
            self.send_json({"error": "payload too large"}, status=413)
            return
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            body = {}
        cmd = str(body.get("cmd", "")).strip()
        if not cmd:
            self.send_json({"output": "(empty command)"})
            return
        log_web(cmd)
        output = run_netcoreos(cmd)
        self.send_json({"output": output})
def main():
    if not find_script():
        print("[NetCoreOS Web UI] ERROR: netcoreos.sh not found!")
        print("  Place netcoreos_webui.py in the same folder as netcoreos.sh")
        print("  or: SILENTOS_SCRIPT=/path/to/netcoreos.sh python3 netcoreos_webui.py")
        sys.exit(1)
    os.makedirs(BASE_DIR, exist_ok=True)
    if not ensure_self_signed_cert():
        sys.exit(1)
    print(f"[NetCoreOS Web UI] Script: {SCRIPT_PATH}")
    print(f"[NetCoreOS Web UI] Listening on https://{BIND_HOST}:{PORT}")
    print(f"[NetCoreOS Web UI] Using a self-signed certificate — your browser will "
          f"warn about it once; that's expected for a device with no public domain.")
    if BIND_HOST != "127.0.0.1":
        if AUTH_TOKEN:
            print(f"[NetCoreOS Web UI] Reachable from the LAN — token required (see netcoreos CLI output).")
        else:
            print(f"[NetCoreOS Web UI] WARNING: reachable from the LAN with NO token set — "
                  f"anyone on the network can run commands here.")
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((BIND_HOST, PORT), Handler) as httpd:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(CERT_FILE, KEY_FILE)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n[NetCoreOS Web UI] Stopped.")
if __name__ == "__main__":
    main()
