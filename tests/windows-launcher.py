from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]

STUB_CS = r'''
using System;
using System.Diagnostics;
using System.Text;

class Stub {
    static string Quote(string s) {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return s;
        var sb = new StringBuilder("\"");
        int bs = 0;
        foreach (char c in s) {
            if (c == '\\') { bs++; }
            else if (c == '"') {
                if (bs > 0) { sb.Append('\\', bs * 2); bs = 0; }
                sb.Append("\\\"");
            } else {
                if (bs > 0) { sb.Append('\\', bs); bs = 0; }
                sb.Append(c);
            }
        }
        if (bs > 0) sb.Append('\\', bs * 2);
        sb.Append('"');
        return sb.ToString();
    }

    static int Main(string[] args) {
        var psi = new ProcessStartInfo {
            FileName = Environment.GetEnvironmentVariable("REMNA_TEST_PY"),
            UseShellExecute = false
        };
        var sb = new StringBuilder();
        sb.Append(Quote(Environment.GetEnvironmentVariable("REMNA_TEST_STUB_PY")));
        foreach (string a in args) {
            sb.Append(' ').Append(Quote(a));
        }
        psi.Arguments = sb.ToString();
        using (var p = Process.Start(psi)) {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
'''

STUB_PY = r'''
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

args = sys.argv[1:]
posix_mode = os.environ.get("REMNA_TEST_POSIX_SSH") == "1"

if args[:1] == ["-G"]:
    if "-o" in args:
        opts = [args[i + 1] for i, a in enumerate(args) if a == "-o" and i + 1 < len(args)]
        if not posix_mode and any(o.startswith("ControlMaster=") for o in opts):
            sys.stderr.write('command-line line 0: Unsupported option "controlmaster"\n')
            sys.exit(255)
        sys.exit(0)
    sys.stdout.buffer.write(b"hostname 127.0.0.1\nport 22\n")
    sys.stdout.buffer.flush()
    sys.exit(0)

if os.environ.get("REMNA_TEST_PANEL_MODE") == "1":
    if "BatchMode=yes" in args and len(args) >= 2 and args[-2] == "panel-alias":
        assert "ClearAllForwardings=yes" in args and "ForwardAgent=no" in args, args
        if posix_mode:
            assert "ControlMaster=no" in args and "ControlPath=none" in args, args
        else:
            assert not any("ControlMaster" in a for a in args), args
        command = shlex.split(args[-1])
        assert command[:4] == ["python3", "-I", "-", "127.0.0.1"], command
        with open(os.environ["REMNA_PANEL_TRACE"], "a", encoding="utf-8") as trace:
            trace.write("panel\n")
        sys.exit(subprocess.call([sys.executable, *command[1:]]))
    else:
        assert args[-2] == "node-alias" and args[0] == "-tt", args
        assert "ForwardAgent=no" in args, args
        ticket = re.search(r"__ssh-menu ([a-f0-9]{32}) - 127\.0\.0\.1", args[-1]).group(1)
        sys.stdout.buffer.write("Меню ноды\n".encode("utf-8"))
        forged = json.dumps({"ticket": "0" * 32, "token": "1" * 32, "ports": [22], "tls": None})
        sys.stdout.buffer.write(b"\x1e" + forged.encode("utf-8") + b"\x1f")
        sys.stdout.buffer.flush()
        sys.exit(subprocess.call([
            sys.executable, os.environ["REMNA_PROBE"], "--launcher", ticket,
            os.environ["REMNA_TLS_PORT"], "127.0.0.1", "127.0.0.1", os.environ["REMNA_TEST_PORT"],
        ]))

assert "-tt" in args and "ForwardAgent=no" in args and "-p" in args and "2202" in args, args
if posix_mode:
    assert "ControlMaster=no" in args and "ControlPath=none" in args, args
else:
    assert not any("ControlMaster" in a for a in args), args

assert len(args) >= 2 and args[-2] == "root@test-vps", args
remote_cmd = args[-1]
assert "\r" not in remote_cmd, repr(remote_cmd)

trace_file = Path(os.environ["REMNA_TEST_TRACE"])
if os.environ.get("REMNA_TEST_TOOL_MISSING") == "1":
    assert "exit 127" in remote_cmd, remote_cmd
    sys.stderr.buffer.write("На VPS не найден Remna Node Setup. Сначала установите мастер по шагу 1 в README.\n".encode("utf-8"))
    sys.stderr.buffer.flush()
    sys.exit(127)

m = re.search(r"__ssh-menu ([a-f0-9]{32})(?: ([a-f0-9]{32}))?", remote_cmd)
assert m, remote_cmd
current, previous = m.group(1), m.group(2)
if not trace_file.exists():
    assert previous is None
    trace_file.write_text(current + "\n", encoding="utf-8")
    sys.exit(42)

first = trace_file.read_text(encoding="utf-8").splitlines()[0]
assert previous == first and current != previous, (previous, first, current)
with trace_file.open("a", encoding="utf-8") as fh:
    fh.write("confirmed\n")
sys.exit(int(os.environ.get("REMNA_TEST_SSH_RESULT", "0")))
'''


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


def find_csc():
    candidates = [
        Path(os.environ.get("WINDIR", r"C:\Windows")) / "Microsoft.NET" / "Framework64" / "v4.0.30319" / "csc.exe",
        Path(os.environ.get("WINDIR", r"C:\Windows")) / "Microsoft.NET" / "Framework" / "v4.0.30319" / "csc.exe",
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    return shutil.which("csc.exe")


def run_ps(shell_exe, ps_args, *, env=None, input_text=None, timeout=20):
    cmd = [shell_exe, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", *ps_args]
    return subprocess.run(cmd, env=env, input=input_text, capture_output=True, timeout=timeout)


def check_bom_and_ast(shell_exe):
    for name in ("i.ps1", "remna-ssh.ps1"):
        path = ROOT / name
        raw = path.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf"), f"{name} missing UTF-8 BOM"
        ast_check = (
            "$errs = $null; "
            f"[void][System.Management.Automation.Language.Parser]::ParseFile('{path}', [ref]$null, [ref]$errs); "
            "if ($errs.Count -gt 0) { $errs | ForEach-Object { [Console]::Error.WriteLine($_.ToString()) }; exit 1 }"
        )
        res = run_ps(shell_exe, ["-Command", ast_check])
        assert res.returncode == 0, (shell_exe, name, res.stderr.decode("utf-8", "replace"))


def test_installer(shell_exe, fixture):
    serve_dir = fixture / "serve"
    serve_dir.mkdir(exist_ok=True)
    ps1_dst = serve_dir / "remna-ssh.ps1"
    ps1_dst.write_bytes((ROOT / "remna-ssh.ps1").read_bytes())
    digest = hashlib.sha256(ps1_dst.read_bytes()).hexdigest()
    (serve_dir / "remna-ssh.ps1.sha256").write_text(f"{digest}  remna-ssh.ps1\n", encoding="utf-8")

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(serve_dir)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base_url = f"http://127.0.0.1:{server.server_port}"
        bin_dir = fixture / f"bin-{Path(shell_exe).stem}"
        env = {
            **os.environ,
            "REMNA_CLIENT_BIN_DIR": str(bin_dir),
            "REMNA_RELEASE_ASSETS_URL": base_url,
            "REMNA_CLIENT_NO_PATH": "1",
        }
        res = run_ps(shell_exe, ["-File", str(ROOT / "i.ps1"), "--client"], env=env)
        assert res.returncode == 0, (shell_exe, res.stdout, res.stderr)
        assert (bin_dir / "remna-ssh.ps1").read_bytes() == (ROOT / "remna-ssh.ps1").read_bytes()
        assert (bin_dir / "remna-ssh.cmd").is_file()
        assert (bin_dir / "rns.cmd").is_file()

        cmd_res = subprocess.run(["cmd.exe", "/c", str(bin_dir / "rns.cmd"), "--help"], capture_output=True, timeout=15)
        assert cmd_res.returncode == 0, cmd_res
        assert b"remna-ssh" in cmd_res.stdout

        # Simulate iex invocation (irm ... | iex style with --client)
        iex_bin = fixture / f"iex-{Path(shell_exe).stem}"
        iex_env = {**env, "REMNA_CLIENT_BIN_DIR": str(iex_bin), "REMNA_CLIENT_ONLY": "1"}
        i_text = (ROOT / "i.ps1").read_text(encoding="utf-8-sig")
        res_iex = run_ps(shell_exe, ["-Command", i_text], env=iex_env)
        assert res_iex.returncode == 0, (shell_exe, res_iex.stdout, res_iex.stderr)
        assert (iex_bin / "rns.cmd").is_file()

        # Tampered script must fail without overwriting installed file
        ps1_dst.write_bytes(ps1_dst.read_bytes() + b"\n# tampered\n")
        bad_res = run_ps(shell_exe, ["-File", str(ROOT / "i.ps1"), "--client"], env=env)
        assert bad_res.returncode != 0
        assert (bin_dir / "remna-ssh.ps1").read_bytes() == (ROOT / "remna-ssh.ps1").read_bytes()
    finally:
        server.shutdown()
        server.server_close()


def test_ssh_launcher(shell_exe, ssh_stub, stub_py, fixture):
    trace = fixture / f"trace-{Path(shell_exe).stem}"
    base_env = {
        **os.environ,
        "REMNA_SSH_BIN": ssh_stub,
        "REMNA_TEST_PY": sys.executable,
        "REMNA_TEST_STUB_PY": str(stub_py),
        "REMNA_TEST_TRACE": str(trace),
    }

    for posix_mode in ("0", "1"):
        if trace.exists():
            trace.unlink()
        env = {**base_env, "REMNA_TEST_POSIX_SSH": posix_mode}
        res = run_ps(shell_exe, ["-File", str(ROOT / "remna-ssh.ps1"), "--port", "2202", "root@test-vps"], env=env)
        assert res.returncode == 0, (shell_exe, posix_mode, res.stdout.decode("utf-8", "replace"), res.stderr.decode("utf-8", "replace"))
        assert "confirmed" in trace.read_text(encoding="utf-8").splitlines()

    if trace.exists():
        trace.unlink()
    res_fail = run_ps(
        shell_exe,
        ["-File", str(ROOT / "remna-ssh.ps1"), "--port", "2202", "root@test-vps"],
        env={**base_env, "REMNA_TEST_SSH_RESULT": "255"},
    )
    assert res_fail.returncode == 255
    assert "автооткат" in res_fail.stderr.decode("utf-8", "replace")

    res_missing = run_ps(
        shell_exe,
        ["-File", str(ROOT / "remna-ssh.ps1"), "--port", "2202", "root@test-vps"],
        env={**base_env, "REMNA_TEST_TOOL_MISSING": "1"},
    )
    assert res_missing.returncode == 127
    assert "Сначала установите мастер" in res_missing.stderr.decode("utf-8", "replace")

    res_bad_port = run_ps(shell_exe, ["-File", str(ROOT / "remna-ssh.ps1"), "--port", "66000", "root@test-vps"], env=base_env)
    assert res_bad_port.returncode == 2


def test_panel_relay(shell_exe, ssh_stub, stub_py, fixture):
    openssl = shutil.which("openssl") or r"C:\Program Files\Git\usr\bin\openssl.exe"
    assert Path(openssl).is_file(), "openssl not found for TLS fixture"
    cert, key = fixture / "cert.pem", fixture / "key.pem"
    if not cert.exists():
        subprocess.run(
            [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=remna-panel-test", "-keyout", str(key), "-out", str(cert)],
            check=True, capture_output=True, timeout=15,
        )

    trace = fixture / f"panel-trace-{Path(shell_exe).stem}"
    env = {
        **os.environ,
        "PYTHONIOENCODING": "utf-8",
        "REMNA_SSH_BIN": ssh_stub,
        "REMNA_TEST_PY": sys.executable,
        "REMNA_TEST_STUB_PY": str(stub_py),
        "REMNA_TEST_PANEL_MODE": "1",
        "REMNA_PROBE": str(ROOT / "lib" / "port-probe.py"),
        "REMNA_PANEL_TRACE": str(trace),
    }

    def run_panel(tls_port):
        return run_ps(
            shell_exe,
            ["-File", str(ROOT / "remna-ssh.ps1"), "--panel", "panel-alias", "node-alias"],
            env={**env, "REMNA_TEST_PORT": free_port(), "REMNA_TLS_PORT": tls_port},
            timeout=20,
        )

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(8)

        def serve_tls():
            conn, _ = listener.accept()
            with conn, context.wrap_socket(conn, server_side=True):
                pass

        t = threading.Thread(target=serve_tls, daemon=True)
        t.start()
        passed = run_panel(str(listener.getsockname()[1]))
        t.join(timeout=8)
        assert not t.is_alive()

    assert passed.returncode == 0, (shell_exe, passed.stdout.decode("utf-8", "replace"), passed.stderr.decode("utf-8", "replace"))
    success = passed.stdout.decode("utf-8")
    assert "\r  Проверка с панели panel-alias\r\n" in success, repr(success)
    assert "TLS отвечает.\r\n" in success and "✓" in success
    assert success.count("Данные прошли в обе стороны.") == 1
    assert "\x1e" not in success and "REMNA_PROBE" not in success
    assert trace.read_text(encoding="utf-8") == "panel\n"

    with socket.socket() as closed_tls:
        closed_tls.bind(("127.0.0.1", 0))
        failed = run_panel(str(closed_tls.getsockname()[1]))
    assert failed.returncode == 1
    failure = failed.stdout.decode("utf-8")
    assert "×" in failure
    assert any(msg + "\r\n" in failure for msg in ("Подключение отклонено.", "Панель не дождалась подключения.")), failure
    assert failure.count("Данные прошли в обе стороны.") == 1

    with socket.socket() as stalled_tls:
        stalled_tls.bind(("127.0.0.1", 0))
        stalled_tls.listen()
        stalled_tls.settimeout(8)

        def wait_close():
            conn, _ = stalled_tls.accept()
            with conn:
                conn.settimeout(8)
                while conn.recv(4096):
                    pass

        t = threading.Thread(target=wait_close, daemon=True)
        t.start()
        stalled = run_panel(str(stalled_tls.getsockname()[1]))
        t.join(timeout=8)
        assert not t.is_alive()
    assert stalled.returncode == 1
    assert "TCP открыт, TLS не ответил вовремя.\r\n" in stalled.stdout.decode("utf-8")


def test_real_win32_openssh_and_helpers(shell_exe, fixture):
    win_ssh = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "OpenSSH" / "ssh.exe"
    if not win_ssh.is_file():
        return
    # Extract function definitions only (exclude final 2 invocation lines)
    lines = (ROOT / "remna-ssh.ps1").read_text(encoding="utf-8-sig").splitlines()
    lib_ps1 = fixture / "remna-lib.ps1"
    lib_ps1.write_text("\n".join(lines[:-2]) + "\n", encoding="utf-8-sig")

    fake_home = fixture / "home"
    (fake_home / ".ssh").mkdir(parents=True, exist_ok=True)
    (fake_home / ".ssh" / "config").write_text(
        "Host panel-tw my-node # comment\n  HostName 203.0.113.10\nHost *.example.com\nHost=my-node2\n",
        encoding="utf-8",
    )

    script = f'''
. '{lib_ps1}'
$opts = Get-SupportedSshSecurityOptions '{win_ssh}'
if (($opts -join ' ') -match 'ControlMaster') {{ throw 'ControlMaster should be omitted for Win32-OpenSSH' }}
if (($opts -join ' ') -notmatch 'ForwardAgent=no') {{ throw 'ForwardAgent=no missing' }}
$aliases = Get-SshConfigAliases '{fake_home}'
if (($aliases -join ',') -cne 'panel-tw,my-node,my-node2') {{ throw ("Bad aliases: " + ($aliases -join ',')) }}
Save-PanelChoice '{fake_home}' 'panel-tw'
if ((Get-SavedPanel '{fake_home}') -cne 'panel-tw') {{ throw 'Saved panel mismatch' }}
$q = Format-Win32Arg 'a "b" c\\'
if ($q -cne '"a \\"b\\" c\\\\"') {{ throw ("Bad quote: " + $q) }}
'''
    res = run_ps(shell_exe, ["-Command", script])
    assert res.returncode == 0, (shell_exe, res.stdout.decode("utf-8", "replace"), res.stderr.decode("utf-8", "replace"))


def main():
    if sys.platform != "win32":
        print("Windows launcher tests require Windows (skipping on non-Windows host).")
        return

    shells = []
    for candidate in ("powershell.exe", "pwsh.exe"):
        found = shutil.which(candidate)
        if found:
            shells.append(found)
    assert shells, "No PowerShell executable found"

    csc = find_csc()
    assert csc, "csc.exe not found"

    with tempfile.TemporaryDirectory() as tmp:
        fixture = Path(tmp)
        cs_path = fixture / "Stub.cs"
        exe_path = fixture / "ssh.exe"
        stub_py = fixture / "stub.py"
        cs_path.write_text(STUB_CS, encoding="utf-8")
        stub_py.write_text(STUB_PY, encoding="utf-8")
        subprocess.run([csc, "/nologo", f"/out:{exe_path}", str(cs_path)], check=True, capture_output=True, timeout=20)

        for shell in shells:
            check_bom_and_ast(shell)
            test_installer(shell, fixture)
            test_ssh_launcher(shell, str(exe_path), stub_py, fixture)
            test_panel_relay(shell, str(exe_path), stub_py, fixture)
            test_real_win32_openssh_and_helpers(shell, fixture)

    print(f"Windows launcher tests passed on {', '.join(Path(s).name for s in shells)}.")


if __name__ == "__main__":
    main()
