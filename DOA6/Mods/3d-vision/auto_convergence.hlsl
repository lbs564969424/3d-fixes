Texture2D<float> stereo2mono_downscaled_zbuffer : register(t110);

Texture2D<float4> StereoParams : register(t121);
Texture1D<float4> IniParams : register(t120);

#include "auto_convergence_state.hlsl"

RWStructuredBuffer<struct auto_convergence_state> state : register(u1);

// Copied from lighting shaders
cbuffer slot1 : register(b13)
{
	row_major matrix mW2P;
	row_major matrix mP2W;
}

//// Grabbed via ShaderRegex:
//cbuffer cb13 : register(b13)
//{
//	row_major matrix mP2V;
//}

float z_to_w(float z)
{
	// This is game specific - adjust as needed.

	// Using mP2W and mW2P (e.g. copied from lighting shader):
	float4 tmp = mul(float4(0, 0, z, 1), mP2W);
	tmp = tmp / tmp.w;
	tmp = mul(tmp, mW2P);
	return tmp.w;

	//// Using mP2V:
	//float4 tmp = mul(float4(0, 0, z, 1), mP2V);
	//return -tmp.z / tmp.w;
}

void main(out float auto_convergence : SV_Target0)
{
	float target_convergence, convergence_difference;
	float current_convergence;
	float target_popout_bias;
	float z, zr, zl, w;

	float4 stereo = StereoParams.Load(0);
	float separation = stereo.x, convergence = stereo.y, eye = stereo.z, raw_sep = stereo.w;

	// Since there is some lag between setting the auto-convergence and it
	// taking effect, the convergence from this frame may not be the
	// convergence we previously set (which may still be in flight to the
	// CPU). This can lead to the slow convergence transitions appearing to
	// stutter, since although we are using the same convergence in the
	// calculation as last time, the depth buffer (and in particular, the
	// small subset of points we sample from it) is different and we may
	// come up with a different result (even sometimes going backwards).
	// To counter this and eliminate the stutter, if we tried to set a
	// convergence in the last frame we will use it as a starting point for
	// the calculations in this frame instead of the current convergence.
	if (prev_auto_convergence_enabled) {
		current_convergence = state[0].last_set_convergence;
		if (isnan(current_convergence))
			current_convergence = convergence;
		else
			state[0].last_set_convergence = 1.#QNAN;
	} else {
		current_convergence = convergence;
		state[0].last_set_convergence = 1.#QNAN;
		state[0].last_convergence.xyzw = 1.#QNAN;
	}

	zr = stereo2mono_downscaled_zbuffer.Load(int3(0, 0, 0));
	zl = stereo2mono_downscaled_zbuffer.Load(int3(1, 0, 0));

	// stereo2mono will only work in SLI if StereoFlagsDX10=0x00000008 or
	// the profile supports CM, so we might not have data from the left
	// eye here and check that it is valid before using it - that way at
	// least we will have some auto-convergence, but objects that only
	// obscure the camera in the left eye won't trigger auto-convergence:
	z = (zl ? max(zl, zr) : zr);

	w = z_to_w(z);

	if (isinf(w)) {
		// No depth buffer, auto-convergence cannot work. Bail now,
		// otherwise we would set the hard maximum convergence limit
		auto_convergence = 1.#QNAN;
		state[0].judder = false;
		return;
	}

	// A lot of the maths below is experimental to try to find a good
	// auto-convergence algorithm that works well with a wide variety of
	// screen sizes, seating distances, and varying scenes in the game.

	// Apply the max convergence now, before we apply the popout bias, on
	// the theory that the max suitable convergence is going to vary based
	// on screen size
	target_convergence = min(w, max_convergence_soft);

	// Disabling this for now since we want the user popout bias to be
	// saved in the d3dx_user.ini, meaning we can't calculate it on the
	// GPU. TODO: Maybe bring this back once able to stage arbitrary buffers.
	//if (user_convergence_delta) {
	//	// User adjusted the convergence. Convert this to an equivalent
	//	// popout bias for auto-convergence that we save in a buffer on
	//	// the GPU. This is the below formula re-arranged:
	//	target_popout_bias = (separation*(convergence - target_convergence)/(raw_sep*w));
	//	target_popout_bias = min(max(target_popout_bias, -1), 1) - ini_popout_bias;
	//	state[0].user_popout_bias = target_popout_bias;
	//}

	// Apply the popout bias. This experimental formula is derived by
	// taking the nvidia formula with the perspective divide and the
	// original x=0:
	//
	//   x' = x + separation * (depth - convergence) / depth
	//   x' = separation * (depth - convergence) / depth
	//
	// That gives us our original stereo corrected X value using a
	// convergence that would place the closest object at screen depth
	// (barring the result of capping the convergence). We want to find a
	// new convergence value that would instead position the object
	// slightly popped out - to do so in a way that is comfortable
	// regardless of scene, screen size, and player distance from the
	// screen we apply the popout bias to the x', call it x''. Because we
	// are modifying this post-separation, we will need to multiply by the
	// raw separation value so that it scales with separation (otherwise we
	// would always end with the full pop-out regardless of separation -
	// which is actually kind of cool - people who like toyification might
	// appreciate it, but we do want turning the stereo effect down to
	// reduce the stereo effect):
	//
	//   x'' = x' - (popout_bias * raw_separation)
	//
	// Then we rearrange the nvidia formula and substitute in the two
	// previous formulas to find the new convergence:
	//
	//   x'' = separation * (depth - convergence') / depth
	//   convergence' = depth * (1 - (x'' / separation))
	//   convergence' = depth * (((popout_bias * raw_separation) - x') / separation + 1)
	//   convergence' = depth * popout * raw_separation / separation + convergence
	//
	float new_convergence = w * (ini_popout_bias + state[0].user_popout_bias) * raw_sep / separation + target_convergence;

	// Apply the minimum convergence now to ensure we can't go negative
	// regardless of what the popout bias did, and a hard maximum
	// convergence to prevent us going near infinity:
	new_convergence = min(max(new_convergence, min_convergence), max_convergence_hard);

	// The *2 here is to compensate for the lag in setting the
	// convergence due to the asynchronous transfer.
	float diff = slow_convergence_rate * (time - prev_time) * 2;

	convergence_difference = new_convergence - current_convergence;
	if (abs(convergence_difference) >= instant_convergence_threshold) {

		// The anti-judder countermeasure aims to detect situations
		// where the auto-convergence makes an adjustment that moves
		// something on or off screen, that in turn triggers another
		// auto-convergence correction causing an oscillation between
		// two or more convergence values. In this situation we want to
		// stop trying to set the convergence back to a value it
		// recently was, but we also have to choose which state we stop
		// in. To try to avoid the camera being obscured, we try to
		// stop in the lower convergence state
		if (any(abs(new_convergence - state[0].last_convergence.xyzw) < anti_judder_threshold)) {
			state[0].judder = true;
			state[0].judder_time = time;
			if (new_convergence < current_convergence) {
				auto_convergence = new_convergence;
				state[0].last_set_convergence = auto_convergence;
				state[0].last_convergence.xyzw = float4(current_convergence, state[0].last_convergence.xyz);
				return;
			}
			auto_convergence = 1.#SNAN;
			return;
		}

		auto_convergence = new_convergence;
	} else if (-convergence_difference > slow_convergence_threshold_near) {
		auto_convergence = max(new_convergence, current_convergence - diff);
	} else if (convergence_difference > slow_convergence_threshold_far) {
		auto_convergence = min(new_convergence, current_convergence + diff);
	} else {
		auto_convergence = 1.#QNAN;
	}

	state[0].last_convergence.xyzw = float4(current_convergence, state[0].last_convergence.xyz);
	state[0].last_set_convergence = auto_convergence;
	state[0].judder = false;
}
