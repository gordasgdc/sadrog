# Export measurements (lot 1.6.0)


Cause of large files: system "highest quality" preset (15–19 Mb/s at 4K30 regardless of content) + a key frame every 1 s (I-frames 51–61 % of the bytes in the user's files) + the medium tier writing 568×320.

Product path, 4K, 5 s key frames (Mb/s): H.264 q0.7 A 0.88 / B 2.06 / C 12.3; q0.8 A 1.58 / B 3.96 / C 24.3; q0.9 11.8 / 14.3 / 98; HEVC q0.8 1.52 / 2.62 / 14.5; old default 15–19 (C 42).
SSIM (A/B): q0.7 .9889/.9935, q0.8 .9917/.9966. Key-frame interval at q0.7 on A, same SSIM: 1 s 2.51, 2 s 1.43, 5 s 0.76, 10 s 0.52 Mb/s.
Average rate is honoured within 2–6 %; no multi-pass (canPerformMultiplePasses=false): size target is a one-pass estimate, 5–6 % under in tests. Constant quality gives a uniform look (worst-frame SSIM .987 at 1.4 Mb/s vs .957 for ABR at 2 Mb/s).
Time: H.264 4K ≈ 32 s per 60 s (old preset 34 s); HEVC 18–34 s; ~65 MB RSS.

## Lot 1.7.0 — one slice, every preset (2026-11-12)

Same 60 s slice (t = 280 s) of a 1920×1080, 30 fps screen-and-camera tutorial that was itself exported by another editor (H.264 Main, ≈ 4.0 Mb/s video, AAC 44.1 kHz); all SADROG runs at the document size and rate, product path, hardware encoder required and confirmed. Raw evidence: /Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/benchmarks/export_compare_2026-11-12 (probe.log, measure.txt).

| run | MB | Mb/s | SSIM vs source | time |
|---|---|---|---|---|
| reference slice (stream copy of the other editor's file) | 35.57 | 4.74 | — | — |
| Tutorial (H.264, quality High, 5 s keys, MP4) | 6.30 | 0.84 | 0.9974 | 8.9 s |
| HEVC compact | 4.11 | 0.55 | 0.9956 | 8.7 s |
| H.264 Balanced / Compact | 4.75 / 3.83 | 0.63 / 0.51 | 0.9954 / 0.9912 | 8.7 s |
| Maximum quality (.mov) | 15.48 | 2.06 | 0.9987 | 8.7 s |
| average 3 Mb/s requested | 9.94 | 1.33 | 0.9980 | 9.1 s |
| 16 Mb/s + key frame every 1 s (the pre-1.6.0 behaviour) | 29.60 | 3.95 | 0.9987 | 9.2 s |

Sound: 0.0 ms offset against the source decoded by CoreAudio (ffmpeg shows 47.9 ms on the same files = the 2112-sample AAC priming of the SOURCE, read differently by the two decoders; not introduced by the export).
Limits: the source was already compressed (a re-encode, so SSIM is against a lossy original); one content type; the encoder under-spends an average-rate request on static content (3 Mb/s asked, 1.33 written).
Person background cost (1280×720, 30 fps, 12 s synthetic clip): off 1.0 s (11.5×), blur 5.8 s (2.1×), remove 4.5 s (2.7×).
