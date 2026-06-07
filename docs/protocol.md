# Protocol 1.0

TCP defaults to `127.0.0.1:9901`. Each UTF-8 JSON object ends in `\n`; the
maximum encoded message is 1 MiB. The first message is `hello` and the reply is
`hello_ack`. Post-handshake envelopes use `protocol: "rptk"`,
`protocol_major: 1`, and `type: request|response|event`. The normative shapes
are in `schemas/`.

Requests carry `request_id`, `method`, and object `payload`. Responses carry
the matching ID, `ok`, and `result` or structured `error`. Events carry
`event`, monotonically increasing `event_seq`, and `payload`.

The host caches identical requests by ID for at least the active session.
Reusing an ID with different content returns `request_id_conflict`.

UDP is discovered from `hello_ack`. Network-byte-order layouts:

```text
event: "RPTK" u8-major u8-type token[16] u32-generation u32-sequence
       f64-delay-seconds u8-status u8-data1 u8-data2
reset: "RPTK" u8-major u8-type token[16] u32-generation u32-sequence
```

Packet types are 1 event, 2 reset/all-notes-off, 3 probe, and 4 probe response.
The Python constants use `!4sBB16sIIdBBB` and `!4sBB16sII`.

