#!/usr/bin/env python3
"""Extract H.264 NALUs from a standard rtptools .rtpdump file.

Usage: python dump_to_h264.py <input.rtpdump> [output.h264]

The input is a standard rtptools dump (text preamble + 16B RD_hdr_t + 8B
RD_packet_t records), interoperable with Wireshark / rtpplay. The output is a
raw Annex B H.264 bitstream that ffmpeg/ffprobe can read.
"""
import struct
import sys

FILE_HEADER_SIZE = 16    # RD_hdr_t
RECORD_HEADER_SIZE = 8   # RD_packet_t: length(u16) plen(u16) offset(u32), big-endian

def strip_rtp_header(pkt):
    """Strip RTP header (fixed + CSRC + extension + padding) → payload."""
    if len(pkt) < 12:
        return b''
    cc = pkt[0] & 0x0F
    has_ext = (pkt[0] & 0x10) != 0
    has_pad = (pkt[0] & 0x20) != 0
    off = 12 + cc * 4
    if has_ext:
        if off + 4 > len(pkt):
            return b''
        ext_len = (pkt[off + 2] << 8) | pkt[off + 3]
        off += 4 + ext_len * 4
    end = len(pkt)
    if has_pad and len(pkt) > 0:
        end -= pkt[-1]
    if off >= end:
        return b''
    return pkt[off:end]

def rtp_timestamp(pkt):
    return struct.unpack('>I', pkt[4:8])[0] if len(pkt) >= 8 else 0

def rtp_seq(pkt):
    return struct.unpack('>H', pkt[2:4])[0] if len(pkt) >= 4 else 0

START_CODE = b'\x00\x00\x00\x01'

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    infile = sys.argv[1]
    outfile = sys.argv[2] if len(sys.argv) > 2 else infile.rsplit('.', 1)[0] + '.h264'

    with open(infile, 'rb') as f:
        # Text preamble line: "#!rtpplay1.0 <ip>/<port>\n"
        preamble = f.readline()
        if not preamble.startswith(b'#!rtpplay'):
            print(f'Warning: unexpected preamble: {preamble!r}')
        # RD_hdr_t (16 bytes, big-endian) — informational only.
        hdr = f.read(FILE_HEADER_SIZE)
        if len(hdr) >= FILE_HEADER_SIZE:
            start_sec, start_usec, source, port, _pad = struct.unpack('>IIIHH', hdr)
            print(f'Start: {start_sec}.{start_usec:06d}  source: {source}  port: {port}')

        packets = []
        while True:
            rec_hdr = f.read(RECORD_HEADER_SIZE)
            if len(rec_hdr) < RECORD_HEADER_SIZE:
                break
            length, plen, offset_ms = struct.unpack('>HHI', rec_hdr)
            stored_len = length - RECORD_HEADER_SIZE if length >= RECORD_HEADER_SIZE else 0
            payload = f.read(stored_len)
            if len(payload) < stored_len:
                break
            packets.append((offset_ms, payload))

    print(f'Read {len(packets)} RTP packets')

    # Detect primary media PT (most common) and filter out RTX / padding-only
    pt_counts = {}
    for _, pkt in packets:
        if len(pkt) >= 2:
            pt = pkt[1] & 0x7F
            pt_counts[pt] = pt_counts.get(pt, 0) + 1
    if pt_counts:
        primary_pt = max(pt_counts, key=pt_counts.get)
        print(f'Payload type distribution: {dict(sorted(pt_counts.items()))}')
        print(f'Using primary PT={primary_pt}, filtering others as RTX/RTCP')
    else:
        primary_pt = None

    rtx_skipped = 0

    # Analyze
    fu_frag_count = 0
    nalu_count = 0
    stap_count = 0
    unknown_count = 0
    fu_buffer = bytearray()
    nalus = []

    for i, (ts_us, pkt) in enumerate(packets):
        payload = strip_rtp_header(pkt)
        seq = rtp_seq(pkt)
        rts = rtp_timestamp(pkt)
        pt = pkt[1] & 0x7F if len(pkt) >= 2 else -1
        if primary_pt is not None and pt != primary_pt:
            rtx_skipped += 1
            if i < 10:
                print(f'  pkt[{i}] SKIP PT={pt} (RTX/other)')
            continue

        if not payload:
            if i < 10:
                raw_hex = pkt[:min(32, len(pkt))].hex(' ')
                print(f'  pkt[{i}] EMPTY PAYLOAD  pkt_len={len(pkt)}')
                print(f'    raw: {raw_hex}')
            continue
        nal_type = payload[0] & 0x1F
        marker = (pkt[1] & 0x80) != 0

        if i < 10:
            raw_hex = pkt[:min(32, len(pkt))].hex(' ')
            pay_hex = payload[:min(16, len(payload))].hex(' ')
            print(f'  pkt[{i}] seq={seq} rtp_ts={rts} PT={pt} M={int(marker)} '
                  f'pkt_len={len(pkt)} payload_len={len(payload)} nal_type={nal_type}')
            print(f'    raw: {raw_hex}')
            print(f'    pay: {pay_hex}')

        if 1 <= nal_type <= 23:
            nalus.append((rts, payload))
            nalu_count += 1
        elif nal_type == 24:  # STAP-A
            off = 1
            while off + 2 <= len(payload):
                nlen = (payload[off] << 8) | payload[off + 1]
                off += 2
                if off + nlen > len(payload):
                    break
                nalus.append((rts, payload[off:off + nlen]))
                off += nlen
                stap_count += 1
        elif nal_type == 28:  # FU-A
            fu_indicator = payload[0]
            fu_header = payload[1]
            start = (fu_header & 0x80) != 0
            end = (fu_header & 0x40) != 0
            fu_nal_type = fu_header & 0x1F
            nri = fu_indicator & 0x60

            if start:
                fu_buffer = bytearray()
                fu_buffer.append(nri | fu_nal_type)
            fu_buffer.extend(payload[2:])
            fu_frag_count += 1

            if end:
                nalus.append((rts, bytes(fu_buffer)))
                fu_buffer = bytearray()
        else:
            unknown_count += 1

    print(f'Skipped {rtx_skipped} RTX/non-primary packets')
    print(f'Depacketized: {len(nalus)} NALUs '
          f'(single={nalu_count}, stap_a={stap_count}, '
          f'fu_a_frags={fu_frag_count}, unknown={unknown_count})')

    # Report NALU types
    type_counts = {}
    for _, nalu in nalus:
        nt = nalu[0] & 0x1F
        type_counts[nt] = type_counts.get(nt, 0) + 1
    print(f'NALU types: { {k: v for k, v in sorted(type_counts.items())} }')

    # Write Annex B
    with open(outfile, 'wb') as f:
        for _, nalu in nalus:
            f.write(START_CODE)
            f.write(nalu)

    print(f'Wrote {outfile} ({len(nalus)} NALUs)')

if __name__ == '__main__':
    main()
