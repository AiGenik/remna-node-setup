from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import runpy
import socket
import subprocess
from unittest.mock import patch


dns = runpy.run_path(str(Path(__file__).resolve().parents[1] / "lib/selfsteal-dns.py"))
local_ip = "93.184.216.34"
interfaces = [{"addr_info": [
    {"scope": "global", "local": local_ip},
    {},
    {"scope": "link", "local": "fe80::1"},
]}]


def record(ip):
    return (socket.AF_INET6 if ":" in ip else socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0))


def run(records=None, error=None):
    output = io.StringIO()
    with (
        patch.object(subprocess, "check_output", return_value=json.dumps(interfaces).encode()),
        patch.object(socket, "getaddrinfo", return_value=records, side_effect=error),
        redirect_stdout(output),
    ):
        try:
            dns["check_domain"]("node.example.com", True)
        except SystemExit as exc:
            return str(exc)
    return output.getvalue()


assert f"node.example.com → {local_ip}" in run([record(local_ip)])
missing = run(error=socket.gaierror(socket.EAI_NONAME, "not found"))
assert "DNS не находит" in missing and local_ip in missing
mismatch = run([record(local_ip), record("2001:4860:4860::8888")])
assert local_ip in mismatch and "2001:4860:4860::8888" in mismatch and "DNS only" in mismatch
assert "DNS-сервер VPS" in run(error=socket.gaierror(socket.EAI_AGAIN, "retry"))
print("Проверены A/AAAA, NXDOMAIN, временный сбой резолвера и вывод iproute2.")
