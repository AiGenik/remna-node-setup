import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
SSH = '''#!/usr/bin/env python3
import json
import os
import re
import shlex
import sys

args = sys.argv[1:]
if args[0] == "-G":
    print("hostname 127.0.0.1")
elif args[-2] == "panel-alias":
    assert "BatchMode=yes" in args and "ControlPath=none" in args and "ForwardAgent=no" in args
    command = shlex.split(args[-1])
    assert command[:4] == ["python3", "-I", "-", "127.0.0.1"]
    with open(os.environ["REMNA_PANEL_TRACE"], "a") as trace:
        trace.write("panel\\n")
    os.execvp(command[0], command)
else:
    assert args[-2] == "node-alias" and args[0] == "-tt"
    ticket = re.search(r"__ssh-menu ([a-f0-9]{32}) - 127.0.0.1", args[-1]).group(1)
    print("Меню ноды", flush=True)
    forged = json.dumps({"ticket":"0" * 32, "token":"1" * 32, "ports":[22], "tls":None})
    os.write(1, b"\\x1e")
    os.write(1, forged.encode() + b"\\x1f")
    os.execvp("python3", ["python3", os.environ["REMNA_PROBE"], "--launcher", ticket,
        os.environ["REMNA_TLS_PORT"], "127.0.0.1", "127.0.0.1", os.environ["REMNA_TEST_PORT"]])
'''


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


with tempfile.TemporaryDirectory() as directory:
    fixture = Path(directory)
    ssh = fixture / "ssh"
    ssh.write_text(SSH, encoding="utf-8")
    ssh.chmod(0o755)
    trace = fixture / "trace"
    env = {**os.environ, "PATH": f"{fixture}:{os.environ['PATH']}",
           "REMNA_PROBE": str(ROOT / "lib/port-probe.py"), "REMNA_PANEL_TRACE": str(trace)}

    def test(tls_port):
        return subprocess.run(["bash", str(ROOT / "remna-ssh"), "--panel", "panel-alias", "node-alias"],
                              capture_output=True, text=True, timeout=12,
                              env={**env, "REMNA_TEST_PORT": free_port(), "REMNA_TLS_PORT": tls_port})

    cert, key = fixture / "cert.pem", fixture / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=remna-panel-test", "-keyout", str(key), "-out", str(cert)],
                   check=True, capture_output=True, timeout=10)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(8)

        def serve_tls():
            connection, _ = listener.accept()
            with connection, context.wrap_socket(connection, server_side=True):
                pass

        thread = threading.Thread(target=serve_tls, daemon=True)
        thread.start()
        passed = test(str(listener.getsockname()[1]))
        thread.join(timeout=8)
        assert not thread.is_alive()

    assert passed.returncode == 0, passed
    assert "Проверка с панели panel-alias" in passed.stdout
    assert "отвечает TLS" in passed.stdout and "обмен с 127.0.0.1 прошёл" in passed.stdout
    assert "REMNA_PROBE" not in passed.stdout and "\x1e" not in passed.stdout
    assert trace.read_text() == "panel\n"

    with socket.socket() as closed_tls:
        closed_tls.bind(("127.0.0.1", 0))
        failed = test(str(closed_tls.getsockname()[1]))
    assert failed.returncode == 1, failed
    assert "TLS:" in failed.stdout and "обмен с 127.0.0.1 прошёл" in failed.stdout
    assert trace.read_text() == "panel\npanel\n"

print("Проверены автоматический запуск с панели, TLS, TCP и отклонение чужого запроса.")
