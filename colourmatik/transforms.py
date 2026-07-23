"""Colour-matching transforms. Every transform is a function f: linear_rgb -> linear_rgb.

Two families:
  * Correspondence-based (fit_linear / fit_polynomial): most accurate when the two
    shots share content (same subject / aligned frames / colour chart). Solves the
    exact map from paired source->target pixels via least squares.
  * Distribution-based (fit_mkl): for different scenes with no correspondence.
    Monge-Kantorovich linear map — matches mean + covariance, smooth, artifact-free.
"""
from __future__ import annotations
from itertools import combinations_with_replacement
import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla


# ---------------------------------------------------------------- helpers
def _sqrtm_sym(M: np.ndarray, inverse: bool = False, eps: float = 1e-10) -> np.ndarray:
    """Symmetric (inverse) square root of a symmetric PSD matrix via eigendecomp.

    Eigenvalues are floored RELATIVE to the spectrum (not an absolute 1e-10), so a
    degenerate direction — a flat frame or a crushed/constant colour channel —
    yields a bounded transfer instead of exploding by ~1e5 along that eigenvector."""
    w, V = np.linalg.eigh(M)
    floor = max(eps, 1e-6 * float(w.max()) if w.size else eps)
    w = np.clip(w, floor, None)
    s = 1.0 / np.sqrt(w) if inverse else np.sqrt(w)
    return (V * s) @ V.T


def _poly_features(x: np.ndarray, degree: int) -> np.ndarray:
    """Monomial features up to `degree` for 3-channel input x (N,3), incl. bias."""
    n = x.shape[0]
    feats = [np.ones(n)]
    for d in range(1, degree + 1):
        for combo in combinations_with_replacement((0, 1, 2), d):
            term = np.ones(n)
            for c in combo:
                term = term * x[:, c]
            feats.append(term)
    return np.stack(feats, axis=1)


# ---------------------------------------------------------------- correspondence
def fit_linear(src_lin: np.ndarray, tgt_lin: np.ndarray, ridge: float = 1e-6):
    """Affine 3x3 + offset. Recovers any linear camera difference (gain/WB/primaries)."""
    return fit_polynomial(src_lin, tgt_lin, degree=1, ridge=ridge)


def fit_polynomial(src_lin: np.ndarray, tgt_lin: np.ndarray, degree: int = 3,
                   ridge: float = 1e-4, weights: np.ndarray | None = None):
    """(Weighted) ridge polynomial regression src->tgt (requires correspondence)."""
    Phi = _poly_features(src_lin, degree)
    if weights is not None:
        sw = np.sqrt(weights)[:, None]
        Phi = Phi * sw
        tgt_lin = tgt_lin * sw
    A = Phi.T @ Phi + ridge * np.eye(Phi.shape[1])
    B = Phi.T @ tgt_lin
    W = np.linalg.solve(A, B)  # (F, 3)

    def f(x: np.ndarray) -> np.ndarray:
        return _poly_features(np.atleast_2d(x), degree) @ W

    f.kind = f"poly{degree}"  # type: ignore[attr-defined]
    return f


# ---------------------------------------------------------------- distribution
def fit_mkl(src_lin: np.ndarray, tgt_lin: np.ndarray):
    """Monge-Kantorovich linear transfer (no correspondence needed).

    Maps the source Gaussian (mu_s, Sigma_s) onto the target (mu_t, Sigma_t):
        x -> T (x - mu_s) + mu_t,  with
        T = Ss^-1/2 ( Ss^1/2 St Ss^1/2 )^1/2 Ss^-1/2   (Pitie & Kokaram 2007)
    """
    mu_s = src_lin.mean(0)
    mu_t = tgt_lin.mean(0)
    Ss = np.cov(src_lin.T)
    St = np.cov(tgt_lin.T)
    Ss_half = _sqrtm_sym(Ss)
    Ss_ihalf = _sqrtm_sym(Ss, inverse=True)
    mid = _sqrtm_sym(Ss_half @ St @ Ss_half)
    T = Ss_ihalf @ mid @ Ss_ihalf
    # Bound the transfer's gain. When the source has almost no variance along some
    # axis (a green screen, a flat wall, a single-colour frame), Sigma_s^-1/2 blows
    # up along it and T reaches gains of 40x+ — every pixel is catapulted out of
    # gamut and the baked LUT clamps to the cube corners (the observed all-magenta
    # slot). Real grades measure around 1.2x per axis; 4x is already an extreme
    # look, so cap T's eigenvalues there. The mean shift (mu_s -> mu_t) is
    # untouched, so a degenerate source still gets a sane, bounded look.
    T = 0.5 * (T + T.T)
    w, V = np.linalg.eigh(T)
    T = (V * np.clip(w, 0.0, 4.0)) @ V.T

    def f(x: np.ndarray) -> np.ndarray:
        x = np.atleast_2d(x)
        return (x - mu_s) @ T.T + mu_t

    f.kind = "mkl"  # type: ignore[attr-defined]
    return f


def fit_sep(src_lin: np.ndarray, tgt_lin: np.ndarray):
    """Separated transfer: per-channel 1D quantile curves, then a capped-MKL 3D
    residual — composed into one transform.

    The 1D stage absorbs exposure, white balance, and contrast (each channel's
    marginal distribution is matched with a monotone curve); the 3D stage only
    has to fix what 1D cannot — cross-channel hue/saturation mixing — so it stays
    small and stable. SepLUT (ECCV 2022) measured this 1D-then-3D split beating a
    single coupled 3D map; it also mirrors how hardware ISPs are built.
    """
    qs = np.linspace(0.01, 0.99, 33)
    curves = []
    for c in range(3):
        xq = np.quantile(src_lin[:, c], qs)
        yq = np.quantile(tgt_lin[:, c], qs)
        xq = np.maximum.accumulate(xq) + np.arange(33) * 1e-9  # strictly increasing
        yq = np.maximum.accumulate(yq)
        # linear extension beyond the observed range, with SANE slopes (a curve
        # fitted on 1..99% quantiles says nothing about far highlights; an
        # unbounded edge slope would re-create the extrapolation blow-up)
        lo_m = np.clip((yq[1] - yq[0]) / max(xq[1] - xq[0], 1e-9), 0.0, 6.0)
        hi_m = np.clip((yq[-1] - yq[-2]) / max(xq[-1] - xq[-2], 1e-9), 0.0, 6.0)
        curves.append((xq, yq, lo_m, hi_m))

    def apply_curves(x):
        out = np.empty_like(x)
        for c in range(3):
            xq, yq, lo_m, hi_m = curves[c]
            v = np.interp(x[:, c], xq, yq)
            below = x[:, c] < xq[0]
            above = x[:, c] > xq[-1]
            v[below] = yq[0] + (x[below, c] - xq[0]) * lo_m
            v[above] = yq[-1] + (x[above, c] - xq[-1]) * hi_m
            out[:, c] = v
        return out

    resid = fit_mkl(apply_curves(src_lin), tgt_lin)   # capped, see fit_mkl

    def f(x: np.ndarray) -> np.ndarray:
        return resid(apply_curves(np.atleast_2d(x)))

    f.kind = "sep"  # type: ignore[attr-defined]
    return f


def fit_uot(src_pts: np.ndarray, tgt_pts: np.ndarray, blur: float = 0.05,
            reach: float = 0.4) -> np.ndarray:
    """Unbalanced Sinkhorn transport of `src_pts` toward `tgt_pts` (linear RGB).

    Pitié's IDT matches distributions EXACTLY, mass for mass — so when the
    reference has, say, a huge blue sky and the target has little of it, exact
    matching forcibly paints something else sky-blue. Relaxing mass conservation
    (`reach`) lets modes shift without being conserved, and the entropic `blur`
    keeps the map smooth (the OT literature's fix for grain/quantisation
    artifacts of raw transport maps). One Sinkhorn gradient step is the
    documented GeomLoss colour-transfer recipe. Requires torch+geomloss (the AI
    extras); callers treat ImportError as 'candidate unavailable'.
    """
    import torch
    from geomloss import SamplesLoss
    x = torch.tensor(src_pts, dtype=torch.float32, requires_grad=True)
    y = torch.tensor(tgt_pts, dtype=torch.float32)
    # backend="tensorized": pure torch, runs everywhere. The faster "online"
    # backend needs pykeops, which compiles C++ on the user's machine — a
    # non-starter for a shipped tool. Tensorized is O(N*M) memory, so callers
    # keep N,M at a few thousand points (plenty for a 3D colour distribution).
    loss = SamplesLoss("sinkhorn", p=2, blur=blur, reach=reach, scaling=0.8,
                       backend="tensorized")
    L = loss(x, y)
    (g,) = torch.autograd.grad(L, [x])
    # uniform weights 1/N -> Brenier displacement is -N * grad
    out = (x - float(len(src_pts)) * g).detach().cpu().numpy()
    return np.clip(out.astype(np.float64), 0.0, None)


def _rand_rotation(d: int, rng) -> np.ndarray:
    Q, R = np.linalg.qr(rng.normal(size=(d, d)))
    return Q * np.sign(np.diag(R))


def _match_marginal(s: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Map values `s` so their 1D distribution matches `t` (CDF / quantile match)."""
    n = len(s)
    ranks = np.empty(n)
    ranks[np.argsort(s)] = np.arange(n)
    q = ranks / max(n - 1, 1)
    ts = np.sort(t)
    return np.interp(q, np.linspace(0.0, 1.0, len(ts)), ts)


def fit_idt(src: np.ndarray, tgt: np.ndarray, n_iter: int = 24, seed: int = 0) -> np.ndarray:
    """Iterative Distribution Transfer (Pitié): transport `src` samples so their FULL
    3D colour distribution matches `tgt` — no correspondence needed. Returns the
    transported source samples (nonlinear; captures tone + saturation, not just MKL's
    mean/covariance). Feed the (src -> transported) pairs to fit_lut_lattice to bake."""
    rng = np.random.default_rng(seed)
    x = src.astype(np.float64).copy()
    for _ in range(n_iter):
        Rm = _rand_rotation(src.shape[1], rng)
        xp = x @ Rm
        tp = tgt @ Rm
        for k in range(src.shape[1]):
            xp[:, k] = _match_marginal(xp[:, k], tp[:, k])
        x = xp @ Rm.T
    return x


# ---------------------------------------------------------------- lattice LUT fit
def _trilinear_matrix(pts: np.ndarray, L: int) -> sp.csr_matrix:
    """Sparse (N, L^3) trilinear interpolation weights for points in [0,1]^3.
    Node index = r + g*L + b*L^2  (red fastest), matching .cube ordering."""
    c = np.clip(pts, 0.0, 1.0) * (L - 1)
    i0 = np.clip(np.floor(c).astype(np.int64), 0, L - 2)
    frac = c - i0
    n = pts.shape[0]
    rows, cols, data = [], [], []
    ar = np.arange(n)
    for corner in range(8):
        dr, dg, db = corner & 1, (corner >> 1) & 1, (corner >> 2) & 1
        wr = frac[:, 0] if dr else 1.0 - frac[:, 0]
        wg = frac[:, 1] if dg else 1.0 - frac[:, 1]
        wb = frac[:, 2] if db else 1.0 - frac[:, 2]
        node = (i0[:, 0] + dr) + (i0[:, 1] + dg) * L + (i0[:, 2] + db) * L * L
        rows.append(ar)
        cols.append(node)
        data.append(wr * wg * wb)
    return sp.coo_matrix(
        (np.concatenate(data), (np.concatenate(rows), np.concatenate(cols))),
        shape=(n, L ** 3),
    ).tocsr()


def _laplacian(L: int) -> sp.csr_matrix:
    """6-neighbour graph Laplacian over an LxLxL lattice (smoothness prior)."""
    ar = np.arange(L)
    R, G, B = np.meshgrid(ar, ar, ar, indexing="ij")
    nid = (R + G * L + B * L * L).astype(np.int64)  # indexed [r,g,b]
    I, J = [], []
    for a in range(3):
        s0 = [slice(None)] * 3
        s1 = [slice(None)] * 3
        s0[a] = slice(0, L - 1)
        s1[a] = slice(1, L)
        n1 = nid[tuple(s0)].ravel()
        n2 = nid[tuple(s1)].ravel()
        I += [n1, n2]
        J += [n2, n1]
    I = np.concatenate(I)
    J = np.concatenate(J)
    A = sp.coo_matrix((np.ones(len(I)), (I, J)), shape=(L ** 3, L ** 3)).tocsr()
    deg = np.asarray(A.sum(1)).ravel()
    return (sp.diags(deg) - A).tocsr()


def fit_lut_lattice(src_enc: np.ndarray, tgt_enc: np.ndarray, L: int = 25,
                    smooth: float = 0.10, ridge: float = 1e-4,
                    weights: np.ndarray | None = None) -> np.ndarray:
    """Fit a display-space LUT lattice directly from corresponded pixels.

    Minimises sum_i w_i || W_i v - t_i ||^2 + smooth * v^T Lap v + ridge ||v||^2,
    where W are trilinear weights. Returns an (L,L,L,3) LUT indexed [r,g,b]. Local
    support + smoothness keep highlights/saturated colours accurate (small dE tails)
    without the edge overshoot of a global polynomial. `weights` (e.g. skin) bias
    the fit toward those samples.
    """
    W = _trilinear_matrix(src_enc, L)
    if weights is not None:
        sw = np.sqrt(weights)
        W = W.multiply(sw[:, None]).tocsr()
        tgt_enc = tgt_enc * sw[:, None]
    Lap = _laplacian(L)
    A = (W.T @ W + smooth * Lap + ridge * sp.identity(L ** 3)).tocsc()
    B = W.T @ tgt_enc  # (L^3, 3) dense
    lu = spla.splu(A)
    V = lu.solve(np.asarray(B))
    lattice = np.empty((L, L, L, 3))
    for ch in range(3):
        lattice[..., ch] = V[:, ch].reshape((L, L, L), order="F")
    return np.clip(lattice, 0.0, 1.0)
