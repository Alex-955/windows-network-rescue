"""Run the real .NET network probes against a local controlled HTTP server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import os
import shutil
import tempfile
import threading


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code = {"/ok": 200, "/redirect": 302}.get(self.path, 500)
        self.send_response(code)
        if code == 302:
            self.send_header("Location", "/ok")
        self.end_headers()
        self.wfile.write(b"test response")

    def log_message(self, *_):
        pass


powershell = os.environ.get("NET_RESCUE_POWERSHELL") or shutil.which("pwsh") or shutil.which("powershell")
if not powershell:
    raise SystemExit("PowerShell not found. Set NET_RESCUE_POWERSHELL to its executable path.")

root = Path(__file__).resolve().parents[1]
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
source = str(root / "Windows-Net-Rescue/NetRescue.ps1").replace("'", "''")
test = f"""
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile('{source}',[ref]$tokens,[ref]$errors)
if($errors.Count){{throw ($errors|Out-String)}}
foreach($f in $ast.FindAll({{param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}},$false)){{Invoke-Expression $f.Extent.Text}}
$ok=Web-Probe 'http://127.0.0.1:{port}/ok' $true
if(-not $ok.Healthy -or $ok.Code-ne 200){{throw 'HTTP 200 should be healthy'}}
$redirect=Web-Probe 'http://127.0.0.1:{port}/redirect' $true
if($redirect.Healthy -or -not $redirect.Success -or $redirect.Code-ne 302){{throw 'Redirect is a response, not proof of healthy Internet'}}
$errorResult=Web-Probe 'http://127.0.0.1:{port}/error' $true
if($errorResult.Healthy -or $errorResult.ErrorKind-ne 'ProtocolError'){{throw 'HTTP error should be classified as a protocol failure'}}
if(-not (Tcp-Probe '127.0.0.1' {port})){{throw 'Listening local TCP port must be reachable'}}
'PASS: Real HTTP 200, redirect, HTTP error classification, and TCP listener probes'
"""
try:
    with tempfile.TemporaryDirectory(prefix="net-rescue-probe-test-") as folder:
        script = Path(folder) / "test.ps1"
        script.write_text(test, encoding="utf-8-sig")
        subprocess.run(
            [powershell, "-NoLogo", "-NoProfile", "-File", str(script)],
            check=True,
            timeout=35,
        )
finally:
    server.shutdown()
    server.server_close()
