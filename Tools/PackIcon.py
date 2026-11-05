import pathlib
import struct
import sys

source, output = map(pathlib.Path, sys.argv[1:])
chunks = []
for size, name in [(16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"), (256, b"ic08"), (512, b"ic09"), (1024, b"ic10")]:
    data = (source / f"{size}.png").read_bytes()
    chunks.append(name + struct.pack(">I", len(data) + 8) + data)
payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
