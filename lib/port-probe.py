import asyncio
import ipaddress
import json
import secrets
import shlex
import sys


SECONDS = 90
LAUNCHER_SECONDS = 28
TRANSFER_SECONDS = 5

CLIENT = '''import socket
import sys

host, token, *ports = sys.argv[1:]
ack = token.encode()
payload = ack * 128
failed = False
for port in ports:
    try:
        with socket.create_connection((host, int(port)), timeout=4) as conn:
            conn.sendall(payload)
            with conn.makefile("rb") as reply:
                if reply.read(len(payload)) != payload:
                    raise OSError("неполный ответ")
                conn.sendall(ack)
                if reply.read(1) != b"+":
                    raise OSError("подтверждение не получено")
        print(f"{port}/tcp: обмен в обе стороны прошёл", flush=True)
    except OSError as exc:
        print(f"{port}/tcp: {exc}", flush=True)
        failed = True
sys.exit(failed)
'''


def request_panel(ticket, token, ports, tls_port):
    request = {"ticket": ticket, "token": token, "ports": list(ports), "tls": tls_port}
    print("\x1e" + json.dumps(request, separators=(",", ":")) + "\x1f", end="", flush=True)


async def probe(host, sources, ports, seconds=SECONDS, *, ticket=None, tls_port=None):
    token = secrets.token_hex(16)
    ack = token.encode()
    verify_tls = ticket is not None and tls_port is not None
    payload = ack * 128
    servers = {}
    connected = set()
    received = set()
    passed = set()
    tls_ok = False
    done = asyncio.Event()
    bind_addresses = sorted({"::" if ip.version == 6 else "0.0.0.0" for ip in sources})

    async def exchange(reader, writer, port):
        nonlocal tls_ok
        try:
            remote = ipaddress.ip_address(writer.get_extra_info("peername")[0])
            if isinstance(remote, ipaddress.IPv6Address) and remote.ipv4_mapped:
                remote = remote.ipv4_mapped
            if remote not in sources:
                return
            connected.add(port)
            async with asyncio.timeout(TRANSFER_SECONDS):
                if await reader.readexactly(len(payload)) != payload:
                    return
                received.add(port)
                writer.write(payload)
                await writer.drain()
                if await reader.readexactly(len(ack)) != ack:
                    return
                if verify_tls:
                    status = await reader.readexactly(1)
                    if status not in (b"+", b"-"):
                        return
                    tls_ok = tls_ok or status == b"+"
                writer.write(b"+")
                await writer.drain()
            if port not in passed:
                passed.add(port)
                if ticket is None:
                    print(f"✓ {port}/tcp · обмен с {remote} прошёл", flush=True)
            if passed == servers.keys():
                done.set()
        except (OSError, TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    try:
        for port in ports:
            listeners = []
            try:
                for address in bind_addresses:
                    listeners.append(await asyncio.start_server(
                        lambda r, w, port=port: exchange(r, w, port), address, port, limit=len(payload)
                    ))
            except OSError as exc:
                for listener in listeners:
                    listener.close()
                await asyncio.gather(*(listener.wait_closed() for listener in listeners))
                if ticket is None:
                    print(f"× {port}/tcp · не удалось запустить тест: {exc.strerror}", flush=True)
            else:
                servers[port] = listeners
        if ticket is not None and (servers or tls_port is not None):
            request_panel(ticket, token, servers, tls_port)
        elif servers:
            args = shlex.join([host, token, *map(str, servers)])
            print(f"\nВыполните на сервере панели в течение {seconds} с (Ctrl+C — отмена):\n")
            print(f"python3 - {args} <<'REMNA_PROBE'\n{CLIENT}REMNA_PROBE", flush=True)
        if servers:
            try:
                await asyncio.wait_for(done.wait(), seconds)
            except TimeoutError:
                pass
        if ticket is not None:
            for port in ports:
                mark = "✓" if port in passed else "×"
                if port in passed:
                    status = "Данные прошли в обе стороны."
                elif port not in servers:
                    status = "Порт недоступен для теста."
                elif port in received:
                    status = "Запрос дошёл, ответ не подтверждён."
                elif port in connected:
                    status = "TCP открыт, данные дошли не полностью."
                else:
                    status = "Панель не подключилась."
                print(f"  {mark} {port:>5}/tcp · {status}")
        else:
            for port in servers:
                if port in passed:
                    continue
                if port in received:
                    reason = "запрос дошёл, получение ответа не подтверждено"
                elif port in connected:
                    reason = "TCP открыт, тестовые данные не дошли целиком"
                else:
                    reason = "нет подключения с разрешённого IP"
                print(f"× {port}/tcp · полный обмен не подтверждён: {reason}")
    finally:
        bound = [listener for listeners in servers.values() for listener in listeners]
        for server in bound:
            server.close()
        await asyncio.gather(*(server.wait_closed() for server in bound))
    return passed == set(ports) and (not verify_tls or not servers or tls_ok)


if __name__ == "__main__":
    arguments = sys.argv[1:]
    ticket = tls_port = None
    seconds = SECONDS
    if arguments[:1] == ["--launcher"]:
        _, ticket, tls, *arguments = arguments
        tls_port = int(tls) or None
        seconds = LAUNCHER_SECONDS
    destination, addresses, *numbers = arguments
    allowed = {ipaddress.ip_address(ip) for ip in addresses.split()}
    try:
        sys.exit(not asyncio.run(probe(destination, allowed, list(map(int, numbers)), seconds,
                                      ticket=ticket, tls_port=tls_port)))
    except KeyboardInterrupt:
        print("\nПроверка отменена.")
        sys.exit(1)
