# Synthetic backup video

`black-2s.mp4` contains four generated black frames at two frames per second. It lets the backup
matcher read a known two-second duration through AVFoundation, without a real Photos library or a
runtime dependency on FFmpeg.

Generated with FFmpeg 9.0.1 and libx264:

```sh
ffmpeg -hide_banner -loglevel error -n -f lavfi -i 'color=c=black:s=16x16:r=2' \
  -frames:v 4 -c:v libx264 -pix_fmt yuv420p -threads 1 -fflags +bitexact \
  -flags:v +bitexact -map_metadata -1 -movflags +faststart black-2s.mp4
```

SHA-256: `78e1057ba7b5cce9c8172bb46e54f0ff231ff7941453da6ee652130a70127ffd`.
