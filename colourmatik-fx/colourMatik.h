/*
	colourMatik — native After Effects / Premiere Pro effect.
	Applies a colourMatik 3D LUT (written by the engine to a per-instance "slot"
	.cube file) with a built-in Intensity slider. The heavy colour-matching is
	done by the local engine; this effect just applies its result, on the GPU/CPU,
	as a real, named "colourMatik" effect the panel can add + configure.
*/
#ifndef COLOURMATIK_H
#define COLOURMATIK_H

#include "AEConfig.h"

#ifdef AE_OS_WIN
#include <Windows.h>
#endif

#include "entry.h"
#include "AE_Effect.h"
#include "A.h"
#include "AE_EffectCB.h"
#include "AE_Macros.h"
#include "Param_Utils.h"

#define MAJOR_VERSION   1
#define MINOR_VERSION   0
#define BUG_VERSION     0
#define STAGE_VERSION   PF_Stage_DEVELOP
#define BUILD_VERSION   1

#define NAME        "colourMatik"
#define DESCRIPTION "One-click colour matching. by Sevki Bugra Ozbek - catheadai.com"

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

#define CM_LUT_SIZE  33      // fixed 33^3 LUT (matches what the engine writes for the effect)
#define CM_LUT_N3    (CM_LUT_SIZE * CM_LUT_SIZE * CM_LUT_SIZE)

// Per-instance sequence data: the loaded LUT for this effect's slot.
typedef struct {
	A_long   slot;                  // slot currently loaded (-1 = none/identity)
	A_long   loaded;                // 1 if lut[] holds a valid LUT
	float    lut[CM_LUT_N3 * 3];    // [b*S*S + g*S + r]*3 + channel, values 0..1
} ColourMatikSeq;

extern "C" {
	DllExport PF_Err EffectMain(
		PF_Cmd cmd, PF_InData *in_data, PF_OutData *out_data,
		PF_ParamDef *params[], PF_LayerDef *output);
}

#endif // COLOURMATIK_H
