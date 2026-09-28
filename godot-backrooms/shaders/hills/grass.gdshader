shader_type spatial;
render_mode cull_disabled;

// Base gradient
uniform vec3 bottom_color : source_color;
uniform vec3 top_color : source_color;

// Color variations and noise
uniform vec3 color_variation_1 : source_color;
uniform sampler2D noise_variation_1;
uniform float Noise1Scale = 20.0;

uniform vec3 color_variation_2 : source_color;
uniform sampler2D noise_variation_2;
uniform float Noise2Scale = 20.0;

// Wind & displacement
uniform float windSpeed = 0.005;
uniform float windDis = 0.2;
uniform float noiseStrength = 0.5;
uniform float displaceStrength = 3.0;

// Wind noise texture
uniform sampler2D wind_noise;
uniform float windNoiseScale = 20.0;
uniform vec2 windNoisePanSpeed = vec2(0.03, 0.03);
uniform float noiseFloor = 0.3;
uniform float wind_noise_scale_strength = 0.2;

// Wind Shadow
uniform vec3 wind_shadow_color : source_color = vec3(0.0, 0.2, 0.0);
uniform float wind_shadow_strength = 0.4;
uniform float flatten_shadow_strength = 0.7;
uniform float wind_shadow_displacement_threshold = 0.15;
uniform float wind_shadow_smoothing = 0.3;

// Flattening
uniform vec3 interracting_object_pos = vec3(0.0, 0.0, 0.0);
uniform float flatten_radius = 0.75;
uniform float flatten_strength = 3.0;
uniform float flatten_floor = 0.3;

// Noise-based vertical scale
uniform float combined_noise_min_scale = 0.5;
uniform float combined_noise_max_scale = 1.5;
uniform bool invert_combined_noise = false;

// Debug toggles
uniform bool debug_show_wind_noise = false;
uniform bool debug_show_combined_noise = false;


varying vec3 worldPos;
varying float wind_displacement_strength;
varying float flatten_amount_for_overlay;
varying float combinedNoiseDebug;

void vertex() {
    worldPos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 instance_world_origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;

    // Combined noise from two textures
    vec2 uv1 = worldPos.xz / Noise1Scale;
    vec2 uv2 = worldPos.xz / Noise2Scale;
    float noise1 = texture(noise_variation_1, uv1).r;
    float noise2 = texture(noise_variation_2, uv2).r;
    float combinedNoise = clamp((0.5 + noise1) * noise2, 0.0, 1.0);
    if (invert_combined_noise) {
        combinedNoise = 1.0 - combinedNoise;
    }
    combinedNoiseDebug = combinedNoise;

    // Panning wind noise for vertical scale influence
    vec2 windNoiseUV = instance_world_origin.xz / windNoiseScale + windNoisePanSpeed * TIME;
    float windNoiseVal = texture(wind_noise, windNoiseUV).r;
    float windVerticalOffset = mix(-wind_noise_scale_strength, wind_noise_scale_strength, windNoiseVal);

    // Final noise-based vertical scale
    float verticalScaleNoise = mix(combined_noise_min_scale, combined_noise_max_scale, 1.0 - combinedNoise);
    float finalVerticalScale = verticalScaleNoise + windVerticalOffset;

    // Flattening
    float distToImpact = distance(worldPos, interracting_object_pos);
    float flattenFactor = clamp(1.0 - (distToImpact / flatten_radius), 0.0, 1.0);
    float flattenAmount = flattenFactor * flatten_strength;
    flatten_amount_for_overlay = flattenAmount;

    float flattenScale = mix(1.0, flatten_floor, flattenAmount);
    finalVerticalScale *= flattenScale;
    VERTEX.y *= finalVerticalScale;

    // Wind sway
    float shapedNoise = 0.0;
    float noiseVal = texture(wind_noise, windNoiseUV).r;
    float bias = noiseVal - 0.5;
    if (bias < 0.0) {
        shapedNoise = mix(0.0, noiseFloor - 0.5, -bias * 2.0);
    } else {
        shapedNoise = bias * bias * 2.0;
    }

    float instanceWindSpeed = max(0.0, windSpeed * (1.0 - shapedNoise * noiseStrength));
    float windResponse = 1.0 - flattenAmount;
    float instanceWindDis = windDis * (1.0 + shapedNoise * displaceStrength) * windResponse;
    wind_displacement_strength = instanceWindDis;

    float sineValue = sin(TIME * instanceWindSpeed);
    float heightFactor = clamp(UV.y, 0.0, 1.0);

    vec2 windDir = normalize(windNoisePanSpeed);
    if (length(windNoisePanSpeed) < 0.001) {
        windDir = vec2(1.0, 0.0);
    }

    vec2 sway = windDir * sineValue * instanceWindDis * (1.0 - heightFactor);
    VERTEX.x += sway.x;
    VERTEX.z += sway.y;
}

void fragment() {
    float heightFactor = clamp(UV.y, 0.0, 1.0);

    if (debug_show_combined_noise) {
        ALBEDO = vec3(combinedNoiseDebug);
    } else if (debug_show_wind_noise) {
        vec2 noiseUV = worldPos.xz / windNoiseScale + windNoisePanSpeed * TIME;
        float noiseVal = texture(wind_noise, noiseUV).r;
        ALBEDO = vec3(noiseVal);
    } else {
        vec3 baseGradient = mix(top_color, bottom_color, heightFactor);

        vec3 altGradient1 = mix(color_variation_1, bottom_color, heightFactor);
        float blendVal1 = texture(noise_variation_1, worldPos.xz / Noise1Scale).r;
        vec3 firstBlend = mix(baseGradient, altGradient1, blendVal1);

        vec3 altGradient2 = mix(color_variation_2, bottom_color, heightFactor);
        float blendVal2 = texture(noise_variation_2, worldPos.xz / Noise2Scale).r;
        vec3 finalBlend = mix(firstBlend, altGradient2, blendVal2);

        float noiseFactor = texture(wind_noise, worldPos.xz / windNoiseScale).r;
        finalBlend *= mix(0.9, 1.1, noiseFactor);

        float displace_fade = smoothstep(
            wind_shadow_displacement_threshold,
            wind_shadow_displacement_threshold + wind_shadow_smoothing,
            wind_displacement_strength
        );

        float flatten_fade = smoothstep(0.0, 1.0, flatten_amount_for_overlay);
        float total_overlay_strength = clamp(
            displace_fade * wind_shadow_strength +
            flatten_fade * flatten_shadow_strength,
            0.0, 1.0
        );

        vec3 tint = mix(vec3(1.0), wind_shadow_color, total_overlay_strength);
        finalBlend = mix(finalBlend, finalBlend * tint, total_overlay_strength);

        ALBEDO = finalBlend;
    }

    if (!FRONT_FACING) {
        NORMAL = -NORMAL;
    }
}
