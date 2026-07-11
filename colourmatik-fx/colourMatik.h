/*
	colourMatik — native After Effects / Premiere Pro effect.
	Applies a colourMatik 3D LUT (written by the engine to a per-instance "slot"
	.cube file) with a built-in Intensity slider. The heavy colour-matching is
	done by the local engine; this effect just applies its result as a real,
	named "colourMatik" effect the panel can add + configure.

	Rendering: in Premiere Pro the effect declares the 32-bit float BGRA pixel
	format (with an 8-bit BGRA fallback), so it applies the engine's 65^3 LUT at
	full float precision — zero quantisation, no banding. In After Effects it
	falls back to the classic 8-bit ARGB path.
*/
#ifndef COLOURMATIK_H
#define COLOURMATIK_H

#ifdef _WIN32
#define _CRT_SECURE_NO_WARNINGS 1   // getenv/fopen/sscanf are fine here; sample builds with /WX
#endif

#include "AEConfig.h"

#ifdef AE_OS_WIN
#include <Windows.h>
#endif

#include "entry.h"
#include "AE_Effect.h"
#include "A.h"
#include "AE_EffectCB.h"
#include "AE_EffectCBSuites.h"
#include "AE_Macros.h"
#include "Param_Utils.h"
#include "SPTypes.h"          // SPAPI, needed by the Premiere suites below
#include "SPBasic.h"          // full SPBasicSuite (AcquireSuite/ReleaseSuite)
#include "PrSDKAESupport.h"

#define MAJOR_VERSION   1
#define MINOR_VERSION   1
#define BUG_VERSION     0
#define STAGE_VERSION   PF_Stage_DEVELOP
#define BUILD_VERSION   1

#define NAME        "colourMatik"
#define DESCRIPTION "One-click colour matching. by Sevki Bugra Ozbek - catheadai.com"

#ifndef kAppID_Premiere
#define kAppID_Premiere 'PrMr'
#endif

enum {
	CM_INPUT = 0,   // default input layer
	CM_INTENSITY,   // 0..200 %, 100 = full match
	CM_SLOT,        // which slot_<N>.cube to load (set by the panel)
	CM_NUM_PARAMS
};

enum { CM_INTENSITY_DISK_ID = 1, CM_SLOT_DISK_ID = 2 };

#define CM_INTENSITY_MIN     0
#define CM_INTENSITY_MAX     200
#define CM_INTENSITY_DFLT    100
#define CM_SLOT_MIN          0
#define CM_SLOT_MAX          99999
#define CM_SLOT_DFLT         0

#define CM_LUT_MAX   65      // largest .cube edge we accept (engine writes 65^3)
#define CM_LUT_N3MAX (CM_LUT_MAX * CM_LUT_MAX * CM_LUT_MAX)

// Per-instance sequence data. The LUT lives in a SEPARATELY allocated buffer
// (pointer, not inline): the struct that Premiere flattens into the .prproj is
// then tiny and version-stable, so a project saved by another build can never
// hand us a too-small buffer to overflow (that was the load-time crash). The
// lut pointer is meaningless across sessions — SequenceResetup always allocates
// a fresh one, so a restored (garbage) pointer is never dereferenced.
typedef struct {
	A_long   slot;      // slot currently loaded (-1 = none/identity)
	A_long   loaded;    // 1 if lut holds a valid LUT for 'slot'
	A_long   size;      // LUT edge length actually loaded (e.g. 33 or 65)
	float   *lut;       // heap buffer of CM_LUT_N3MAX*3 floats (NULL if alloc failed)
} ColourMatikSeq;

extern "C" {
	DllExport PF_Err EffectMain(
		PF_Cmd cmd, PF_InData *in_data, PF_OutData *out_data,
		PF_ParamDef *params[], PF_LayerDef *output);
}

#endif // COLOURMATIK_H
