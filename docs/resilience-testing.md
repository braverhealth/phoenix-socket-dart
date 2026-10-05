# Resilience, interoperability and stress coverage

These suites run in native Dart and headless Chrome on Dart 3.4.4 and stable.
The protobuf suites also run with the minimum supported protobuf runtime (3.1).
The tests use bounded inputs and fixed seeds; a failure reports the seed, case
and input bytes. Xorshift32 has a fixed expected sequence so both runtimes use
the same corpus.

## Coverage

| Area | Checks per suite run |
|---|---|
| Phoenix framing | 12,000 randomized client/server frames; byte ownership, frame-view offsets and metadata preservation |
| Phoenix malformed input | 6,000 arbitrary frames up to 256 bytes; every metadata-prefix truncation in 300 generated replies |
| JSON payloads | 3,000 bounded recursive trees with Unicode, escapes, numeric and null values |
| MessagePack | 6,000 recursive trees across binary/base64; 6,000 arbitrary frames; full-envelope truncations and declared-length/depth limits |
| Protobuf | 6,000 arbitrary/mutated bodies; 3,000 routed Unicode messages; 10,000 control values that must bypass schema lookup |
| Concurrent routing | Two seeded runs of 1,024 outstanding requests across 16 channels, shuffled and duplicated replies, and interleaved broadcasts |
| Resource cleanup | 100 connection cycles settle and release 6,400 pending transport waiters; each owned transport closes once |
| Channel churn | 80 replacements settle 960 abandoned pushes and ignore late replies from older joins |

This is bounded regression coverage, not an exhaustive fuzzer or a proof that
the whole process cannot leak memory. Cleanup tests inspect retained pending
maps and transport-close counts rather than noisy heap or elapsed-time limits.
Protobuf runtimes reject invalid wire data with protocol/format errors and may
also use RangeError on the VM or ArgumentError in JavaScript. Application decoder
errors continue to propagate unchanged through the socket's error path.

## Independent wire vectors

Twenty-five checked-in vectors avoid validating only our encoder against our
decoder:

- Client Phoenix bytes and server decode results come from Phoenix's official
  [JavaScript serializer at v1.8.14](https://github.com/phoenixframework/phoenix/blob/v1.8.14/assets/js/phoenix/serializer.js).
- MessagePack bytes come from Python msgpack 1.2.3, including integer-width,
  string/array/binary-length boundaries and nested payloads.
- Protobuf bytes come from Google's Python runtime 6.33.6, using descriptors
  for the same test fields. Unknown fields must survive decode/re-encode.

The generated Dart fixture records producer versions and the Phoenix source
SHA-256. CI reads the checked-in fixture; it needs neither Python nor network
access to generate vectors.

To regenerate from the repository root:

```sh
python3 -m venv /tmp/phoenix-wire-fixtures
/tmp/phoenix-wire-fixtures/bin/pip install -r tool/wire_vectors_requirements.txt
/tmp/phoenix-wire-fixtures/bin/python tool/generate_wire_vectors.py
dart format packages/phoenix_socket/test/helpers/independent_wire_vectors.dart
```

## MessagePack input bounds

The dependency's decoder allocates arrays from declared lengths and reads from
the underlying buffer. Our preflight validates lengths against the actual
received view before allocation, rejects incomplete/trailing values, and limits
nesting to 64 containers including the envelope. Numeric and binary reads must
not escape a sliced frame into its surrounding backing buffer. No payload bytes
are copied by the preflight.

## Running the suites

```sh
cd packages/phoenix_socket
dart test test/codec_resilience_test.dart test/socket_stress_test.dart
dart test --platform chrome test/codec_resilience_test.dart test/socket_stress_test.dart
cd ../phoenix_socket_msgpack
dart test test/resilience_test.dart
dart test --platform chrome test/resilience_test.dart
cd ../phoenix_socket_protobuf
dart test test/resilience_test.dart
dart test --platform chrome test/resilience_test.dart
```

Real Phoenix backend E2E remains in CI. Braver's production protobuf schema and
server protocol are outside these fixture-based interoperability checks.
