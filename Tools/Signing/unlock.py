from pathlib import Path
import subprocess
import sys

directory = Path(sys.argv[1])
password = (directory / "keychain-password.txt").read_text().strip()
result = subprocess.run(
    ["/usr/bin/security", "unlock-keychain", "-p", password,
     str(directory / "release-signing.keychain-db")],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
if result.returncode:
    raise SystemExit("无法解锁听桥签名钥匙串。")
