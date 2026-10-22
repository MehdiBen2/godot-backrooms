shader_type canvas_item;

#define MAT_SCREEN 0.0
#define MAT_SPHERE1 1.0
#define MAT_FLOOR  2.0
#define MAT_CORNER 3.0
#define MAT_SCREENZ 4.0
#define MAT_MARCHSPHERE 5.0
#define MAT_MARCHROUTE 6.0
#define MAT_MARCHRADIUS 7.0
#define MAT_SPHERE2 8.0
#define MAT_SPHERE3 9.0
#define MAT_RAYDIRECTION 10.0
#define MAT_HITPOINT 11.0

struct TimelineState {
	float uvToP;
	float colToUv;
	float screenZ;
	float sphereAnim;
	float radiusAnim;
	float routeAnim;
	float raySphereAlpha;
	float cornersAlpha;
	float cornersAnim;
	float screenZAlpha;
	float radiusAlpha;
	float rayDirectionAnim;
	float rayDirectionAnim2;
	float screenAlpha;
	vec3 cameraPos;
	vec3 cameraTarget;
	float sum;
	float sphereID;
};

float tl(float val, float offset, float range, inout float sum) {
	float im = sum + offset;
	float ix = im + range;
	sum += offset + range;
	return clamp((val - im) / (ix - im), 0.0, 1.0);
}

float cio(float t) {
	return t < 0.5
		? 0.5 * (1.0 - sqrt(1.0 - 4.0 * t * t))
		: 0.5 * (sqrt((3.0 - 2.0 * t) * (2.0 * t - 1.0)) + 1.0);
}

float eio(float t) {
	return (t == 0.0 || t == 1.0)
		? t
		: (t < 0.5
			? +0.5 * pow(2.0, (20.0 * t) - 10.0)
			: -0.5 * pow(2.0, 10.0 - (t * 20.0)) + 1.0);
}

void init_timeline(inout TimelineState st, float time) {
	st.uvToP = 0.0;
	st.colToUv = 1.0;
	st.screenZ = 2.5;
	st.sphereAnim = 1.0;
	st.radiusAnim = 1.0;
	st.routeAnim = 1.0;
	st.raySphereAlpha = 0.0;
	st.cornersAlpha = 0.0;
	st.cornersAnim = 0.0;
	st.screenZAlpha = 0.0;
	st.radiusAlpha = 1.0;
	st.rayDirectionAnim = 0.0;
	st.rayDirectionAnim2 = 0.0;
	st.screenAlpha = 0.0;
	st.cameraPos = vec3(0.0);
	st.cameraTarget = vec3(0.0, 0.0, 5.0);
	st.sum = 0.0;
	st.sphereID = 0.0;

	float t = tl(time, 1.0, 0.5, st.sum);
	st.uvToP = mix(0.0, 1.0, eio(t));

	t = tl(time, 1.0, 1.0, st.sum);
	st.cameraPos = mix(vec3(0.0), vec3(5.0, 5.0, -2.0), eio(t));
	st.cameraTarget = vec3(0.0, 0.0, 5.0);

	t = tl(time, 0.5, 1.0, st.sum);
	st.raySphereAlpha = mix(0.0, 1.0, t);
	st.cornersAlpha = mix(0.0, 1.0, t);

	t = tl(time, 0.5, 1.0, st.sum);
	st.cornersAnim = mix(0.0, 1.0, t);

	t = tl(time, 1.0, 1.0, st.sum);
	st.cameraPos = mix(st.cameraPos, vec3(2.0, 3.0, -3.0), eio(t));
	st.cameraTarget = mix(st.cameraTarget, vec3(0.0, 0.0, 3.0), eio(t));

	t = tl(time, 0.5, 0.5, st.sum);
	st.screenZAlpha = mix(0.0, 1.0, t);

	t = tl(time, 0.5, 0.5, st.sum);
	st.colToUv = mix(st.colToUv, 0.0, eio(t));

	t = tl(time, 0.5, 1.0, st.sum);
	st.screenZ = mix(st.screenZ, 5.0, eio(t));

	t = tl(time, 1.0, 1.0, st.sum);
	st.screenZ = mix(st.screenZ, 0.75, eio(t));

	t = tl(time, 1.0, 1.0, st.sum);
	st.screenZ = mix(st.screenZ, 2.5, eio(t));

	t = tl(time, 0.5, 1.0, st.sum);
	st.cornersAlpha = mix(st.cornersAlpha, 0.0, t);
	st.screenZAlpha = mix(st.screenZAlpha, 0.0, t);
	st.colToUv = mix(st.colToUv, 1.0, eio(t));

	t = tl(time, 0.0, 0.0, st.sum);
	st.cornersAnim = mix(st.cornersAnim, 0.0, t);

	t = tl(time, 0.5, 1.0, st.sum);
	st.cameraPos = mix(st.cameraPos, vec3(5.0, 15.0, 6.0), eio(t));
	st.cameraTarget = mix(st.cameraTarget, vec3(0.0, 0.0, 6.0), eio(t));

	for (int i = 0; i < 6; i++) {
		t = tl(time, 0.25, 0.25, st.sum);
		st.radiusAnim = mix(st.radiusAnim, float(i) + 2.0, t);
		t = tl(time, 0.25, 0.25, st.sum);
		st.routeAnim = mix(st.routeAnim, float(i) + 2.0, t);
		t = tl(time, 0.25, 0.25, st.sum);
		st.sphereAnim = mix(st.sphereAnim, float(i) + 2.0, t);
	}

	t = tl(time, 1.0, 1.0, st.sum);
	st.cameraPos = mix(st.cameraPos, vec3(2.0, 3.0, -3.0), eio(t));
	st.cameraTarget = mix(st.cameraTarget, vec3(0.0, 0.0, 3.0), eio(t));
	st.radiusAlpha = mix(st.radiusAlpha, 0.0, t);
	st.routeAnim = mix(st.routeAnim, 1.0, t);
	st.sphereAnim = mix(st.sphereAnim, 1.0, t);
	st.colToUv = mix(st.colToUv, 1.0, eio(t));
	st.screenAlpha = mix(st.screenAlpha, 0.0, t);

	t = tl(time, 0.5, 1.0, st.sum);
	st.rayDirectionAnim2 = mix(st.rayDirectionAnim2, 1.0, eio(t));

	t = tl(time, 0.5, 4.0, st.sum);
	st.rayDirectionAnim = mix(st.rayDirectionAnim, 1.0, t);

	t = tl(time, 0.5, 1.0, st.sum);
	st.raySphereAlpha = mix(st.raySphereAlpha, 0.0, t);
	st.rayDirectionAnim2 = mix(st.rayDirectionAnim2, 0.0, t);

	t = tl(time, 0.5, 1.0, st.sum);
	st.cameraPos = mix(st.cameraPos, vec3(0.0), eio(t));
	st.cameraTarget = mix(st.cameraTarget, vec3(0.0, 0.0, 5.0), eio(t));
}

vec2 opU(vec2 a, vec2 b) {
	return a.x < b.x ? a : b;
}

float sdLine(vec3 p, vec3 a, vec3 b, float r) {
	vec3 pa = p - a, ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

float sdBox(vec3 p, vec3 b) {
	vec3 d = abs(p) - b;
	return length(max(d, 0.0)) + min(max(d.x, max(d.y, d.z)), 0.0);
}

float sdSphere(vec3 p, float s) {
	return length(p) - s;
}

const vec3 sunDir = vec3(0.67267, 0.56056, 0.44845); // normalized vec3(0.3, 0.25, 0.2)

vec3 skyColor(vec3 rd) {
	float sundot = clamp(dot(rd, sunDir), 0.0, 1.0);
	vec3 col = mix(vec3(0.2, 0.5, 0.85) * 1.1, vec3(0.0, 0.15, 0.7), rd.y);
	col = mix(col, 0.85 * vec3(0.8, 0.8, 0.7), pow(1.0 - max(rd.y, 0.0), 4.0));
	col += 0.3 * vec3(1.0, 0.7, 0.4) * pow(sundot, 5.0);
	col += 0.5 * vec3(1.0, 0.8, 0.6) * pow(sundot, 64.0);
	col += 6.0 * vec3(1.0, 0.8, 0.6) * pow(sundot, 1024.0);
	return col * 3.0;
}

vec2 sceneSpheres(vec3 p) {
	vec2 s1 = vec2(sdSphere(p - vec3(-2.0, 0.0, 6.0), 1.0), MAT_SPHERE1);
	vec2 s2 = vec2(sdSphere(p - vec3(0.0, 0.0, 12.0), 1.0), MAT_SPHERE2);
	vec2 s3 = vec2(sdSphere(p - vec3(2.0, 0.0, 9.0), 1.0), MAT_SPHERE3);
	return opU(opU(s1, s2), s3);
}

vec2 sceneMap(vec3 p) {
	vec2 s = sceneSpheres(p);
	vec2 p1 = vec2(p.y + 2.0, MAT_FLOOR);
	return opU(s, p1);
}

vec3 get_scene_normal(vec3 p) {
	vec2 e = vec2(0.001, 0.0);
	float d = sceneMap(p).x;
	return normalize(d - vec3(sceneMap(p - e.xyy).x, sceneMap(p - e.yxy).x, sceneMap(p - e.yyx).x));
}

void sceneTrace(inout vec3 pos, vec3 ray, out vec2 mat, inout float depth, float maxD) {
	vec3 ro = pos;
	for (int i = 0; i < 70; i++) {
		if (depth > maxD) {
			depth = maxD;
			break;
		}
		pos = ro + ray * depth;
		mat = sceneMap(pos);
		if (mat.x < 0.001) {
			break;
		}
		depth += mat.x;
	}
}

vec2 screenMap(vec3 p, vec2 iResolution, float screenZ) {
	vec2 screenSize = iResolution.xy / min(iResolution.x, iResolution.y);
	vec2 b1 = vec2(sdBox(p - vec3(0.0, 0.0, screenZ), vec3(screenSize, 0.01)), MAT_SCREEN);
	return b1;
}

void screenTrace(inout vec3 pos, vec3 ray, out vec2 mat, inout float depth, float maxD, vec2 iResolution, float screenZ) {
	vec3 ro = pos;
	for (int i = 0; i < 20; i++) {
		if (depth > maxD) {
			depth = maxD;
			break;
		}
		pos = ro + ray * depth;
		mat = screenMap(pos, iResolution, screenZ);
		if (mat.x < 0.001) {
			break;
		}
		depth += mat.x;
	}
}

float remap(float val, float im, float ix, float om, float ox) {
	return clamp(om + (val - im) * (ox - om) / (ix - im), om, ox);
}

vec2 gizmoCorners(vec3 p, vec2 iResolution, inout TimelineState st) {
	vec2 screenSize = iResolution.xy / min(iResolution.x, iResolution.y);
	float a1 = remap(st.cornersAnim, 0.0, 0.25, 0.0, 1.0);
	float a2 = remap(st.cornersAnim, 0.25, 0.5, 0.0, 1.0);
	float a3 = remap(st.cornersAnim, 0.5, 0.75, 0.0, 1.0);
	float a4 = remap(st.cornersAnim, 0.75, 1.0, 0.0, 1.0);

	vec2 c1 = vec2(sdLine(p, vec3(0.0), mix(vec3(0.0), vec3(screenSize, st.screenZ), a1), 0.02), MAT_CORNER);
	vec2 c2 = vec2(sdLine(p, vec3(0.0), mix(vec3(0.0), vec3(screenSize * vec2(1.0, -1.0), st.screenZ), a2), 0.02), MAT_CORNER);
	vec2 c3 = vec2(sdLine(p, vec3(0.0), mix(vec3(0.0), vec3(screenSize * vec2(-1.0, -1.0), st.screenZ), a3), 0.02), MAT_CORNER);
	vec2 c4 = vec2(sdLine(p, vec3(0.0), mix(vec3(0.0), vec3(screenSize * vec2(-1.0, 1.0), st.screenZ), a4), 0.02), MAT_CORNER);
	return opU(c1, opU(c2, opU(c3, c4)));
}

vec2 gizmoScreenZ(vec3 p, inout TimelineState st) {
	return vec2(sdLine(p, vec3(0.0), vec3(0.0, 0.0, st.screenZ), 0.03), MAT_SCREENZ);
}

vec2 gizmoMarching(vec3 p, inout TimelineState st) {
	vec3 ray = vec3(0.0, 0.0, 1.0);
	vec2 d = vec2(10000.0);
	float t = 0.0;
	for (int i = 0; i < 7; i++) {
		vec3 pos = ray * t;
		vec2 s = vec2(sdSphere(p - pos, 0.15), MAT_MARCHSPHERE);
		if (s.x < d.x) {
			d = s;
			st.sphereID = float(i);
		}
		float dist = sceneSpheres(pos).x;
		float anim = clamp(st.routeAnim - float(i) - 1.0, 0.0, 1.0);
		vec2 c1 = vec2(sdLine(p, pos, pos + mix(vec3(0.0), ray * dist, anim), 0.03), MAT_MARCHROUTE);
		d = opU(d, c1);
		t += dist;
	}
	return d;
}

vec2 gizmoRayDirection(vec3 p, vec2 iResolution, inout TimelineState st) {
	float a1 = fract(st.rayDirectionAnim * 19.99999);
	float a2 = floor(st.rayDirectionAnim * 19.99999) / 20.0;
	vec2 screenSize = iResolution.xy / min(iResolution.x, iResolution.y);
	screenSize.y *= -1.0;
	screenSize = mix(-screenSize, screenSize, vec2(a1, a2));
	vec2 c1 = vec2(sdLine(p, vec3(0.0), mix(vec3(0.0), vec3(screenSize, st.screenZ) * 10.0, st.rayDirectionAnim2), 0.02), MAT_RAYDIRECTION);

	vec3 ray = normalize(vec3(screenSize, st.screenZ));
	vec3 pos = vec3(0.0);
	float t = 0.01;
	for (int i = 0; i < 20; i++) {
		pos = ray * t;
		vec2 d = sceneMap(pos);
		t += d.x;
	}
	c1 = opU(c1, vec2(sdSphere(p - pos, 0.3), MAT_HITPOINT));
	return c1;
}

vec2 gizmoMap(vec3 p, vec2 iResolution, inout TimelineState st) {
	vec2 d = opU(gizmoCorners(p, iResolution, st), gizmoScreenZ(p, st));
	d = opU(d, gizmoMarching(p, st));
	d = opU(d, gizmoRayDirection(p, iResolution, st));
	return d;
}

void gizmoTrace(inout vec3 pos, vec3 ray, out vec2 mat, inout float depth, float maxD, vec2 iResolution, inout TimelineState st) {
	vec3 ro = pos;
	for (int i = 0; i < 60; i++) {
		if (depth > maxD) {
			depth = maxD;
			break;
		}
		pos = ro + ray * depth;
		mat = gizmoMap(pos, iResolution, st);
		if (mat.x < 0.001) {
			break;
		}
		depth += mat.x;
	}
}

void radiusTrace(inout vec3 pos, vec3 ray, out vec2 mat, inout float depth, float maxD) {
	vec3 ro = pos;
	for (int i = 0; i < 40; i++) {
		if (depth > maxD) {
			depth = maxD;
			break;
		}
		pos = ro + ray * depth;
		mat = vec2(pos.y, MAT_MARCHRADIUS);
		if (mat.x < 0.001 || depth > maxD) {
			break;
		}
		depth += mat.x;
	}
}

float shadow(vec3 p, vec3 l, float ma, vec2 iResolution, float screenZ) {
	float t = 0.1;
	float res = 1.0;
	for (int i = 0; i < 16; ++i) {
		if (t > ma) break;
		vec3 pos = p + t * l;
		float d = opU(sceneMap(pos), screenMap(pos, iResolution, screenZ)).x;
		if (d < 0.001) {
			return 0.0;
		}
		t += d * 1.0;
		res = min(res, 10.0 * d / t);
	}
	return res;
}

float checkersTextureGradBox(vec2 p, vec2 ddx, vec2 ddy) {
	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;
	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;
	return 0.5 - 0.5 * i.x * i.y;
}

vec3 sceneShade(vec2 mat, vec3 pos, vec3 ray, float depth, float maxD, vec2 iResolution, float screenZ) {
	vec3 sky = skyColor(ray);
	if (depth > maxD - 0.01) {
		return sky;
	}
	float sha = shadow(pos, sunDir, 10.0, iResolution, screenZ);
	vec3 norm = get_scene_normal(pos);
	vec3 albedo = vec3(0.0);
	if (mat.y == MAT_SPHERE1) {
		albedo = vec3(1.0, 0.0, 0.0);
	} else if (mat.y == MAT_SPHERE2) {
		albedo = vec3(0.0, 1.0, 0.0);
	} else if (mat.y == MAT_SPHERE3) {
		albedo = vec3(0.0, 0.0, 1.0);
	} else if (mat.y == MAT_FLOOR) {
		vec2 ddx_uvw = dFdx(pos.xz);
		vec2 ddy_uvw = dFdy(pos.xz);
		float checker = checkersTextureGradBox(pos.xz, ddx_uvw, ddy_uvw);
		albedo = vec3(max(0.2, checker)) * vec3(0.8, 0.8, 0.7) * 2.0;
	}

	float diffuse = clamp(dot(norm, sunDir), 0.0, 1.0) * sha * 2.0;
	vec3 col = albedo * (diffuse + 0.05);
	float fo = 1.0 - exp2(-0.0001 * depth * depth);
	return mix(col, sky, fo);
}

vec3 screenShade(vec2 mat, vec3 pos, vec2 iResolution, inout TimelineState st) {
	vec3 ro = vec3(0.0);
	vec3 ta = vec3(0.0, 0.0, 3.0);
	vec3 fo = normalize(ta - ro);
	vec3 ri = normalize(cross(vec3(0.0, 1.0, 0.0), fo));
	vec3 up = normalize(cross(fo, ri));
	mat3 cam = mat3(ri, up, fo);
	vec3 ray = cam * normalize(pos);
	float depth = 0.01;
	vec3 p = ro;
	sceneTrace(p, ray, mat, depth, 100.0);
	vec3 col = sceneShade(mat, p, ray, depth, 100.0, iResolution, st.screenZ);

	float a1 = fract(st.rayDirectionAnim * 19.99999);
	float a2 = floor(st.rayDirectionAnim * 19.99999 + 1.0) / 20.0;
	float a3 = floor(st.rayDirectionAnim * 19.99999) / 20.0;

	float aspect = iResolution.y / iResolution.x;
	float halfAspect = aspect * 0.5;

	a1 = step(pos.x * halfAspect + 0.5, a1);
	a2 = step(-pos.y * 0.49 + 0.51, a2);
	a3 = step(-pos.y * 0.49 + 0.51, a3);

	vec2 uvClamped = clamp(mix(pos.xy * 0.5 + 0.5, pos.xy, st.uvToP), 0.0, 1.0);
	vec3 uvCoord = vec3(pow(uvClamped, vec2(2.2)), 0.0);
	col = mix(col, uvCoord, st.colToUv - min(st.screenAlpha + min(a2 * a1 + a3, 1.0), 1.0));
	return col;
}

vec4 gizmoShade(vec2 mat, inout TimelineState st) {
	vec4 col = vec4(0.0);
	if (mat.y == MAT_CORNER) {
		col = vec4(1.0, 0.0, 0.0, st.cornersAlpha);
	} else if (mat.y == MAT_SCREENZ) {
		col = vec4(0.05, 0.05, 1.0, st.screenZAlpha);
	} else if (mat.y == MAT_MARCHSPHERE) {
		float alpha = clamp(st.sphereAnim - st.sphereID, 0.0, 1.0);
		vec3 sc = mix(vec3(0.0, 0.1, 3.0), vec3(0.02, 1.0, 0.02), float(st.sphereID == 0.0 || st.sphereID == 6.0));
		col = vec4(sc, alpha * st.raySphereAlpha);
	} else if (mat.y == MAT_MARCHROUTE) {
		col = vec4(1.0, 0.0, 0.0, 0.9);
	} else if (mat.y == MAT_RAYDIRECTION) {
		col = vec4(1.0, 0.0, 0.0, 0.9);
	} else if (mat.y == MAT_HITPOINT) {
		col = vec4(0.02, 1.0, 0.02, st.raySphereAlpha);
	}
	return col;
}

vec4 radiusShade(vec3 p, inout TimelineState st) {
	vec4 col = vec4(0.0);
	vec3 ray = vec3(0.0, 0.0, 1.0);
	float t = 0.0;
	for (int i = 0; i < 7; i++) {
		vec3 pos = ray * t;
		vec2 dd = sceneSpheres(pos);
		vec2 d = vec2(sdSphere(p - pos, dd.x), MAT_MARCHSPHERE);
		float alpha2 = step(st.radiusAnim, float(i) + 2.0);
		float alpha = clamp(st.radiusAnim - float(i) - 1.0, 0.0, 1.0);

		vec4 cirCol = mix(vec4(0.0, 0.05, 0.1, 0.9), vec4(0.2, 1.0, 1.4, 0.6), alpha2);
		col = mix(col, cirCol, smoothstep(0.01, 0.0, d.x) * cirCol.a * alpha);
		col = mix(col, vec4(0.0, 0.0, 0.0, 1.0), smoothstep(0.02, 0.0, abs(d.x) - 0.01) * alpha);
		t += dd.x;
	}
	col *= st.radiusAlpha;
	return col;
}

vec3 reinhard(vec3 col, float exposure, float white) {
	col *= exposure;
	white *= exposure;
	float lum = dot(vec3(0.298912, 0.586611, 0.114478), col);
	return (col * (lum / (white * white) + 1.0) / (lum + 1.0));
}

vec3 render_scene(vec2 p, vec2 iResolution, inout TimelineState st) {
	vec3 screenPos = vec3(p, 2.5);
	vec3 ro = st.cameraPos;
	vec3 ta = st.cameraTarget;
	vec3 fo = normalize(ta - ro);
	vec3 ri = normalize(cross(vec3(0.0, 1.0, 0.0), fo));
	vec3 up = normalize(cross(fo, ri));
	mat3 cam = mat3(ri, up, fo);
	vec3 ray = cam * normalize(screenPos);
	float depth = 0.01;
	vec2 mat;
	vec3 pos = ro;

	sceneTrace(pos, ray, mat, depth, 100.0);
	vec3 col = sceneShade(mat, pos, ray, depth, 100.0, iResolution, st.screenZ);

	float sceneDepth = depth;
	depth = 0.01;
	pos = ro;
	screenTrace(pos, ray, mat, depth, sceneDepth, iResolution, st.screenZ);
	if (depth < sceneDepth) {
		col = screenShade(mat, pos, iResolution, st);
	}

	float sceneAndScreenDepth = depth;
	depth = 0.01;
	pos = ro;
	radiusTrace(pos, ray, mat, depth, sceneAndScreenDepth);
	if (depth < sceneAndScreenDepth) {
		vec4 rad = radiusShade(pos, st);
		col = mix(col, rad.rgb, rad.a);
	}

	float sceneAndScreenAndGizmoDepth = sceneAndScreenDepth;
	depth = 0.01;
	pos = ro;
	gizmoTrace(pos, ray, mat, depth, sceneAndScreenAndGizmoDepth, iResolution, st);
	if (depth < sceneAndScreenAndGizmoDepth) {
		vec4 gizmo = gizmoShade(mat, st);
		col = mix(col, gizmo.rgb, gizmo.a);
	}
	return col;
}

void fragment() {
	vec2 iResolution = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 fragCoord = FRAGCOORD.xy;
	TimelineState st;
	init_timeline(st, mod(TIME, 41.0));

	vec3 col = vec3(0.0);
	for (int y = 0; y < 2; y++) {
		for (int x = 0; x < 2; x++) {
			vec2 off = vec2(float(x), float(y)) * 0.5;
			vec2 xy = (-iResolution.xy + 2.0 * (fragCoord + off)) / iResolution.y;
			col += render_scene(xy, iResolution, st) * 0.25;
		}
	}
	col = reinhard(col, 1.0, 1000.0);
	col = pow(col, vec3(1.0 / 2.2));
	COLOR = vec4(col, 1.0);
}
