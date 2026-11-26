import asyncio
import ipaddress
import json
import secrets
import shlex
import socket
import sys
import time


SECONDS = 90
LAUNCHER_SECONDS = 28
TRANSFER_SECONDS = 5

CLIENT = '''import socket
import sys

host, token, *ports = sys.argv[1:]
ack = token.encode()
payload = ack * 128
failed = False
for spec in ports:
    if spec.endswith("/udp"):
        port = int(spec[:-4])
        try:
            family = socket.AF_INET6 if ":" in host else socket.AF_INET
            with socket.socket(family, socket.SOCK_DGRAM) as conn:
                conn.settimeout(4)
                conn.sendto(payload, (host, port))
                data, _ = conn.recvfrom(len(payload) + 128)
                if data != payload:
                    raise OSError("неполный UDP-ответ")
            print(f"{port}/udp: обмен в обе стороны прошёл", flush=True)
        except OSError as exc:
            print(f"{port}/udp: {exc}", flush=True)
            failed = True
        continue
    port = int(spec[:-4] if spec.endswith("/tcp") else spec)
    try:
        with socket.create_connection((host, port), timeout=4) as conn:
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


def request_panel(ticket, token, ports, tls_port, udp_ports=(), busy_ports=()):
    request = {"ticket": ticket, "token": token, "ports": list(ports), "tls": tls_port}
    if udp_ports:
        request["udp"] = list(udp_ports)
    if busy_ports:
        request["busy"] = list(busy_ports)
    print("\x1e" + json.dumps(request, separators=(",", ":")) + "\x1f", end="", flush=True)


def check_outbound(ips, probe_ports=(443, 80, 22, 2222)):
    failed = False
    for raw in ips:
        addr = ipaddress.ip_address(raw)
        reachable = False
        elapsed_ms = None
        last_err = "таймаут"
        for port in probe_ports:
            started = time.monotonic()
            try:
                with socket.create_connection((str(addr), int(port)), timeout=2.5):
                    elapsed_ms = int((time.monotonic() - started) * 1000)
                    reachable = True
                    break
            except ConnectionRefusedError:
                elapsed_ms = int((time.monotonic() - started) * 1000)
                reachable = True
                break
            except TimeoutError:
                last_err = "таймаут (пакеты не возвращаются)"
            except OSError as exc:
                last_err = exc.strerror or str(exc)
        if reachable:
            print(f"  ✓ нода → {addr} · маршрут и отклик подтверждены ({elapsed_ms} мс)")
        else:
            print(f"  × нода → {addr} · IP панели не ответил ({last_err})")
            failed = True
    return not failed


async def probe(host, sources, ports, seconds=SECONDS, *, ticket=None, tls_port=None,
                udp_ports=(), busy_ports=()):
    token = secrets.token_hex(16)
    ack = token.encode()
    verify_tls = ticket is not None and tls_port is not None
    payload = ack * 128
    servers = {}
    udp_transports = {}
    connected = set()
    received = set()
    passed = set()
    udp_passed = set()
    tls_ok = False
    done = asyncio.Event()
    bind_addresses = sorted({"::" if ip.version == 6 else "0.0.0.0" for ip in sources})

    def maybe_done():
        if passed == set(servers) and udp_passed == set(udp_transports):
            done.set()

    class UdpEcho(asyncio.DatagramProtocol):
        def __init__(self, port):
            self.port = port
            self.transport = None

        def connection_made(self, transport):
            self.transport = transport

        def datagram_received(self, data, addr):
            try:
                remote = ipaddress.ip_address(addr[0])
                if isinstance(remote, ipaddress.IPv6Address) and remote.ipv4_mapped:
                    remote = remote.ipv4_mapped
                if remote not in sources or data != payload:
                    return
                self.transport.sendto(payload, addr)
                if self.port not in udp_passed:
                    udp_passed.add(self.port)
                    if ticket is None:
                        print(f"✓ {self.port}/udp · обмен с {remote} прошёл", flush=True)
                    maybe_done()
            except OSError:
                pass

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
            maybe_done()
        except (OSError, TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    try:
        loop = asyncio.get_running_loop()
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
        for port in udp_ports:
            transports = []
            try:
                for address in bind_addresses:
                    transport, _ = await loop.create_datagram_endpoint(
                        lambda port=port: UdpEcho(port), local_addr=(address, port)
                    )
                    transports.append(transport)
            except OSError as exc:
                for transport in transports:
                    transport.close()
                if ticket is None:
                    print(f"× {port}/udp · не удалось запустить тест: {exc.strerror}", flush=True)
            else:
                udp_transports[port] = transports
        if ticket is not None and (servers or udp_transports or tls_port is not None or busy_ports):
            request_panel(ticket, token, servers, tls_port, list(udp_transports), list(busy_ports))
        elif servers or udp_transports:
            targets = [*map(str, servers), *(f"{port}/udp" for port in udp_transports)]
            args = shlex.join([host, token, *targets])
            print(f"\nВыполните на сервере панели в течение {seconds} с (Ctrl+C — отмена):\n")
            print(f"python3 - {args} <<'REMNA_PROBE'\n{CLIENT}REMNA_PROBE", flush=True)
        if servers or udp_transports:
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
                    status = "Панель не подключилась (возможна блокировка порта или IP у провайдера)."
                print(f"  {mark} {port:>5}/tcp · {status}")
            for port in udp_ports:
                mark = "✓" if port in udp_passed else "×"
                if port in udp_passed:
                    status = "UDP-пакеты прошли в обе стороны."
                elif port not in udp_transports:
                    status = "UDP-порт недоступен для теста."
                else:
                    status = "UDP-ответ от панели не получен."
                print(f"  {mark} {port:>5}/udp · {status}")
            if busy_ports and not ports:
                print("  Итог по занятым TCP-портам показан в отчёте панели выше.")
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
            for port in udp_transports:
                if port in udp_passed:
                    continue
                print(f"× {port}/udp · UDP-обмен не подтверждён: нет пакетов с разрешённого IP")
    finally:
        bound = [listener for listeners in servers.values() for listener in listeners]
        for server in bound:
            server.close()
        await asyncio.gather(*(server.wait_closed() for server in bound))
        for transports in udp_transports.values():
            for transport in transports:
                transport.close()
    return (
        passed == set(ports)
        and udp_passed == set(udp_ports)
        and (not verify_tls or not servers or tls_ok)
    )


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if arguments[:1] == ["--outbound"]:
        sys.exit(not check_outbound(arguments[1:]))
    ticket = tls_port = None
    seconds = SECONDS
    udp_list = []
    busy_list = []
    if arguments[:1] == ["--launcher"]:
        _, ticket, tls, *arguments = arguments
        tls_port = int(tls) or None
        seconds = LAUNCHER_SECONDS
    cleaned = []
    index = 0
    while index < len(arguments):
        item = arguments[index]
        if item == "--udp" and index + 1 < len(arguments):
            udp_list = [int(p) for p in arguments[index + 1].split(",") if p]
            index += 2
        elif item == "--busy" and index + 1 < len(arguments):
            busy_list = [int(p) for p in arguments[index + 1].split(",") if p]
            index += 2
        else:
            cleaned.append(item)
            index += 1
    destination, addresses, *numbers = cleaned
    allowed = {ipaddress.ip_address(ip) for ip in addresses.split()}
    try:
        sys.exit(not asyncio.run(probe(
            destination, allowed, list(map(int, numbers)), seconds,
            ticket=ticket, tls_port=tls_port, udp_ports=udp_list, busy_ports=busy_list,
        )))
    except KeyboardInterrupt:
        print("\nПроверка отменена.")
        sys.exit(1)
