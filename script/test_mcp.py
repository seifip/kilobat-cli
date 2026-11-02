#!/usr/bin/env python3
"""Live MCP handshake against `kilobat mcp`: initialize, tools/list, then status and diagnose calls.

Usage: script/test_mcp.py [path-to-kilobat-cli]   (default: .build/debug/kilobat)
Touches the real network (diagnose pings and resolves) and holds a sleep assertion for a moment; no settings are changed.
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
binary = sys.argv[1] if len(sys.argv) > 1 else str(ROOT / ".build/debug/kilobat")
server = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

def send(message):
    server.stdin.write(json.dumps(message) + "\n")
    server.stdin.flush()

def reply(id, message, reply_id=None):
    send(message)
    while True:
        line = server.stdout.readline()
        assert line, "server closed stdout"
        message = json.loads(line)  # Every stdout line must be a JSON-RPC message.
        if "id" in message and message["id"] == (id if reply_id is None else reply_id):
            return message

def request(id, method, params=None):
    message = reply(id, {"jsonrpc": "2.0", "id": id, "method": method, **({"params": params} if params is not None else {})})
    assert "error" not in message, message
    return message["result"]

def invalid_params(id, name, arguments):
    message = reply(id, {"jsonrpc": "2.0", "id": id, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
    assert message.get("error", {}).get("code") == -32602, message

init = request(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "kilobat-test", "version": "1"}})
assert init["protocolVersion"] == "2025-06-18" and init["serverInfo"]["name"] == "kilobat", init
send({"jsonrpc": "2.0", "method": "notifications/initialized"})

tools = {tool["name"]: tool for tool in request(2, "tools/list")["tools"]}
expected = {"get_status", "diagnose_network", "create_support_report", "get_proxy_status", "test_proxy_nodes", "check_vpn", "check_vpn_leaks", "get_call_reports", "get_remote_session_reports", "get_household", "get_starlink_status", "get_captive_portal", "get_wifi", "scan_wifi", "suggest_wifi_channel", "run_speedtest", "get_usage_report", "compare_usage", "get_network_history",
            "benchmark_dns", "check_url", "list_connections", "list_devices", "trace_route", "list_networks", "list_rules",
            "get_conditions", "diagnose_connection", "list_sessions", "agent_network_log", "keep_awake", "release_awake",
            "set_profile", "set_app_rule", "set_budget", "set_app_quota", "set_dns", "get_fastest_dns", "set_fastest_dns", "set_network_cost", "get_updaters", "set_updater_pause", "set_kill_switch", "get_uploads", "hold_upload",
            "get_app_bandwidth", "get_access_policy", "list_approvals", "list_blocked_connections",
            "set_new_app_mode", "decide_approval", "block_destination",
            "run_stutter_test", "get_game_ping", "get_nearby_radios", "get_bluetooth_audio", "set_airdrop_visibility",
            "get_exit_path", "compare_speed_tests", "get_plan_check", "get_router_checkup", "get_service_speed", "get_weekly_digest", "get_outage_credit", "get_route_history", "run_lan_test", "service_status",
            "check_host_reputation", "get_protection_status", "set_protection"}
assert set(tools) == expected, sorted(tools)
# run_speedtest transfers up to 80 MB, which costs data on metered links; run_lan_test floods the LAN for five seconds;
# keep_awake holds off idle sleep. None changes settings.
side_effects = {"run_speedtest", "run_lan_test", "keep_awake", "release_awake"}
for name, tool in tools.items():
    hints = tool["annotations"]
    changes = name.startswith("set_") or name in {"decide_approval", "block_destination", "hold_upload"}
    assert hints["readOnlyHint"] is not (changes or name in side_effects) and hints["destructiveHint"] is changes, (name, hints)
    assert hints["readOnlyHint"] or "confirmation" in tool["description"], name

invalid_params(10, "get_usage_report", {"days": True})
invalid_params(11, "get_usage_report", {"days": 7, "verbose": 1})
invalid_params(12, "check_url", {"url": 5})
invalid_params(13, "keep_awake", {"minutes": "5"})
invalid_params(14, "diagnose_connection", {"target": "example.com", "port": 443})
invalid_params(18, "set_app_quota", {"app": "com.example.App", "upload": True})
null_id = reply(None, {"jsonrpc": "2.0", "id": None, "method": "tools/list"})
assert null_id["id"] is None and null_id["error"]["code"] == -32600, null_id

# Router check-up reads what the app saved; it works (with an empty list) before the app has any history.
router = request(70, "tools/call", {"name": "get_router_checkup", "arguments": {"all": True}})
assert not router.get("isError"), router
for entry in router["structuredContent"]["routers"]:
    assert entry["state"] in {"learning", "waiting", "normal", "degraded", "signal"} and entry["headline"], entry
    assert set(entry["symptoms"]) <= {"slower", "loss", "drops", "dns"} and isinstance(entry["showsFinding"], bool), entry
    assert all(r["source"] in {"outage", "button"} and r["outcome"] in {None, "fixed", "helped", "didntHelp", "unclear", "noProblem"} for r in entry["restarts"]), entry
invalid_params(71, "get_router_checkup", {"all": "yes"})

# Service speed reads what the app saved; it works (with an empty list) before the app has measured anything.
speeds = request(72, "tools/call", {"name": "get_service_speed", "arguments": {"all": True}})
assert not speeds.get("isError"), speeds
for network in speeds["structuredContent"]["networks"]:
    assert network["note"] and isinstance(network["rows"], list), network
    for row in network["rows"]:
        assert row["kind"] in {"service", "network"} and row["state"] in {"fast", "mixed", "slow", "unknown"}, row
    if network.get("finding"):
        assert network["finding"]["kind"] in {"route", "service"} and network["finding"]["headline"], network["finding"]
invalid_params(73, "get_service_speed", {"all": "yes"})
# The weekly digest reads what the app saved; with no history it is an empty week, never an error.
week = request(73, "tools/call", {"name": "get_weekly_digest", "arguments": {"weeks_ago": 1}})
assert not week.get("isError"), week
digest = week["structuredContent"]
assert isinstance(digest["calm"], bool) and isinstance(digest["partial"], bool) and isinstance(digest["headline"], str), digest
assert len(digest["facts"]) <= 4, digest
for fact in digest["facts"]:
    assert fact["topic"] in {"outages", "calls", "remote", "router", "starlink", "protection", "agents", "metered", "credit", "plan", "signIns", "trackers", "routerHealthy"}, fact
    assert fact["line"] and fact["tab"] in {"History", "Wi-Fi", "Connections", "Speed"} and fact["value"] != 0, fact
assert request(74, "tools/call", {"name": "get_weekly_digest", "arguments": {"weeks_ago": 13}}).get("isError")
invalid_params(75, "get_weekly_digest", {"weeks_ago": "1"})

# Fastest DNS reads what the app saved (an empty list before any run); set_fastest_dns changes a setting, so it is
# only checked for its annotations and argument validation here.
fastest = request(172, "tools/call", {"name": "get_fastest_dns", "arguments": {"all": True}})
assert not fastest.get("isError"), fastest
dns = fastest["structuredContent"]
assert {"networks", "applied", "switches", "autoEverywhere", "excluded", "added", "rule"} <= set(dns), dns
for entry in dns["networks"]:
    assert entry["state"] in {"learning", "network", "faster"} and entry["headline"] and entry["daysNeeded"] == 3, entry
    assert all(r["note"] and isinstance(r["reliable"], bool) for r in entry["resolvers"]), entry
assert tools["get_fastest_dns"]["annotations"]["readOnlyHint"] and tools["set_fastest_dns"]["annotations"]["destructiveHint"]
assert "set_fastest_dns" in init["instructions"]
invalid_params(173, "get_fastest_dns", {"all": "yes"})
invalid_params(174, "set_fastest_dns", {"enabled": "on"})
invalid_params(175, "set_fastest_dns", {"enabled": True, "verbose": 1})

status = request(3, "tools/call", {"name": "get_status", "arguments": {}})
assert not status.get("isError"), status
snapshot = status["structuredContent"]
assert {"connected", "network", "metered", "profile", "apps", "downloadBytesPerSecond"} <= set(snapshot), snapshot.keys()

diagnosis = request(4, "tools/call", {"name": "diagnose_network", "arguments": {}})
assert not diagnosis.get("isError"), diagnosis
report = diagnosis["structuredContent"]
assert report["health"] in {"good", "degraded", "poor", "unknown"} and report["advice"], report

conditions = request(5, "tools/call", {"name": "get_conditions", "arguments": {}})["structuredContent"]
assert {"connected", "metered", "osMetered", "meteredSource", "lowDataMode", "vpn", "power", "keptAwake", "advice"} <= set(conditions) and conditions["advice"], conditions
assert set(conditions["updaters"]) == {"pauseOnMetered", "paused"}, conditions
# The kill switch: the saved settings always, the live state only from the running app (null otherwise).
assert {"enabled", "allowLAN", "state", "armed", "vpnUp", "allowedUntil", "filterActive", "summary"} <= set(conditions["killSwitch"]), conditions["killSwitch"]
assert conditions["killSwitch"]["state"] in {None, "off", "needsPro", "needsFilter", "waiting", "protected", "blocking", "allowed"}, conditions["killSwitch"]
vpn = request(61, "tools/call", {"name": "check_vpn", "arguments": {}})["structuredContent"]
assert vpn["vpnState"] in {"full", "partial", "off"} and type(vpn["killSwitch"]["enabled"]) is bool and vpn["killSwitch"]["summary"], vpn
assert tools["set_kill_switch"]["inputSchema"]["properties"]["state"]["enum"] == ["on", "off"] and "never turn it off" in tools["set_kill_switch"]["description"]
invalid_params(62, "set_kill_switch", {"state": True})
# The leak test: one check each for DNS, IPv6 and UDP, skipped without a full VPN, with a fix wherever one failed.
leaks = request(63, "tools/call", {"name": "check_vpn_leaks", "arguments": {}})["structuredContent"]
assert [check["id"] for check in leaks["checks"]] == ["dns", "ipv6", "udp"] and leaks["summary"] and isinstance(leaks["passed"], bool), leaks
assert all(check["status"] in {"pass", "fail", "warning", "skipped"} and (check["status"] != "fail" or check["fix"]) for check in leaks["checks"]), leaks
assert leaks["vpnState"] == "full" or all(check["status"] == "skipped" for check in leaks["checks"]), leaks
assert tools["check_vpn_leaks"]["annotations"]["openWorldHint"] is True
assert set(conditions["awakeOnPower"]) == {"enabled", "display", "active"} and all(type(v) is bool for v in conditions["awakeOnPower"].values()), conditions
assert conditions["meteredSource"] in {"macOS", "you"} and (conditions["meteredSource"] == "you" or conditions["metered"] == conditions["osMetered"]), conditions
assert tools["set_network_cost"]["inputSchema"]["properties"]["cost"]["enum"] == ["automatic", "metered", "unmetered"]

updaters = request(60, "tools/call", {"name": "get_updaters", "arguments": {}})["structuredContent"]
assert {"enabled", "metered", "paused", "filterActive", "covered", "gotThrough", "pausedConnections", "inProcess", "summary", "limits"} <= set(updaters), updaters
assert {"google", "microsoft", "macos", "app-store", "sparkle", "squirrel"} <= {helper["id"] for helper in updaters["covered"]}, updaters["covered"]
assert all(app["updater"] in {"Sparkle", "Squirrel"} for app in updaters["inProcess"]), updaters["inProcess"]
assert tools["set_updater_pause"]["inputSchema"]["properties"]["pause"]["enum"] == ["on", "off"]
invalid_params(19, "set_network_cost", {"cost": True})

# Read-only: whatever is uploading now, with a time left only where the total is known. Nothing is held here.
uploads = request(61, "tools/call", {"name": "get_uploads", "arguments": {}})["structuredContent"]
assert {"appRunning", "network", "metered", "uplinkMbps", "thresholdBytesPerSecond", "filterActive", "pro", "uploads", "limits"} <= set(uploads), uploads
assert uploads["appRunning"] or uploads["uploads"] == [], uploads
for entry in uploads["uploads"]:
    assert entry["state"] in {"uploading", "held"} and entry["method"] in {"suspend", "block", "none"}, entry
    assert entry["etaSeconds"] is None or entry["totalBytes"] is not None, entry
assert tools["hold_upload"]["inputSchema"]["properties"]["action"]["enum"] == ["hold", "resume"]
assert tools["hold_upload"]["inputSchema"]["required"] == ["app"]
invalid_params(20, "hold_upload", {"app": "Dropbox", "until": 2})
bad_until = reply(21, {"jsonrpc": "2.0", "id": 21, "method": "tools/call", "params": {"name": "hold_upload", "arguments": {"app": "Dropbox", "until": "tomorrow"}}})
assert bad_until.get("result", {}).get("isError") or "error" in bad_until, bad_until

doctor = request(6, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "example.com", "app": "com.apple.Safari", "failed_at": "2026-01-01T00:00:00Z"}})
assert not doctor.get("isError"), doctor
verdict = doctor["structuredContent"]
assert verdict["host"] == "example.com" and verdict["steps"] and isinstance(verdict["ok"], bool), verdict
# The diagnosis records the client as installed, the method sent, the path taken and the failure time beside the check's own.
assert verdict["client"]["id"] == "com.apple.Safari" and verdict["client"]["name"] and verdict["client"].get("version"), verdict
assert verdict["path"]["kind"] in {"appProxy", "environmentProxy", "systemProxy", "direct"} and verdict["failedAt"] == "2026-01-01T00:00:00Z" and verdict["date"], verdict
assert verdict.get("method") in {"HEAD", "GET", None} and (verdict.get("method") is None or verdict["method"] == verdict["hops"][0]["method"]), verdict
assert request(42, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "example.com", "failed_at": "2999-01-01T00:00:00Z"}}).get("isError")
assert request(43, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "example.com", "failed_at": "yesterday-ish"}}).get("isError")
invalid_params(44, "diagnose_connection", {"target": "example.com", "failed_at": 1767225600})
assert "failed_at" in tools["diagnose_connection"]["inputSchema"]["properties"]
assert request(7, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "not a host"}}).get("isError")
# The query goes in the request but never in the result.
signed = request(19, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "https://example.com/?token=secret123"}})
assert "secret123" not in json.dumps(signed) and signed["structuredContent"]["target"] == "https://example.com/?token=[redacted]", signed
assert signed["structuredContent"]["hops"][0]["url"] == "https://example.com/?token=[redacted]", signed
assert request(20, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "example.com", "proxy": "not a proxy"}}).get("isError")
invalid_params(21, "diagnose_connection", {"target": "example.com", "proxy": 8080})
assert tools["diagnose_connection"]["inputSchema"]["properties"]["context"]["enum"] == ["container", "vm", "remote", "provider"]
# A provider's servers can't reach this Mac's own address, whatever the local check finds; no SSH or tunnel offered.
routed = request(40, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "http://127.0.0.1:9/", "context": "provider", "app": "dev.warp.Warp-Stable"}})["structuredContent"]
provider = [step for step in routed["steps"] if step["layer"] == "Provider"]
assert provider and provider[0]["status"] == "failed" and "Oct 2026" in provider[0]["detail"] and "ssh" not in json.dumps(routed).lower(), routed
assert request(41, "tools/call", {"name": "diagnose_connection", "arguments": {"target": "example.com", "context": "cloud"}}).get("isError")

# A router or provider figure beside Kilobat's for the same period: matching units, coverage, gaps and reasons, never a verdict on either side.
compared = request(50, "tools/call", {"name": "compare_usage", "arguments": {"total": 40, "unit": "GB", "direction": "both", "period": "last-7-days"}})
assert not compared.get("isError"), compared
comparison = compared["structuredContent"]
assert comparison["externalBytes"] == 40_000_000_000 and comparison["alternateUnit"] == "GiB" and comparison["alternateBytes"] == 42_949_672_960, comparison
assert comparison["kilobatBytes"] == comparison["downloadBytes"] + comparison["uploadBytes"] and comparison["differenceBytes"] == 40_000_000_000 - comparison["kilobatBytes"], comparison
assert 0 <= comparison["coverage"] <= 1 and comparison["recordedHours"] <= comparison["periodHours"] + 1e-6 and comparison["reasons"] and comparison["summary"], comparison
assert all(gap["reason"] in {"notRecorded", "otherNetwork", "beforeHistory", "notYet"} and gap["hours"] > 0 for gap in comparison["gaps"]), comparison["gaps"]
assert not any(word in json.dumps(comparison["reasons"]).lower() for word in ["wrong", "fraud", "overcharg", "mistake"]), comparison["reasons"]
dated = request(51, "tools/call", {"name": "compare_usage", "arguments": {"total": 2, "unit": "GiB", "direction": "download", "from": "2026-10-01", "to": "2026-10-01"}})["structuredContent"]
assert dated["externalBytes"] == 2 * 1024 ** 3 and dated["direction"] == "download" and dated["kilobatBytes"] == dated["downloadBytes"], dated
assert request(52, "tools/call", {"name": "compare_usage", "arguments": {"total": 40, "unit": "GB"}}).get("isError")  # No period.
assert request(53, "tools/call", {"name": "compare_usage", "arguments": {"total": 40, "unit": "GB", "period": "today", "network": "no such network"}}).get("isError")
invalid_params(54, "compare_usage", {"total": "40GB", "unit": "GB", "period": "today"})
assert tools["compare_usage"]["inputSchema"]["required"] == ["total", "unit"] and "GiB" in tools["compare_usage"]["inputSchema"]["properties"]["unit"]["enum"]

# Paired Macs: read-only, never pairs; live usage only through the app with Pro.
household = request(80, "tools/call", {"name": "get_household", "arguments": {}})["structuredContent"]
assert {"name", "sharing", "appRunning", "peers"} <= set(household) and isinstance(household["peers"], list), household
assert all({"id", "name", "network", "pairedAt", "onThisNetwork"} <= set(peer) for peer in household["peers"]), household
assert household["appRunning"] or all(peer.get("live") is None for peer in household["peers"]), household
assert "never pairs" in tools["get_household"]["description"] and tools["get_household"]["annotations"]["readOnlyHint"]
invalid_params(81, "get_household", {"pair": True})
# The sign-in page check: a live probe plus the app's history, read-only, with any query values redacted.
portal = request(61, "tools/call", {"name": "get_captive_portal", "arguments": {}})["structuredContent"]
assert portal["state"] in {"open", "portal", "offline"} and portal["status"] in {"none", "signInNeeded", "loggedOut", "signedIn"}, portal
assert isinstance(portal["networks"], list) and (portal["signInPage"] is None or "=" not in portal["signInPage"] or "[redacted]" in portal["signInPage"]), portal
invalid_params(62, "get_captive_portal", {"verbose": True})

sessions = request(8, "tools/call", {"name": "list_sessions", "arguments": {"days": 1}})
assert isinstance(json.loads(sessions["content"][0]["text"]), list), sessions  # Arrays come as text only.

# The agent network log: read-only, the same object as `kilobat agent-log --json`, whether or not the app has recorded one.
log = request(55, "tools/call", {"name": "agent_network_log", "arguments": {"all": True, "flagged": True}})
assert not log.get("isError"), log
log = log["structuredContent"]
assert isinstance(log["sessions"], list) and all(host["flags"] for session in log["sessions"] for host in session["hosts"]), log
assert all({"process", "host", "port", "transport", "sent", "received", "connections", "flags"} <= set(host) for session in log["sessions"] for host in session["hosts"])
assert request(56, "tools/call", {"name": "agent_network_log", "arguments": {"since": "soon"}}).get("isError")
invalid_params(57, "agent_network_log", {"all": "yes"})

held = request(9, "tools/call", {"name": "keep_awake", "arguments": {"minutes": 1, "reason": "test_mcp.py"}})["structuredContent"]
assert held["holding"] and held["until"], held
assert request(15, "tools/call", {"name": "get_conditions", "arguments": {}})["structuredContent"]["awakeUntil"] == held["until"]
assert request(16, "tools/call", {"name": "release_awake", "arguments": {}})["structuredContent"]["released"] is True
assert request(17, "tools/call", {"name": "release_awake", "arguments": {}})["structuredContent"]["released"] is False

# The lid needs the app's power helper, allowed and approved by the person; without it nothing is held.
assert tools["keep_awake"]["inputSchema"]["properties"]["lid_closed"]["type"] == "boolean" and "lid_closed every time" in tools["keep_awake"]["description"]
assert {"lidClosedAllowed", "lidHold"} <= set(conditions), conditions
invalid_params(19, "keep_awake", {"minutes": 1, "lid_closed": "yes"})
lid = request(20, "tools/call", {"name": "keep_awake", "arguments": {"minutes": 1, "reason": "test_mcp.py", "lid_closed": True}})
if lid.get("isError"):
    assert "Kilobat" in lid["content"][0]["text"], lid
    assert request(21, "tools/call", {"name": "release_awake", "arguments": {}})["structuredContent"]["released"] is False
else:
    assert lid["structuredContent"]["lidHold"], lid
    assert request(21, "tools/call", {"name": "release_awake", "arguments": {}})["structuredContent"]["released"] is True

stutter = request(30, "tools/call", {"name": "run_stutter_test", "arguments": {"seconds": 10, "target": "internet"}})["structuredContent"]
assert stutter["sent"] == 200 and stutter["pattern"] in {"steady", "few", "periodic", "irregular", "noReplies"} and stutter["verdict"] and "samplesMs" not in stutter, stutter
invalid_params(31, "run_stutter_test", {"seconds": "10"})
# Game data centers: Fortnite's 16 subregions, a few seconds of pings. Games without a public target say why.
games = request(70, "tools/call", {"name": "get_game_ping", "arguments": {"game": "fortnite"}})["structuredContent"]
assert games["game"] == "fortnite" and len(games["regions"]) == 16 and {"pingMs", "jitterMs", "lossPercent", "method", "samplesMs"} <= set(games["regions"][0]), games
assert games["noReplies"] or (games["best"] in games["regions"] and games["overlayTarget"] == "fortnite:" + games["best"]["region"]), games
valorant = request(71, "tools/call", {"name": "get_game_ping", "arguments": {"game": "valorant"}})
assert valorant.get("isError") and "Riot" in valorant["content"][0]["text"] and "match" in valorant["content"][0]["text"], valorant
invalid_params(72, "get_game_ping", {"game": 2})
# Without a game, the list: every game with how it's measured and an icon, and the ones left out with why.
listed = request(73, "tools/call", {"name": "get_game_ping", "arguments": {}})["structuredContent"]
assert len(listed["games"]) >= 15 and {"cs2", "fortnite", "apex", "r6", "aoe2", "aoe4"} <= {g["game"] for g in listed["games"]}, listed
assert all(g["measuredBy"] in {"valve", "epic", "azure", "aws", "official"} and g["regions"] for g in listed["games"]), listed
assert listed["games"][0]["icon"].endswith("/cs2.webp") and any(n["game"] == "valorant" and n["reason"] for n in listed["notMeasured"]), listed
# An Azure game: PlayFab's beacon per region, each named by its Azure region.
age = request(74, "tools/call", {"name": "get_game_ping", "arguments": {"game": "Age of Empires IV"}})["structuredContent"]
assert age["game"] == "aoe4" and age["measuredBy"] == "azure" and all(r["cloud"].startswith("Azure ") for r in age["regions"]), age
assert age["noReplies"] or age["best"]["method"] in {"udp", "icmp", "tcp"}, age
# The match being played: nothing here is a game, so it says so instead of guessing.
match = request(75, "tools/call", {"name": "get_game_ping", "arguments": {"game": "match"}})["structuredContent"]
assert match["state"] in {"found", "noGame", "noServer", "hidden"}, match
radios = request(32, "tools/call", {"name": "get_nearby_radios", "arguments": {}})["structuredContent"]
assert {"awdl", "visibility", "devices", "wifiBand", "advice"} <= set(radios) and "summary" in radios["awdl"], radios
# Bluetooth audio: works with or without headphones playing; risks and actions come from fixed lists, and the basis is always said.
audio = request(76, "tools/call", {"name": "get_bluetooth_audio", "arguments": {}})["structuredContent"]
assert audio["source"] in {"app", "cli"} and isinstance(audio["playing"], bool) and audio["basis"], audio
assert set(audio["risks"]) <= {"wifi24GHz", "crowdedChannel", "airDrop", "heavyTraffic", "weakBluetooth", "busyBluetooth"}, audio
assert all(step["action"] in {None, "joinFasterBand", "pauseAirDrop"} and step["text"] for step in audio["advice"]), audio
assert audio["output"] is None or audio["output"]["transport"] in {"classic", "le"}, audio
assert audio["playing"] or not audio["risks"] or audio["output"] is not None, audio
assert tools["get_bluetooth_audio"]["annotations"]["readOnlyHint"] is True

# Where traffic leaves, read on the Mac: no public IP unless asked, since that contacts Cloudflare.
exit_path = request(33, "tools/call", {"name": "get_exit_path", "arguments": {}})["structuredContent"]
assert exit_path["vpn"] in {"full", "partial", "off"} and exit_path["lookedUp"] is False and exit_path["publicIP"] is None, exit_path
assert {"vpnName", "vpnConnected"} <= set(conditions), conditions
assert tools["get_exit_path"]["inputSchema"]["properties"]["public_ip"]["type"] == "boolean" and "anonymous" in tools["get_exit_path"]["description"]
invalid_params(34, "get_exit_path", {"public_ip": "yes"})
assert tools["run_speedtest"]["inputSchema"]["properties"]["parallel"]["type"] == "boolean"
assert tools["trace_route"]["inputSchema"]["properties"]["rounds"]["maximum"] == 5
assert "hosts" in request(35, "tools/call", {"name": "get_route_history", "arguments": {}})["structuredContent"]
assert request(36, "tools/call", {"name": "get_route_history", "arguments": {"host": "never-traced.invalid"}}).get("isError")
assert request(37, "tools/call", {"name": "compare_speed_tests", "arguments": {"first": "1"}}).get("isError")  # Both or neither.
# Outage credit: read-only, from the app's journal; an unknown provider is refused, a known one gets its rule and a draft.
credit = request(90, "tools/call", {"name": "get_outage_credit", "arguments": {"provider": "gb-bt", "monthly_price": 35, "month": "last"}})["structuredContent"]
assert credit["policy"]["id"] == "uk-ofcom" and credit["providerName"] == "BT" and "[your account number]" in credit["claim"]["body"], credit
assert {"outages", "localSeconds", "unprovenSeconds", "asleepSeconds"} <= set(credit["tally"]) and "qualifies" in credit["estimate"], credit
assert request(91, "tools/call", {"name": "get_outage_credit", "arguments": {"provider": "nope"}}).get("isError")
assert request(92, "tools/call", {"name": "get_outage_credit", "arguments": {"country": "US", "provider": "us-spectrum"}})["structuredContent"].get("policy") is None
invalid_params(93, "get_outage_credit", {"monthly_price": "35"})
lan = request(38, "tools/call", {"name": "run_lan_test", "arguments": {"host": "127.0.0.1"}})
assert lan.get("isError") and ("iperf3" in lan["content"][0]["text"]), lan  # No server here, or no iperf3: either way it says so.

# Status pages: the catalog without a request, one live page, and a name nobody knows.
catalog = request(80, "tools/call", {"name": "service_status", "arguments": {"list": True}})["structuredContent"]["services"]
assert len(catalog) >= 30 and any(row["id"] == "github" and row["format"] == "statuspage" for row in catalog), catalog
pages = request(81, "tools/call", {"name": "service_status", "arguments": {"service": "github.com, slack"}})["structuredContent"]["services"]
assert [row["id"] for row in pages] == ["github", "slack"], pages
# An agent asking about its own provider: Anthropic's page per component, and an API host.
own = request(84, "tools/call", {"name": "service_status", "arguments": {"service": "claude, api.openai.com"}})["structuredContent"]["services"]
assert [row["id"] for row in own] == ["claude", "claude-code", "anthropic-api", "openai-api"], own
assert all(row["state"] in {"unknown", "operational", "maintenance", "degraded", "partialOutage", "majorOutage"} and row["summary"] and row["page"].startswith("https://") for row in pages), pages
unknown = request(82, "tools/call", {"name": "service_status", "arguments": {"service": "not-a-service-anyone-runs"}})
assert unknown.get("isError") and "down --list" in unknown["content"][0]["text"], unknown
invalid_params(83, "service_status", {"list": "yes"})

# Protection: the host check and the status are read-only and local; set_protection is a change that tells the agent
# never to turn Protection off to get its own requests through. Nothing here changes a setting.
reputation = request(84, "tools/call", {"name": "check_host_reputation", "arguments": {"host": "https://malware.example/payload"}})
assert not reputation.get("isError"), reputation
checked = reputation["structuredContent"]
assert checked["host"] == "malware.example" and isinstance(checked["listed"], bool) and isinstance(checked["wouldBlock"], bool) and checked["note"], checked
assert not checked["localNetwork"]
local = request(85, "tools/call", {"name": "check_host_reputation", "arguments": {"host": "printer.local"}})["structuredContent"]
assert local["localNetwork"] and not local["wouldBlock"], local
invalid_params(86, "check_host_reputation", {"host": 5})
bad = request(87, "tools/call", {"name": "check_host_reputation", "arguments": {"host": "not a host"}})
assert bad.get("isError"), bad
protection = request(88, "tools/call", {"name": "get_protection_status", "arguments": {}})["structuredContent"]
assert {"threats", "trackers", "agentGuard", "threatEntries", "trackerEntries", "lists", "allowedSites", "uploadLimitMB"} <= set(protection), protection
assert tools["check_host_reputation"]["annotations"]["readOnlyHint"] and tools["get_protection_status"]["annotations"]["readOnlyHint"]
assert tools["set_protection"]["annotations"]["destructiveHint"] and "Never call this to turn Protection off" in tools["set_protection"]["description"]
assert "check_host_reputation" in init["instructions"] and "never turn Protection off" in init["instructions"]
invalid_params(89, "set_protection", {"threats": True})

server.stdin.close()
assert server.wait(timeout=10) == 0
print(f"✓ MCP {init['protocolVersion']} · {len(tools)} tools · status: {snapshot['network']}, {len(snapshot['apps'])} apps · diagnose: {report['health']} · example.com: {verdict['verdict']}")
for tip in report["advice"]:
    print("  " + tip)
print("  Conditions: " + conditions["advice"])
print(f"  Stutter (internet, 10 s): {stutter['verdict']}")
print(f"  Fortnite: best {games['best']['name']} at {games['best']['pingMs']} ms" if games["best"] else "  Fortnite: no data center answered")
print("  Status pages: " + " ".join(row["summary"] for row in pages))
print(f"  Age of Empires IV: best {age['best']['name']} ({age['best']['cloud']}, {age['best']['method']}) at {age['best']['pingMs']} ms" if age["best"] else "  Age of Empires IV: no region answered")
print(f"  Current match: {match['state']}")
print(f"  Protection: malware.example listed {checked['listed']} · threats {protection['threats']} · {protection['threatEntries']} entries")
print(f"  Nearby: {radios['awdl']['summary']} · AirDrop {radios['visibility']} · {len(radios['devices'])} Bluetooth devices")
