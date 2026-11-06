# Export measurements (lot 1.6.0)


Cause of large files: system "highest quality" preset (15–19 Mb/s at 4K30 regardless of content) + a key frame every 1 s (I-frames 51–61 % of the bytes in the user's files) + the medium tier writing 568×320.

Product path, 4K, 5 s key frames (Mb/s): H.264 q0.7 A 0.88 / B 2.06 / C 12.3; q0.8 A 1.58 / B 3.96 / C 24.3; q0.9 11.8 / 14.3 / 98; HEVC q0.8 1.52 / 2.62 / 14.5; old default 15–19 (C 42).
SSIM (A/B): q0.7 .9889/.9935, q0.8 .9917/.9966. Key-frame interval at q0.7 on A, same SSIM: 1 s 2.51, 2 s 1.43, 5 s 0.76, 10 s 0.52 Mb/s.
Average rate is honoured within 2–6 %; no multi-pass (canPerformMultiplePasses=false): size target is a one-pass estimate, 5–6 % under in tests. Constant quality gives a uniform look (worst-frame SSIM .987 at 1.4 Mb/s vs .957 for ABR at 2 Mb/s).
Time: H.264 4K ≈ 32 s per 60 s (old preset 34 s); HEVC 18–34 s; ~65 MB RSS.
