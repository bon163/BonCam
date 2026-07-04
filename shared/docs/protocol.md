# Streaming Protocol

## Transport

- TCP control channel on port `41000`
- UDP video channel on port `41001`
- JSON messages framed as newline-delimited UTF-8 on the control channel
- H.264 Annex B NAL units inside UDP datagrams on the video channel

## Session flow

1. Phone discovers or is configured with the host address.
2. Phone opens TCP control connection.
3. Host sends `PairCodeRequired` if the phone is unknown.
4. Phone sends `PairRequest`.
5. Host replies with `PairConfirm`.
6. Host sends `StartStream`.
7. Phone begins H.264 frame delivery over UDP.

## Reliability

- Each video packet includes `frame_id`, `packet_index`, `packet_count`, and `timestamp_us`.
- Host can send `RequestKeyframe` when packet loss or decoder desync is detected.
- Phone emits `StatusEvent` for battery, thermal, lock, and background state.

## Versioning

- All control messages include `protocol_version`.
- Incompatible versions must fail pairing with a descriptive error.
