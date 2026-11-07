#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import struct

parser = argparse.ArgumentParser(description='Generate the KomixV2 byte vocabulary.')
parser.add_argument('vocab', type=pathlib.Path)
parser.add_argument('layout', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
args = parser.parse_args()
layout = args.layout.read_bytes()
n_mels, n_fft = struct.unpack_from('<2i', layout, 48)
offset = 56 + n_mels * n_fft * 4
vocab = json.loads(args.vocab.read_text(encoding='utf-8'))
values = list(range(33,127)) + list(range(161,173)) + list(range(174,256))
characters = values[:]
extra = 0
for value in range(256):
    if value not in values:
        values.append(value)
        characters.append(256+extra)
        extra += 1
byte_decoder = {chr(character): value for value,character in zip(values,characters)}
base = sorted(((text,index) for text,index in vocab.items() if index < 50257), key=lambda item:item[1])
if [index for _,index in base] != list(range(50257)):
    raise ValueError('Unexpected Whisper vocabulary IDs')
tokens = [bytes(byte_decoder[character] for character in text) for text,_ in base]
metadata = layout[:offset] + struct.pack('<i',len(tokens))
metadata += b''.join(struct.pack('<i',len(token))+token for token in tokens)
if hashlib.sha256(metadata).hexdigest() != '49639ac8580c3985225c05981ed17f85c8d193ebeaaab3bde2a0cddc38d2eb56':
    raise ValueError('Unexpected KomixV2 metadata')
args.output.write_bytes(metadata)
print(f'Generated {len(tokens)} byte tokens; {len(metadata)} bytes')
