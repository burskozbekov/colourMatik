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
static void cm_sample(const float *lut, int S, float r, float g, float b, float out[3]) {
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

// Diagnostic trace (first calls + anomalies) -> /tmp/colourmatik_fx.log.
// Premiere reports "a low-level exception occurred" without saying where; this
// pinpoints the exact render call if it ever happens again. Cheap + capped.
static void cm_trace(const char *fmtstr, ...) {
	static int n = 0;
	if (n > 200) return;
	n++;
	FILE *lf = fopen("/tmp/colourmatik_fx.log", "a");
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
static void cm_render_bgra_32f(PF_EffectWorld *src, PF_EffectWorld *dst,
                               A_long width, A_long height, CM_Info *info) {
	const float *lut = info->seq->lut;
	const int S = (int)info->seq->size;
	const float t = info->t;
	for (A_long y = 0; y < height; y++) {
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
}

static void cm_render_bgra_8u(PF_EffectWorld *src, PF_EffectWorld *dst,
                              A_long width, A_long height, CM_Info *info) {
	const float *lut = info->seq->lut;
	const int S = (int)info->seq->size;
	const float t = info->t;
	for (A_long y = 0; y < height; y++) {
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
}

static void cm_copy_rows(PF_EffectWorld *src, PF_EffectWorld *dst,
                         A_long width, A_long height, size_t bpp) {
	size_t nbytes = (size_t)width * bpp;
	for (A_long y = 0; y < height; y++) {
		memcpy((char *)dst->data + (size_t)y * dst->rowbytes,
		       (const char *)src->data + (size_t)y * src->rowbytes, nbytes);
	}
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
		if (seq->slot != slot || !seq->loaded) {
			seq->loaded = cm_load_lut(slot, seq);
			seq->slot = slot;
		}
		if (!seq->loaded || intensity == 0.f) identity = 1;
	} else {
		identity = 1;
	}

	CM_Info info; info.seq = seq; info.t = intensity;

	// ---------------- Premiere Pro: BGRA float / 8-bit paths ----------------
	if (in_data->appl_id == kAppID_Premiere && in_data->pica_basicP) {
		SPBasicSuite *bs = in_data->pica_basicP;
		PF_PixelFormatSuite1 *pfs = NULL;
		PrPixelFormat fmt = PrPixelFormat_BGRA_4444_8u;
		if (bs->AcquireSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1,
		                     (const void **)&pfs) == kSPNoError && pfs) {
			(*pfs->GetPixelFormat)(output, &fmt);
			bs->ReleaseSuite(kPFPixelFormatSuite, kPFPixelFormatSuiteVersion1);
		}
		size_t bpp = (fmt == PrPixelFormat_BGRA_4444_32f) ? 16 : 4;
		A_long w = MIN(inputW->width, output->width);
		A_long h = MIN(inputW->height, output->height);
		// Never trust dims past what the rowbytes can actually hold, and never
		// touch a world without pixels — early apply-time renders can hand us
		// half-initialised worlds (the "low-level exception" class of bugs).
		if (inputW->rowbytes > 0)  w = MIN(w, (A_long)(inputW->rowbytes / (A_long)bpp));
		if (output->rowbytes > 0)  w = MIN(w, (A_long)(output->rowbytes / (A_long)bpp));
		cm_trace("render fmt=%d in=%ldx%ld rb=%ld %p out=%ldx%ld rb=%ld %p slot=%ld loaded=%ld t=%.2f",
		         (int)fmt, (long)inputW->width, (long)inputW->height, (long)inputW->rowbytes,
		         inputW->data, (long)output->width, (long)output->height, (long)output->rowbytes,
		         output->data, (long)slot, (long)(seq ? seq->loaded : -1), intensity);
		if (!inputW->data || !output->data || w <= 0 || h <= 0) {
			cm_trace("  -> skipped (empty/null world)");
			return PF_Err_NONE;
		}
		if (fmt == PrPixelFormat_BGRA_4444_32f) {
			if (identity) cm_copy_rows(inputW, output, w, h, 16);
			else          cm_render_bgra_32f(inputW, output, w, h, &info);
			return PF_Err_NONE;
		}
		if (fmt == PrPixelFormat_BGRA_4444_8u) {
			if (identity) cm_copy_rows(inputW, output, w, h, 4);
			else          cm_render_bgra_8u(inputW, output, w, h, &info);
			return PF_Err_NONE;
		}
		cm_trace("  -> unexpected fmt, falling back to ARGB path");
		// Unexpected format: fall through to the generic 8-bit ARGB path below.
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
