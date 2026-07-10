/*
	colourMatik.cpp — applies a colourMatik 3D LUT (per-instance "slot" file)
	with a built-in Intensity slider. by Sevki Bugra Ozbek - catheadai.com
*/

#include "colourMatik.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// ------------------------------------------------------------ LUT helpers
static void cm_lut_path(A_long slot, char *out, size_t n) {
	const char *home = getenv("HOME");
	if (!home) home = "";
	snprintf(out, n, "%s/Library/Application Support/colourMatik/slot_%ld.cube", home, (long)slot);
}

// Load a 33^3 .cube (RED varies fastest) into seq->lut. Returns 1 on success.
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
			if (count < CM_LUT_N3) {
				seq->lut[count * 3 + 0] = r;
				seq->lut[count * 3 + 1] = g;
				seq->lut[count * 3 + 2] = b;
			}
			count++;
		}
	}
	fclose(f);
	if (size != CM_LUT_SIZE || count < CM_LUT_N3) return 0;
	return 1;
}

static inline float cm_clampf(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

// Trilinear sample of the 33^3 LUT at (r,g,b) in [0,1]. idx = r + g*S + b*S*S.
static void cm_sample(const float *lut, float r, float g, float b, float out[3]) {
	const int S = CM_LUT_SIZE;
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

static PF_Err cm_pixel(void *refcon, A_long x, A_long y, PF_Pixel *inP, PF_Pixel *outP) {
	CM_Info *info = (CM_Info *)refcon;
	float r = inP->red / 255.f, g = inP->green / 255.f, b = inP->blue / 255.f;
	float o[3];
	cm_sample(info->seq->lut, r, g, b, o);
	float t = info->t;
	outP->alpha = inP->alpha;
	outP->red   = (A_u_char)(cm_clampf(r + t * (o[0] - r)) * 255.f + 0.5f);
	outP->green = (A_u_char)(cm_clampf(g + t * (o[1] - g)) * 255.f + 0.5f);
	outP->blue  = (A_u_char)(cm_clampf(b + t * (o[2] - b)) * 255.f + 0.5f);
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

	if (!out_data->sequence_data) {
		return PF_COPY(&params[CM_INPUT]->u.ld, output, NULL, NULL);
	}
	ColourMatikSeq *seq = *(ColourMatikSeq **)out_data->sequence_data;

	if (seq->slot != slot || !seq->loaded) {
		seq->loaded = cm_load_lut(slot, seq);
		seq->slot = slot;
	}

	if (!seq->loaded || intensity == 0.f) {
		return PF_COPY(&params[CM_INPUT]->u.ld, output, NULL, NULL);
	}

	if (in_data->extent_hint.left != output->extent_hint.left ||
		in_data->extent_hint.top != output->extent_hint.top ||
		in_data->extent_hint.right != output->extent_hint.right ||
		in_data->extent_hint.bottom != output->extent_hint.bottom) {
		ERR(PF_FILL(NULL, &output->extent_hint, output));
	}

	CM_Info info; info.seq = seq; info.t = intensity;
	A_long h = in_data->extent_hint.bottom - in_data->extent_hint.top;
	ERR(PF_ITERATE(0, h, &params[CM_INPUT]->u.ld, &in_data->extent_hint, (void *)&info, cm_pixel, output));
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
