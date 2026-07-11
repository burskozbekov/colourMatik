/*
	colourMatik.cpp — applies a colourMatik 3D LUT (per-instance "slot" file)
	with a built-in Intensity slider. by Sevki Bugra Ozbek - catheadai.com

	Premiere Pro: renders in 32-bit float BGRA (declared via the Premiere pixel
	format suite; 8-bit BGRA fallback), so the engine's 65^3 LUT is applied with
	zero quantisation — the clip gets exactly what the engine computed.
	After Effects: classic 8-bit ARGB path via PF_ITERATE.
*/

#include "colourMatik.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>

// Premiere renders on several threads at once; LUT loads into the shared
// sequence data must be serialized, and 'loaded' must publish with a barrier.
#ifdef AE_OS_WIN
static volatile LONG cm_lock_v = 0;
static void cm_lock(void)   { while (InterlockedCompareExchange(&cm_lock_v, 1, 0)) Sleep(0); }
static void cm_unlock(void) { InterlockedExchange(&cm_lock_v, 0); }
#define CM_STORE_RELEASE(p, v) InterlockedExchange((volatile LONG *)(p), (LONG)(v))
#define CM_LOAD_ACQUIRE(p)     InterlockedCompareExchange((volatile LONG *)(p), 0, 0)
#else
#include <os/lock.h>
static os_unfair_lock cm_lock_v = OS_UNFAIR_LOCK_INIT;
static void cm_lock(void)   { os_unfair_lock_lock(&cm_lock_v); }
static void cm_unlock(void) { os_unfair_lock_unlock(&cm_lock_v); }
#define CM_STORE_RELEASE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)
#define CM_LOAD_ACQUIRE(p)     __atomic_load_n((p), __ATOMIC_ACQUIRE)
#endif

// ------------------------------------------------------------ LUT helpers
static void cm_lut_path(A_long slot, char *out, size_t n) {
#ifdef AE_OS_WIN
	const char *base = getenv("APPDATA");            // %USERPROFILE%\AppData\Roaming
	if (!base) base = "";
	snprintf(out, n, "%s\\colourMatik\\slot_%ld.cube", base, (long)slot);
#else
	const char *home = getenv("HOME");
	if (!home) home = "";
	snprintf(out, n, "%s/Library/Application Support/colourMatik/slot_%ld.cube", home, (long)slot);
#endif
}

// Load a .cube (RED varies fastest, edge size 2..CM_LUT_MAX) into seq->lut.
static int cm_load_lut(A_long slot, ColourMatikSeq *seq) {
	char path[1024];
	cm_lut_path(slot, path, sizeof(path));
	FILE *f = fopen(path, "r");
	if (!f) return 0;
	int size = 0, count = 0;
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		if (line[0] == '#' || line[0] == '\r' || line[0] == '\n') continue;
		if (strncmp(line, "LUT_3D_SIZE", 11) == 0) { sscanf(line + 11, "%d", &size); continue; }
		if (strncmp(line, "TITLE", 5) == 0 || strncmp(line, "DOMAIN", 6) == 0 ||
			strncmp(line, "LUT_1D", 6) == 0) continue;
		float r, g, b;
		if (sscanf(line, "%f %f %f", &r, &g, &b) == 3) {
			if (count < CM_LUT_N3MAX) {
				seq->lut[count * 3 + 0] = r;
				seq->lut[count * 3 + 1] = g;
				seq->lut[count * 3 + 2] = b;
			}
			count++;
		}
	}
	fclose(f);
	if (size < 2 || size > CM_LUT_MAX || count < size * size * size) return 0;
	seq->size = size;
	return 1;
}

static inline float cm_clampf(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

// Trilinear sample of an S^3 LUT at (r,g,b) in [0,1]. idx = r + g*S + b*S*S.
// S must be >= 2 (callers only sample a fully published LUT, but keep the guard).
static void cm_sample(const float *lut, int S, float r, float g, float b, float out[3]) {
	if (S < 2) { out[0] = r; out[1] = g; out[2] = b; return; }
	float cr = cm_clampf(r) * (S - 1), cg = cm_clampf(g) * (S - 1), cb = cm_clampf(b) * (S - 1);
	int r0 = (int)cr, g0 = (int)cg, b0 = (int)cb;
	if (r0 > S - 2) r0 = S - 2; if (r0 < 0) r0 = 0;
	if (g0 > S - 2) g0 = S - 2; if (g0 < 0) g0 = 0;
	if (b0 > S - 2) b0 = S - 2; if (b0 < 0) b0 = 0;
	float fr = cr - r0, fg = cg - g0, fb = cb - b0;
	out[0] = out[1] = out[2] = 0.f;
	for (int c = 0; c < 8; c++) {
		int dr = c & 1, dg = (c >> 1) & 1, db = (c >> 2) & 1;
		float w = (dr ? fr : 1 - fr) * (dg ? fg : 1 - fg) * (db ? fb : 1 - fb);
		int idx = ((r0 + dr) + (g0 + dg) * S + (b0 + db) * S * S) * 3;
		out[0] += w * lut[idx + 0];
		out[1] += w * lut[idx + 1];
		out[2] += w * lut[idx + 2];
	}
}

typedef struct { ColourMatikSeq *seq; float t; } CM_Info;

// Diagnostic trace -> /tmp/colourmatik_fx.log (or %TEMP% on Windows), capped.
// DORMANT unless the COLOURMATIK_TRACE env var is set, so shipping builds are
// silent but field-debuggable. Premiere's "a low-level exception occurred"
// doesn't say where; this pinpoints the exact render call when enabled.
static void cm_trace(const char *fmtstr, ...) {
	static int enabled = -1;
	if (enabled == -1) enabled = getenv("COLOURMATIK_TRACE") ? 1 : 0;
	if (!enabled) return;
	static int n = 0;
	if (n > 400) return;
	n++;
#ifdef AE_OS_WIN
	const char *tmp = getenv("TEMP"); if (!tmp) tmp = ".";
	char lp[1024]; snprintf(lp, sizeof(lp), "%s\\colourmatik_fx.log", tmp);
	FILE *lf = fopen(lp, "a");
#else
	FILE *lf = fopen("/tmp/colourmatik_fx.log", "a");
#endif
	if (!lf) return;
	va_list ap;
	va_start(ap, fmtstr);
	vfprintf(lf, fmtstr, ap);
	va_end(ap);
	fputc('\n', lf);
	fclose(lf);
}

// ------------------------------------------------------------ AE 8-bit ARGB path
static PF_Err cm_pixel(void *refcon, A_long x, A_long y, PF_Pixel *inP, PF_Pixel *outP) {
	CM_Info *info = (CM_Info *)refcon;
	float r = inP->red / 255.f, g = inP->green / 255.f, b = inP->blue / 255.f;
	float o[3];
	cm_sample(info->seq->lut, info->seq->size, r, g, b, o);
	float t = info->t;
	outP->alpha = inP->alpha;
	outP->red   = (A_u_char)(cm_clampf(r + t * (o[0] - r)) * 255.f + 0.5f);
	outP->green = (A_u_char)(cm_clampf(g + t * (o[1] - g)) * 255.f + 0.5f);
	outP->blue  = (A_u_char)(cm_clampf(b + t * (o[2] - b)) * 255.f + 0.5f);
	return PF_Err_NONE;
}

// ------------------------------------------------------------ Premiere BGRA paths
// Row loops over the effect worlds; memory order is B,G,R,A per pixel.
// IMPORTANT: honour the host's abort callback every few rows. Premiere cancels
// superseded renders (project open, scrubbing, apply-time thumbnails); a plugin
// that never checks gets hard-cancelled — which surfaces in the Events panel as
// "a low-level exception occurred". Checking lets us exit cleanly instead.
#define CM_ABORT_EVERY 16
static int cm_aborted(PF_InData *in_data, A_long y) {
	if ((y & (CM_ABORT_EVERY - 1)) != 0) return 0;
	if (!in_data || !in_data->inter.abort) return 0;
	return (*in_data->inter.abort)(in_data->effect_ref) != PF_Err_NONE;
}

static PF_Err cm_render_bgra_32f(PF_InData *in_data, PF_EffectWorld *src, PF_EffectWorld *dst,
                                 A_long width, A_long height, CM_Info *info) {
	const float *lut = info->seq->lut;
	const int S = (int)info->seq->size;
	const float t = info->t;
	for (A_long y = 0; y < height; y++) {
		if (cm_aborted(in_data, y)) return PF_Interrupt_CANCEL;
		const float *ip = (const float *)((const char *)src->data + (size_t)y * src->rowbytes);
		float *op = (float *)((char *)dst->data + (size_t)y * dst->rowbytes);
		for (A_long x = 0; x < width; x++) {
			float b = ip[0], g = ip[1], r = ip[2], a = ip[3];
			float rc = cm_clampf(r), gc = cm_clampf(g), bc = cm_clampf(b);
			float o[3];
			cm_sample(lut, S, rc, gc, bc, o);
			// blend from the CLAMPED sample point, so over-range (HDR) offsets survive
			op[0] = b + t * (o[2] - bc);
			op[1] = g + t * (o[1] - gc);
			op[2] = r + t * (o[0] - rc);
			op[3] = a;
			ip += 4; op += 4;
		}
	}
	return PF_Err_NONE;
}

static PF_Err cm_render_bgra_8u(PF_InData *in_data, PF_EffectWorld *src, PF_EffectWorld *dst,
                                A_long width, A_long height, CM_Info *info) {
	const float *lut = info->seq->lut;
	const int S = (int)info->seq->size;
	const float t = info->t;
	for (A_long y = 0; y < height; y++) {
		if (cm_aborted(in_data, y)) return PF_Interrupt_CANCEL;
		const unsigned char *ip = (const unsigned char *)src->data + (size_t)y * src->rowbytes;
		unsigned char *op = (unsigned char *)dst->data + (size_t)y * dst->rowbytes;
		for (A_long x = 0; x < width; x++) {
			float b = ip[0] / 255.f, g = ip[1] / 255.f, r = ip[2] / 255.f;
			float o[3];
			cm_sample(lut, S, r, g, b, o);
			op[0] = (unsigned char)(cm_clampf(b + t * (o[2] - b)) * 255.f + 0.5f);
			op[1] = (unsigned char)(cm_clampf(g + t * (o[1] - g)) * 255.f + 0.5f);
			op[2] = (unsigned char)(cm_clampf(r + t * (o[0] - r)) * 255.f + 0.5f);
			op[3] = ip[3];
			ip += 4; op += 4;
		}
	}
	return PF_Err_NONE;
}

static PF_Err cm_copy_rows(PF_InData *in_data, PF_EffectWorld *src, PF_EffectWorld *dst,
                           A_long width, A_long height, size_t bpp) {
	size_t nbytes = (size_t)width * bpp;
	for (A_long y = 0; y < height; y++) {
		if (cm_aborted(in_data, y)) return PF_Interrupt_CANCEL;
		memcpy((char *)dst->data + (size_t)y * dst->rowbytes,
		       (const char *)src->data + (size_t)y * src->rowbytes, nbytes);
	}
	return PF_Err_NONE;
}

// ------------------------------------------------------------ AE entry points
static PF_Err About(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	PF_SPRINTF(out_data->return_msg, "%s v%d.%d\r%s", NAME, MAJOR_VERSION, MINOR_VERSION, DESCRIPTION);
	return PF_Err_NONE;
}

static PF_Err GlobalSetup(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	out_data->my_version = PF_VERSION(MAJOR_VERSION, MINOR_VERSION, BUG_VERSION, STAGE_VERSION, BUILD_VERSION);
	out_data->out_flags |= PF_OutFlag_PIX_INDEPENDENT | PF_OutFlag_USE_OUTPUT_EXTENT;

	// Premiere: declare high-precision pixel formats (float preferred, 8-bit fallback).
	if (in_data->appl_id == kAppID_Premiere && in_data->pica_basicP) {
		SPBasicSuite *bs = in_data->pica_basicP;
		PF_PixelFormatSuite1 *pfs = NULL;
		if (bs->AcquireSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1,
		                     (const void **)&pfs) == kSPNoError && pfs) {
			(*pfs->ClearSupportedPixelFormats)(in_data->effect_ref);
			(*pfs->AddSupportedPixelFormat)(in_data->effect_ref, PrPixelFormat_BGRA_4444_32f);
			(*pfs->AddSupportedPixelFormat)(in_data->effect_ref, PrPixelFormat_BGRA_4444_8u);
			bs->ReleaseSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1);
		}
	}
	return PF_Err_NONE;
}

static PF_Err ParamsSetup(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	PF_ParamDef def;

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Intensity", CM_INTENSITY_MIN, CM_INTENSITY_MAX, CM_INTENSITY_MIN,
		CM_INTENSITY_MAX, CM_INTENSITY_DFLT, PF_Precision_INTEGER, 0, 0, CM_INTENSITY_DISK_ID);

	AEFX_CLR_STRUCT(def);
	PF_ADD_FLOAT_SLIDERX("Match Slot", CM_SLOT_MIN, CM_SLOT_MAX, CM_SLOT_MIN,
		CM_SLOT_MAX, CM_SLOT_DFLT, PF_Precision_INTEGER, 0, 0, CM_SLOT_DISK_ID);

	out_data->num_params = CM_NUM_PARAMS;
	return PF_Err_NONE;
}

static PF_Err SequenceSetup(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	if (out_data->sequence_data) PF_DISPOSE_HANDLE(out_data->sequence_data);
	out_data->sequence_data = PF_NEW_HANDLE(sizeof(ColourMatikSeq));
	if (!out_data->sequence_data) return PF_Err_INTERNAL_STRUCT_DAMAGED;
	ColourMatikSeq *seq = *(ColourMatikSeq **)out_data->sequence_data;
	seq->slot = -1;
	seq->loaded = 0;
	seq->size = 0;
	return PF_Err_NONE;
}

static PF_Err SequenceSetdown(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	if (in_data->sequence_data) { PF_DISPOSE_HANDLE(in_data->sequence_data); out_data->sequence_data = NULL; }
	return PF_Err_NONE;
}

static PF_Err SequenceResetup(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	if (!in_data->sequence_data) return SequenceSetup(in_data, out_data, params, output);
	return PF_Err_NONE;
}

static PF_Err Render(PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	PF_Err err = PF_Err_NONE;

	float intensity = (float)(params[CM_INTENSITY]->u.fs_d.value / 100.0);
	A_long slot = (A_long)(params[CM_SLOT]->u.fs_d.value + 0.5);
	PF_EffectWorld *inputW = &params[CM_INPUT]->u.ld;
	int identity = 0;

	// Premiere's render process may populate only in_data->sequence_data.
	PF_Handle seqH = in_data->sequence_data ? in_data->sequence_data
	                                        : out_data->sequence_data;
	ColourMatikSeq *seq = NULL;
	if (seqH && *(void **)seqH) {
		seq = *(ColourMatikSeq **)seqH;
		// Premiere renders concurrently: serialize the (slow, 65^3) LUT load and
		// publish 'loaded' with release/acquire so no thread ever samples a
		// half-written LUT (that was the garbage-frame + exception storm).
		if (CM_LOAD_ACQUIRE(&seq->loaded) == 0 || seq->slot != slot) {
			cm_lock();
			if (seq->slot != slot || !seq->loaded) {
				CM_STORE_RELEASE(&seq->loaded, 0);
				seq->slot = slot;
				int ok = cm_load_lut(slot, seq);   // fills lut[] and seq->size
				CM_STORE_RELEASE(&seq->loaded, ok ? 1 : 0);
			}
			cm_unlock();
		}
		if (CM_LOAD_ACQUIRE(&seq->loaded) == 0 || seq->size < 2 || intensity == 0.f)
			identity = 1;
	} else {
		identity = 1;
	}

	CM_Info info; info.seq = seq; info.t = intensity;

	// ---------------- Premiere Pro: BGRA float / 8-bit paths ----------------
	if (in_data->appl_id == kAppID_Premiere && in_data->pica_basicP) {
		SPBasicSuite *bs = in_data->pica_basicP;
		PF_PixelFormatSuite1 *pfs = NULL;
		PrPixelFormat fmt = PrPixelFormat_BGRA_4444_8u;
		int fmt_ok = 0;
		if (bs->AcquireSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1,
		                     (const void **)&pfs) == kSPNoError && pfs) {
			fmt_ok = ((*pfs->GetPixelFormat)(output, &fmt) == PF_Err_NONE);
			bs->ReleaseSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1);
		}
		// On transient apply-time renders GetPixelFormat can fail or return
		// garbage. We only ever declared the two BGRA formats, so infer from the
		// row stride — the one reliable signal (|rowbytes|/width: 4 -> 8u, 16 -> 32f).
		if (!fmt_ok || (fmt != PrPixelFormat_BGRA_4444_32f &&
		                fmt != PrPixelFormat_BGRA_4444_8u)) {
			A_long rb = output->rowbytes < 0 ? -output->rowbytes : output->rowbytes;
			A_long px = (output->width > 0) ? rb / output->width : 4;
			fmt = (px >= 16) ? PrPixelFormat_BGRA_4444_32f : PrPixelFormat_BGRA_4444_8u;
			cm_trace("  (fmt query unreliable -> inferred %s from stride %ld/px)",
			         px >= 16 ? "32f" : "8u", (long)px);
		}
		size_t bpp = (fmt == PrPixelFormat_BGRA_4444_32f) ? 16 : 4;
		A_long w = MIN(inputW->width, output->width);
		A_long h = MIN(inputW->height, output->height);
		// Never trust dims past what the rowbytes can actually hold, and never
		// touch a world without pixels (half-initialised apply-time worlds).
		{
			A_long irb = inputW->rowbytes < 0 ? -inputW->rowbytes : inputW->rowbytes;
			A_long orb = output->rowbytes < 0 ? -output->rowbytes : output->rowbytes;
			if (irb > 0) w = MIN(w, (A_long)(irb / (A_long)bpp));
			if (orb > 0) w = MIN(w, (A_long)(orb / (A_long)bpp));
		}
		cm_trace("render fmt=%d in=%ldx%ld rb=%ld %p out=%ldx%ld rb=%ld %p slot=%ld loaded=%ld t=%.2f",
		         (int)fmt, (long)inputW->width, (long)inputW->height, (long)inputW->rowbytes,
		         inputW->data, (long)output->width, (long)output->height, (long)output->rowbytes,
		         output->data, (long)slot, (long)(seq ? seq->loaded : -1), intensity);
		if (!inputW->data || !output->data || w <= 0 || h <= 0) {
			cm_trace("  -> skipped (empty/null world)");
			return PF_Err_NONE;
		}
		PF_Err perr;
		if (fmt == PrPixelFormat_BGRA_4444_32f) {
			perr = identity ? cm_copy_rows(in_data, inputW, output, w, h, 16)
			                : cm_render_bgra_32f(in_data, inputW, output, w, h, &info);
		} else {
			perr = identity ? cm_copy_rows(in_data, inputW, output, w, h, 4)
			                : cm_render_bgra_8u(in_data, inputW, output, w, h, &info);
		}
		cm_trace(perr == PF_Err_NONE ? "  -> done" : "  -> aborted (host superseded)");
		// Premiere logs ANY non-zero return from a Pr-format render as "a low-level
		// exception". A host-superseded render isn't an error — we already stopped
		// early to save CPU; just report success. The discarded frame is moot.
		return PF_Err_NONE;   // NEVER hand a Premiere world to the AE PF_ITERATE path
	}

	// ---------------- After Effects (and fallback): 8-bit ARGB --------------
	if (identity) {
		return PF_COPY(inputW, output, NULL, NULL);
	}

	if (in_data->extent_hint.left != output->extent_hint.left ||
		in_data->extent_hint.top != output->extent_hint.top ||
		in_data->extent_hint.right != output->extent_hint.right ||
		in_data->extent_hint.bottom != output->extent_hint.bottom) {
		ERR(PF_FILL(NULL, &output->extent_hint, output));
	}

	A_long hh = in_data->extent_hint.bottom - in_data->extent_hint.top;
	ERR(PF_ITERATE(0, hh, inputW, &in_data->extent_hint, (void *)&info, cm_pixel, output));
	return err;
}

extern "C" DllExport
PF_Err PluginDataEntryFunction2(
	PF_PluginDataPtr inPtr, PF_PluginDataCB2 inPluginDataCallBackPtr,
	SPBasicSuite *inSPBasicSuitePtr, const char *inHostName, const char *inHostVersion) {
	PF_Err result = PF_Err_INVALID_CALLBACK;
	result = PF_REGISTER_EFFECT_EXT2(
		inPtr, inPluginDataCallBackPtr,
		"colourMatik",              // Name (shows in Effects panel)
		"catheadai colourMatik",    // Match Name (unique id)
		"colourMatik",              // Category
		AE_RESERVED_INFO,
		"EffectMain",
		"https://catheadai.com");
	return result;
}

PF_Err EffectMain(PF_Cmd cmd, PF_InData *in_data, PF_OutData *out_data, PF_ParamDef *params[], PF_LayerDef *output) {
	PF_Err err = PF_Err_NONE;
	switch (cmd) {
	case PF_Cmd_ABOUT:            err = About(in_data, out_data, params, output); break;
	case PF_Cmd_GLOBAL_SETUP:     err = GlobalSetup(in_data, out_data, params, output); break;
	case PF_Cmd_PARAMS_SETUP:     err = ParamsSetup(in_data, out_data, params, output); break;
	case PF_Cmd_SEQUENCE_SETUP:   err = SequenceSetup(in_data, out_data, params, output); break;
	case PF_Cmd_SEQUENCE_SETDOWN: err = SequenceSetdown(in_data, out_data, params, output); break;
	case PF_Cmd_SEQUENCE_RESETUP: err = SequenceResetup(in_data, out_data, params, output); break;
	case PF_Cmd_RENDER:           err = Render(in_data, out_data, params, output); break;
	}
	return err;
}

#ifdef AE_OS_WIN
BOOL WINAPI DllMain(HINSTANCE hDLL, DWORD dwReason, LPVOID lpReserved) { return TRUE; }
#endif
