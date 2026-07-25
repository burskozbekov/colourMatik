"""ModFlows colour-transfer candidate (Larchenko et al., AAAI 2025).

An EfficientNet encoder looks at ONE image and predicts the weights of a tiny
rectified-flow MLP that transports that image's RGB distribution to a shared
latent distribution. A transfer is then: source flow FORWARD, reference flow
INVERSE — a pure position-independent RGB->RGB map, which means we can evaluate
it directly on the 65^3 lattice: the LUT bake is exact, not a distillation.

Weights: MIT-licensed checkpoints on HuggingFace (MariaLarchenko/
modflows_color_encoder), fetched lazily through huggingface_hub (already a
transformers dependency). This module is a clean-room reimplementation of the
thin inference math; graceful: any failure -> callers just lose one candidate.

Faithfulness notes (bug-compatible on purpose — the weights were TRAINED this
way): the encoder input is the frame resized to 528x528 then reshaped
(H,W,3)->(3,H,W) *without* transposing (the original repo's reshape), and the
torchvision EfficientNet preprocessing transform is applied on top.
"""
from __future__ import annotations
import threading
import numpy as np

_ENC = None            # cached (encoder_model, transforms, device) or False
_LOCK = threading.Lock()

_REPO = "MariaLarchenko/modflows_color_encoder"
_CKPT = "modflows_color_encoder_B6_dim_8195_iter_751001.pt"
_KDIM, _HIDDEN = 8195, 1024     # flow MLP: Linear(4,1024) -> tanh -> Linear(1024,3)
_INPUT = 528


def _load():
    global _ENC
    if _ENC is not None:
        return _ENC if _ENC is not False else None
    with _LOCK:
        if _ENC is not None:
            return _ENC if _ENC is not False else None
        try:
            import torch
            import torchvision
            from huggingface_hub import hf_hub_download
            path = hf_hub_download(_REPO, _CKPT)
            model = torchvision.models.efficientnet_b6(num_classes=_KDIM)
            tfm = torchvision.models.efficientnet.EfficientNet_B6_Weights.IMAGENET1K_V1.transforms()
            sd = torch.load(path, map_location="cpu")
            # original checkpoint keys are "model.*" (encoder wrapped the net)
            sd = { (k[6:] if k.startswith("model.") else k): v for k, v in sd.items() }
            model.load_state_dict(sd)
            device = "mps" if torch.backends.mps.is_available() else "cpu"
            model.to(device).eval()
            _ENC = (model, tfm, device)
        except Exception:
            _ENC = False
            return None
    return _ENC


def available() -> bool:
    return _load() is not None


def _encode_flow_weights(enc_img: np.ndarray):
    """enc_img: (H,W,3) float [0,1] -> flat (8195,) flow weights tensor."""
    import torch
    from PIL import Image
    model, tfm, device = _load()
    im = Image.fromarray((np.clip(enc_img, 0, 1) * 255 + 0.5).astype(np.uint8))
    im = im.resize((_INPUT, _INPUT))
    arr = np.asarray(im, dtype=np.float32) / 255.0
    x = torch.tensor(arr.reshape(3, _INPUT, _INPUT))     # bug-compatible reshape
    with torch.no_grad():
        x = tfm(x).unsqueeze(0).to(device)
        e = model(x).flatten().to("cpu")
    return e


class _Flow:
    """The tiny per-image flow MLP, weights set from the encoder's output."""

    def __init__(self, e, device):
        import torch
        h = _HIDDEN
        s = [0, 4 * h, 4 * h + h, 4 * h + h + 3 * h, 4 * h + h + 3 * h + 3]
        self.w1 = e[s[0]:s[1]].reshape(h, 4).to(device)
        self.b1 = e[s[1]:s[2]].reshape(h).to(device)
        self.w2 = e[s[2]:s[3]].reshape(3, h).to(device)
        self.b2 = e[s[3]:s[4]].reshape(3).to(device)
        self.device = device
        self.torch = torch

    def f(self, z, t):
        torch = self.torch
        zt = torch.cat([z, t], dim=1)
        return torch.tanh(zt @ self.w1.T + self.b1) @ self.w2.T + self.b2

    def forward_map(self, x, steps):
        torch = self.torch
        z = x.clone()
        dt = 1.0 / steps
        for i in range(steps):
            t = torch.full((z.shape[0], 1), i / steps, device=self.device)
            z = z + self.f(z, t) * dt
        return z

    def inverse_map(self, x, steps):
        torch = self.torch
        z = x.clone()
        dt = 1.0 / steps
        for i in range(steps):
            t = torch.full((z.shape[0], 1), 1.0 - i / steps, device=self.device)
            z = z - self.f(z, t) * dt
        return z


def modflows_lut(src_enc: np.ndarray, ref_enc: np.ndarray, size: int = 65,
                 steps: int = 8) -> np.ndarray | None:
    """Bake the src->ref ModFlows transfer straight onto a size^3 encoded LUT."""
    if _load() is None:
        return None
    try:
        import torch
        _, _, device = _load()
        e_src = _encode_flow_weights(src_enc)
        e_ref = _encode_flow_weights(ref_enc)
        f_src = _Flow(e_src, device)
        f_ref = _Flow(e_ref, device)
        ax = np.linspace(0.0, 1.0, size, dtype=np.float32)
        R, G, B = np.meshgrid(ax, ax, ax, indexing="ij")
        grid = torch.tensor(np.stack([R, G, B], -1).reshape(-1, 3), device=device)
        with torch.no_grad():
            latent = f_src.forward_map(grid, steps)
            out = f_ref.inverse_map(latent, steps)
        lut = out.to("cpu").numpy().astype(np.float64).reshape(size, size, size, 3)
        return np.clip(lut, 0.0, 1.0)
    except Exception:
        return None
