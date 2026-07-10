"""Image + video frame I/O. Video frames come out via ffmpeg (already on the system)."""
from __future__ import annotations
import subprocess
import tempfile
from pathlib import Path
import numpy as np
import imageio.v3 as iio

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}
VIDEO_EXTS = {".mov", ".mp4", ".mxf", ".m4v", ".avi", ".mkv", ".mts", ".braw"}


def load_image(path: str | Path) -> np.ndarray:
    """Load an image as display-encoded float RGB in [0,1], shape (H,W,3)."""
    try:
        arr = iio.imread(path)
    except Exception as e:
        name = Path(path).name
        raise ValueError(
            f"Couldn't read '{name}' as a video/image. Pick a plain video or still "
            f"clip — After Effects comps (.aep), nested sequences, titles/graphics and "
            f"offline clips can't be sampled directly."
        ) from e
    while arr.ndim > 3:              # animated PNG/GIF -> (N,H,W,C); take the first frame
        arr = arr[0]
    if arr.dtype == np.uint8:
        arr = arr.astype(np.float64) / 255.0
    elif arr.dtype == np.uint16:
        arr = arr.astype(np.float64) / 65535.0
    else:
        arr = arr.astype(np.float64)
    if arr.ndim == 2:                       # grayscale (H,W)
        arr = np.stack([arr] * 3, axis=-1)
    elif arr.shape[-1] == 1:                # single channel with axis (H,W,1)
        arr = np.repeat(arr, 3, axis=-1)
    elif arr.shape[-1] == 2:               # grayscale + alpha, Pillow "LA" (H,W,2)
        arr = np.repeat(arr[..., :1], 3, axis=-1)
    return np.ascontiguousarray(arr[..., :3])  # RGB / RGBA -> RGB


def save_image(path: str | Path, enc: np.ndarray) -> None:
    a = np.clip(enc, 0.0, 1.0)
    iio.imwrite(path, (a * 255.0 + 0.5).astype(np.uint8))


def _probe_duration(video: str | Path) -> float | None:
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nk=1:nw=1", str(video)],   # nw = noprint_wrappers (np is invalid)
            capture_output=True, text=True, check=True,
        )
        return float(out.stdout.strip())
    except Exception:
        return None


def extract_frame(video: str | Path, t: float | None = None) -> np.ndarray:
    """Extract one representative frame (default: middle) as encoded float RGB."""
    dur = _probe_duration(video)
    if t is None:
        t = (dur / 2.0) if dur else 0.5
    elif dur:
        t = max(0.0, min(float(t), dur - 1e-3))    # clamp a user time into the clip
    else:
        t = max(0.0, float(t))
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "frame.png"
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{t:.3f}",
                 "-i", str(video), "-frames:v", "1", str(out)],
                check=True,
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            raise ValueError(
                f"Couldn't extract a frame from '{Path(video).name}' — the clip may be "
                f"corrupt, an unsupported codec, or offline."
            ) from e
        if not out.exists():                 # fast-seek past EOF writes nothing
            raise ValueError(
                f"Couldn't read a frame from '{Path(video).name}' at {t:.2f}s "
                f"(is the requested time past the end of the clip?)."
            )
        return load_image(out)


def extract_frames(video: str | Path, n: int = 3) -> np.ndarray:
    """Extract `n` frames spread across the clip and stack them vertically.

    Pooling several frames gives a more representative colour distribution than a
    single frame (motion, exposure drift). Frames are stacked in the SAME temporal
    order for both clips, so pixel correspondence is preserved for aligned shots."""
    if n <= 1:
        return extract_frame(video)
    dur = _probe_duration(video)
    if not dur:
        return extract_frame(video)
    # sample at interior points, avoiding the very first/last frame
    times = [dur * (i + 1) / (n + 1) for i in range(n)]
    frames = [extract_frame(video, t) for t in times]
    h = min(f.shape[0] for f in frames)
    w = min(f.shape[1] for f in frames)
    frames = [f[:h, :w] for f in frames]
    return np.concatenate(frames, axis=0)


def load_any(path: str | Path, t: float | None = None, frames: int = 1) -> np.ndarray:
    """Load an image, or extract frame(s) from a video, into encoded float RGB."""
    ext = Path(path).suffix.lower()
    if ext in VIDEO_EXTS:
        if t is not None or frames <= 1:
            return extract_frame(path, t)
        return extract_frames(path, frames)
    return load_image(path)
