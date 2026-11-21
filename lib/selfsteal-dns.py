import ipaddress
import json
import socket
import subprocess
import sys


def addresses_text(addresses):
    return ", ".join(str(ip) for ip in sorted(addresses, key=lambda ip: (ip.version, ip.packed)))


def local_addresses():
    output = subprocess.check_output(["ip", "-j", "address", "show", "scope", "global"])
    return {
        ipaddress.ip_address(address["local"])
        for interface in json.loads(output)
        for address in interface.get("addr_info", [])
        if address.get("scope") == "global" and "local" in address
    }


def public_addresses():
    try:
        assigned = local_addresses()
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        sys.exit("Не удалось прочитать адреса VPS. Проверьте вывод ip -br address.")

    return {address for address in assigned if address.is_global}


def check_domain(domain, report):
    public = public_addresses()
    expected = addresses_text(public)
    try:
        records = socket.getaddrinfo(domain, None, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        if error.errno in (socket.EAI_NONAME, getattr(socket, "EAI_NODATA", None)):
            hint = f" Создайте A/AAAA на IP VPS — {expected}." if expected else ""
            sys.exit(f"DNS не находит {domain}.{hint}")
        sys.exit(f"DNS-сервер VPS не смог ответить для {domain}. Проверьте резолвер и повторите.")

    published = {ipaddress.ip_address(record[4][0]) for record in records}
    if not public:
        sys.exit("На интерфейсах VPS нет публичных адресов для прямой проверки HTTP-01.")
    if not published:
        sys.exit(f"Для {domain} нет A/AAAA. IP VPS — {expected}.")
    if not published.issubset(public):
        mismatch = addresses_text(published - public)
        sys.exit(
            f"{domain} указывает на {mismatch}. IP VPS — {expected}.\n"
            "Исправьте A/AAAA. Для Cloudflare включите DNS only."
        )
    if report:
        print(f"DNS в порядке. {domain} → {addresses_text(published)}.")


if __name__ == "__main__":
    if sys.argv[1] == "--public-ips":
        print(addresses_text(public_addresses()))
    else:
        check_domain(sys.argv[1], sys.argv[2] == "report")
