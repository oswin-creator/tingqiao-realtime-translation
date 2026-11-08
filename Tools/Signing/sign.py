from pathlib import Path
import shlex
import subprocess
import sys

identity, keychain, application = sys.argv[1:4]
application = Path(application)
options = ["--force", "--sign", identity]
previous = None
if keychain:
    keychain = str(Path(keychain).resolve())
    options += ["--keychain", keychain]
    previous = shlex.split(subprocess.check_output(
        ["/usr/bin/security", "list-keychains", "-d", "user"], text=True))
    subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s",
                    keychain, *[p for p in previous if p != keychain]], check=True)
try:
    for name in ("TingQiaoWhisper", "TingQiaoUpdater", "TingQiaoQwen", "libTingQiaoVAD.dylib"):
        subprocess.run(["/usr/bin/codesign", *options,
                        str(application / "Contents/MacOS" / name)], check=True)
    subprocess.run(["/usr/bin/codesign", *options, "--deep", "--identifier",
                    "cn.tingqiao.bridge", str(application)], check=True)
finally:
    if previous is not None:
        subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s",
                        *previous], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)], check=True)
