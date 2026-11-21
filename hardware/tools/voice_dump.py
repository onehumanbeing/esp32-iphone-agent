#!/usr/bin/env python3
"""StopWatch voice over USB serial, for tests without the app: holds yellow (`swpress`) for SECONDS, reads the
voice chunks the board prints as hex when no app is on Bluetooth, decodes the IMA ADPCM and writes a 16 kHz WAV.
Usage: uv run --with pyserial hardware/tools/voice_dump.py /dev/cu.usbmodemXXXX 3 out.wav"""
import struct, sys, time, wave

import serial

INDEX = [-1, -1, -1, -1, 2, 4, 6, 8] * 2
STEP = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
        24623, 27086, 29794, 32767]


def decode(pred, index, data):
    out = []
    for byte in data:
        for code in (byte & 15, byte >> 4):
            st = STEP[index]
            diff = st >> 3
            if code & 4: diff += st
            if code & 2: diff += st >> 1
            if code & 1: diff += st >> 2
            pred = max(-32768, min(32767, pred - diff if code & 8 else pred + diff))
            index = max(0, min(88, index + INDEX[code]))
            out.append(pred)
    return out


def main(port, seconds, path):
    s = serial.Serial(port, 115200, timeout=0.2)
    s.write(b'1 ui {"p":"standby","v":1}\n')
    time.sleep(0.3)
    s.write(f"2 swpress yellow {int(float(seconds) * 1000)}\n".encode())
    pcm, locale, seqs, end = [], None, [], time.time() + float(seconds) + 6
    while time.time() < end:
        line = s.readline().decode(errors="replace").strip()
        if not line.startswith("vchunk "):
            if line: print(line)
            continue
        b = bytes.fromhex(line[7:])
        seq, flags = struct.unpack_from("<HB", b)
        assert flags & 0xC0 == 0xC0, flags
        seqs.append(seq)
        if flags & 1: locale = b[3:].decode()
        elif flags & 2:
            end = min(end, time.time() + 1.5)  # the board's summary lines follow
        else:
            pred, index = struct.unpack_from("<hB", b, 3)
            pcm += decode(pred, index, b[6:])
    s.write(b"3 voice fail none\n")  # no app to transcribe: the board's "didn't catch that", then idle again
    gaps = sum(1 for a, b2 in zip(seqs, seqs[1:]) if (b2 - a) & 0xFFFF != 1)
    with wave.open(path, "wb") as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(16000)
        w.writeframes(struct.pack(f"<{len(pcm)}h", *pcm))
    print(f"locale {locale}, {len(seqs)} chunks, {gaps} gaps, {len(pcm) / 16000:.2f} s -> {path}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
