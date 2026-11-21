import shlex
import socket
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path


PROBE = Path(__file__).resolve().parents[1] / "lib/port-probe.py"
SERVER = '''
import asyncio, ipaddress, runpy, sys
path, source, *ports = sys.argv[1:]
probe = runpy.run_path(path)["probe"]
sys.exit(not asyncio.run(probe("127.0.0.1", {ipaddress.ip_address(source)}, list(map(int, ports)), 2)))
'''


def reserve(host="127.0.0.1"):
    sock = socket.socket()
    sock.bind((host, 0))
    return sock


@contextmanager
def running(source, *ports):
    with subprocess.Popen(
        [sys.executable, "-u", "-c", SERVER, str(PROBE), source, *map(str, ports)],
        stdout=subprocess.PIPE, text=True,
    ) as process:
        try:
            lines = []
            for line in process.stdout:
                if line.startswith("python3 - "):
                    lines.append(line)
                    break
            assert lines, "Не сформирована команда для панели"
            for line in process.stdout:
                lines.append(line)
                if line.strip() == "REMNA_PROBE":
                    break
            yield process, "".join(lines), shlex.split(lines[0])[3]
        finally:
            if process.poll() is None:
                process.kill()


with reserve() as first, reserve() as second:
    first_port, second_port = first.getsockname()[1], second.getsockname()[1]
with running("127.0.0.1", first_port, second_port) as (server, command, _):
    client = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=6, check=True)
    assert client.stdout.count("обмен в обе стороны прошёл") == 2
    output, _ = server.communicate(timeout=4)
    assert server.returncode == 0 and output.count("обмен с 127.0.0.1 прошёл") == 2

with running("127.0.0.1", first_port) as (server, _, token):
    with socket.create_connection(("127.0.0.1", first_port), timeout=2) as connection:
        with connection.makefile("rb") as reply:
            payload = token.encode() * 128
            connection.sendall(payload)
            assert reply.read(len(payload)) == payload
    output, _ = server.communicate(timeout=4)
    assert server.returncode == 1 and "запрос дошёл, получение ответа не подтверждено" in output

with running("127.0.0.1", first_port) as (server, _, token):
    with socket.create_connection(("127.0.0.1", first_port), timeout=2) as connection:
        connection.sendall(token.encode() * 64)
    output, _ = server.communicate(timeout=4)
    assert server.returncode == 1 and "TCP открыт, тестовые данные не дошли целиком" in output

with running("127.0.0.2", first_port) as (server, command, _):
    client = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=6)
    assert client.returncode == 1
    output, _ = server.communicate(timeout=4)
    assert server.returncode == 1 and "нет подключения с разрешённого IP" in output

with reserve("0.0.0.0") as occupied:
    occupied.listen()
    with running("127.0.0.1", occupied.getsockname()[1], first_port) as (server, command, _):
        subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=6, check=True)
        server.communicate(timeout=4)
        assert server.returncode == 1
        with socket.create_connection(occupied.getsockname(), timeout=2):
            incoming, _ = occupied.accept()
            incoming.close()

print("Проверены обмен TCP в обе стороны, неполный обмен, ограничение по IP и занятый порт.")
