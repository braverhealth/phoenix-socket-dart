"""Generate small cross-language vectors; CI consumes the checked-in Dart data.

Run in a venv with wire_vectors_requirements.txt installed. Node and rtk are
needed to execute Phoenix's pinned official serializer. No backend is started.
"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import ssl
import urllib.request

import certifi
import msgpack
import google.protobuf
from google.protobuf import descriptor_pb2, descriptor_pool, message_factory

ROOT = Path(__file__).resolve().parent.parent
URL = "https://raw.githubusercontent.com/phoenixframework/phoenix/v1.8.14/assets/js/phoenix/serializer.js"
source = urllib.request.urlopen(URL, timeout=30,
    context=ssl.create_default_context(cafile=certifi.where())).read()
javascript = re.sub(r'import\s*\{\s*CHANNEL_EVENTS\s*\}\s*from\s*"\./constants"',
                    'const CHANNEL_EVENTS = {reply: "phx_reply"}', source.decode())
javascript = javascript.replace("export default {", "const serializer = {", 1)
javascript += """
const input = JSON.parse((await import('node:fs')).readFileSync(0, 'utf8'));
function body(value){return value instanceof ArrayBuffer ? {$bytes: Buffer.from(value).toString('hex')} : {status:value.status,response:body(value.response)}}
const clients = input.clients.map(m => ({...m, frame:Buffer.from(serializer.binaryEncode({...m,payload:Uint8Array.from(m.bytes).buffer})).toString('hex')}));
const servers = input.servers.map(m => {let d=serializer.binaryDecode(Uint8Array.from(m.bytes).buffer); return {name:m.name,frame:Buffer.from(m.bytes).toString('hex'),message:{join_ref:d.join_ref||null,ref:d.ref||null,topic:d.topic,event:d.event,payload:body(d.payload)}}});
console.log(JSON.stringify({clients,servers}));
"""

clients = [
    dict(name="ordinary", join_ref="1", ref="2", topic="room", event="echo", bytes=[0, 128, 255]),
    dict(name="unicode", join_ref="", ref="", topic="røom🙂", event="更新", bytes=[1, 2]),
    dict(name="empty", join_ref="", ref="", topic="room", event="empty", bytes=[]),
    dict(name="metadata-limit", join_ref="1", ref="2", topic="x" * 255, event="echo", bytes=[42]),
]
servers = []
for kind, fields, name in [(0, ["1", "røom🙂", "更新"], "push"),
                          (1, ["1", "2", "room", "error"], "reply"),
                          (2, ["room", "update"], "broadcast"),
                          (2, ["", ""], "empty")]:
    encoded = [field.encode() for field in fields]
    wire = bytes([kind] + [len(field) for field in encoded]) + b"".join(encoded)
    servers.append(dict(name=name, bytes=list(wire + (b"\x00\x80\xff" if name != "empty" else b""))))
phoenix = json.loads(subprocess.run(["rtk", "node", "--input-type=module", "-e", javascript],
                                  input=json.dumps(dict(clients=clients, servers=servers)),
                                  text=True, capture_output=True, check=True).stdout)

def portable(value):
    if isinstance(value, bytes):
        return {"$bytes": value.hex()}
    if isinstance(value, list):
        return [portable(item) for item in value]
    if isinstance(value, dict):
        return {key: portable(item) for key, item in value.items()}
    return value

messagepack = []
for name, payload in [
    ("nested", {"items": [None, True, False, {"text": "héllo🙂"}], "bytes": b"\x00\x80\xff"}),
    ("numbers", {"values": [-32769, -129, -33, -1, 0, 127, 128, 256, 65536, 3.25]}),
    ("str32", {"text": "x" * 32}),
    ("array16", list(range(16))),
    ("binary256", bytes(range(256))),
    ("empty-binary", b""),
    ("reply", {"status": "error", "response": b"\x00\xff"}),
]:
    parts = [None, "2", "røom", "phx_reply" if name == "reply" else "event", payload]
    messagepack.append(dict(name=name, frame=msgpack.packb(parts, use_bin_type=True).hex(), message=portable(parts)))

file = descriptor_pb2.FileDescriptorProto(name="vectors.proto", package="vectors", syntax="proto3")
for name, field, number in [("Reply", "text", 1), ("Update", "id", 2)]:
    message = file.message_type.add(name=name)
    message.field.add(name=field, number=number, type=descriptor_pb2.FieldDescriptorProto.TYPE_STRING,
                      label=descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL)
pool = descriptor_pool.DescriptorPool()
pool.Add(file)
protobuf = []
for schema, field in [("Reply", "text"), ("Update", "id")]:
    cls = message_factory.GetMessageClass(pool.FindMessageTypeByName("vectors." + schema))
    for name, value in [("empty", ""), ("unicode", "héllo🙂"), ("escaped", "quote\"\\\n\x00"), ("long", "λ" * 70)]:
        wire = cls(**{field: value}).SerializeToString()
        protobuf.append(dict(name=schema + "-" + name, schema=schema, value=value, frame=wire.hex()))
    wire = cls(**{field: "unknown preserved"}).SerializeToString() + bytes([0xf8, 0x07, 0xc1, 0x0d])
    assert getattr(cls.FromString(wire), field) == "unknown preserved"
    protobuf.append(dict(name=schema + "-unknown", schema=schema, value="unknown preserved", frame=wire.hex()))

vectors = dict(producer=dict(phoenix=URL, phoenix_sha256=hashlib.sha256(source).hexdigest(),
                             msgpack=msgpack.__version__, protobuf=google.protobuf.__version__),
               phoenix=phoenix, messagepack=messagepack, protobuf=protobuf)
target = ROOT / "packages/phoenix_socket/test/helpers/independent_wire_vectors.dart"
target.write_text("// Generated by tool/generate_wire_vectors.py; do not hand-edit.\n"
                  "const independentWireVectorsJson = r'''\n" + json.dumps(vectors, ensure_ascii=False, indent=2) + "\n''';\n")
print("Wrote", target)
