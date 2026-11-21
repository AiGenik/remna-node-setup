import asyncio
import ipaddress
import secrets
import shlex
import sys


SECONDS = 90
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


async def probe(host, sources, ports, seconds=SECONDS):
    token = secrets.token_hex(16)
    ack = token.encode()
    payload = ack * 128
    servers = {}
    connected = set()
    received = set()
    passed = set()
    done = asyncio.Event()
    bind_addresses = sorted({"::" if ip.version == 6 else "0.0.0.0" for ip in sources})

    async def exchange(reader, writer, port):
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
                writer.write(b"+")
                await writer.drain()
            if port not in passed:
                print(f"✓ {port}/tcp · обмен с {remote} прошёл", flush=True)
                passed.add(port)
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
                print(f"× {port}/tcp · не удалось запустить тест: {exc.strerror}", flush=True)
            else:
                servers[port] = listeners
        if servers:
            args = shlex.join([host, token, *map(str, servers)])
            print(f"\nВыполните на сервере панели в течение {seconds} с (Ctrl+C — отмена):\n")
            print(f"python3 - {args} <<'REMNA_PROBE'\n{CLIENT}REMNA_PROBE", flush=True)
            try:
                await asyncio.wait_for(done.wait(), seconds)
            except TimeoutError:
                pass
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
    return passed == set(ports)


if __name__ == "__main__":
    destination, addresses, *numbers = sys.argv[1:]
    allowed = {ipaddress.ip_address(ip) for ip in addresses.split()}
    try:
        sys.exit(not asyncio.run(probe(destination, allowed, list(map(int, numbers)))))
    except KeyboardInterrupt:
        print("\nПроверка отменена.")
        sys.exit(1)
