#include <metal_stdlib>
using namespace metal;

// Bubble frame: the bubble is the unit sphere at the origin. Normally that is the phone's
// frame (+Y toward the top of the phone, +Z out of the screen, camera at (0, 0, camera.y));
// in AR it is the anchored bubble's frame and `viewProj`/`eye` come from ARKit.

struct Uniforms {
    float4x4 attitude;   // bubble frame → physics world (Z up)
    float4x4 viewProj;   // bubble frame → clip
    float4 viewport;     // width, height, bubble centre x, y (pixels)
    float4 camera;       // focal (px, phone mode), camera distance, time (s), EDR headroom
    float4 gravity;      // bubble-frame direction of fall, |g| in g
    float4 jiggle;       // quadrupole deformation, breathing
    float4 film;         // drain strength, swirl speed, north azimuth (world), has north
    float4 post;         // bloom, scanlines, chromatic aberration, reduce motion
    float4 lightA;       // bubble-frame light direction (anchored in the world), intensity
    float4 lightB;
    float4 misc;         // bubble radius (px), scan band height, flicker, has AR environment probe
    float4 eye;          // camera position in the bubble frame, AR flag
    float4 camA;         // view → camera-image transform: a, b, c, d
    float4 camB;         // tx, ty, sound shimmer on the film, —
    float4 ripples[4];   // bubble-frame direction, age (s); age < 0 = unused
};

struct LineInstance {
    float4 a;   // xyz, width (px)
    float4 b;
    float4 ca;  // rgb × intensity, alpha
    float4 cb;
};

struct MeshVertex {
    float4 position;
    float4 normal;
};

struct MeshUniforms {
    float4x4 model;      // part → bubble frame
    float4x4 normalModel; // inverse transpose of `model`, for stretched parts
    float4 material;     // roughness, anisotropy, iridescence, glow
    float4 base;         // base reflectance, emissive boost
    float4 spinCenter;   // object centre (bubble frame), w = 1 for circular brushing
    float4 spinAxis;     // spin axis, w = pattern: 0 metal, 1 machined (lathe marks), 2 planet, 3 planet ring
    float4 spinU;        // a direction ⟂ the axis that turns with the object, w = angle swept this frame
    float4 extra;        // object size, then per object: glass refraction, frost, dispersion
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
constexpr sampler cubeSampler(filter::linear, mip_filter::linear);
constexpr sampler mipClamp(filter::linear, mip_filter::linear, address::clamp_to_edge);

// MARK: - Helpers

static inline float3 toWorld(float3 v, constant Uniforms& u) {
    return (u.attitude * float4(v, 0.0)).xyz;
}

static float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

static float vnoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash13(i);
    float b = hash13(i + float3(1, 0, 0));
    float c = hash13(i + float3(0, 1, 0));
    float d = hash13(i + float3(1, 1, 0));
    float e = hash13(i + float3(0, 0, 1));
    float g = hash13(i + float3(1, 0, 1));
    float h = hash13(i + float3(0, 1, 1));
    float k = hash13(i + float3(1, 1, 1));
    return mix(mix(mix(a, b, f.x), mix(c, d, f.x), f.y), mix(mix(e, g, f.x), mix(h, k, f.x), f.y), f.z);
}

static float fbm(float3 p) {
    return 0.55 * vnoise(p) + 0.30 * vnoise(p * 2.03 + 11.7) + 0.15 * vnoise(p * 4.07 + 3.1);
}

static float lineMask(float coord, float spacing, float fw) {
    float d = abs(fract(coord / spacing + 0.5) - 0.5) * spacing;
    return 1.0 - smoothstep(0.0, fw * 1.2 + 1e-5, d);
}

/// The world outside: a dark sky over a darker floor, a glowing horizon and a 15° grid,
/// all fixed in the world, so the phone is a window you look through.
static float3 sky(float3 d, constant Uniforms& u) {
    const float twoPi = 2.0 * M_PI_F;
    float z = clamp(d.z, -1.0, 1.0);
    float lat = asin(z);
    float lon = atan2(d.y, d.x);
    float fwLat = fwidth(lat);
    float lonAlt = fract(lon / twoPi + 1.0) * twoPi;
    float fwLon = min(fwidth(lon), fwidth(lonAlt));

    float3 skyTop = float3(0.003, 0.006, 0.022);
    float3 skyHorizon = float3(0.018, 0.030, 0.075);
    float3 groundHorizon = float3(0.020, 0.012, 0.032);
    float3 groundLow = float3(0.002, 0.002, 0.005);
    float3 c = z >= 0.0 ? mix(skyHorizon, skyTop, sqrt(z)) : mix(groundHorizon, groundLow, pow(-z, 0.45));
    c += float3(0.05, 0.075, 0.16) * exp(-abs(z) * 38.0);

    float spacing = M_PI_F / 12.0;
    float poleFade = 1.0 - smoothstep(0.86, 0.97, abs(z));
    float lat15 = lineMask(lat, spacing, fwLat);
    float lon15 = lineMask(lon, spacing, fwLon) * poleFade;
    float lon90 = lineMask(lon, M_PI_F * 0.5, fwLon) * poleFade;
    float3 lineColor = z >= 0.0 ? float3(0.035, 0.065, 0.15) : float3(0.07, 0.035, 0.11);
    c += lineColor * max(lat15, lon15) + lineColor * 0.25 * lon90;
    c += float3(0.10, 0.16, 0.32) * (1.0 - smoothstep(0.0, fwLat * 1.5 + 1e-5, abs(lat)));

    if (u.film.w > 0.5) {
        float dl = lon - u.film.z;
        dl -= twoPi * round(dl / twoPi);
        float north = 1.0 - smoothstep(0.0, fwLon * 1.6 + 1e-5, abs(dl));
        c += float3(0.30, 0.06, 0.10) * north * (1.0 - smoothstep(0.06, 0.3, abs(z)));
    }
    return c;
}

/// A holographic studio fixed in the room, for the metal to reflect: soft horizon glow,
/// three softboxes and a magenta strip light. Tilt the phone and the reflections slide.
static float3 studio(float3 d) {
    float z = d.z;
    float3 c = mix(float3(0.012, 0.010, 0.026), float3(0.05, 0.07, 0.16), smoothstep(-0.4, 0.7, z));
    c += float3(0.22, 0.50, 0.85) * exp(-abs(z) * 12.0) * 0.45;
    c += float3(1.7, 1.8, 2.0) * smoothstep(0.93, 0.975, dot(d, normalize(float3(0.3, -0.45, 0.84))));
    c += float3(1.0, 0.55, 1.7) * smoothstep(0.95, 0.985, dot(d, normalize(float3(-0.8, 0.45, 0.25))));
    c += float3(0.45, 1.4, 1.5) * smoothstep(0.96, 0.99, dot(d, normalize(float3(0.55, 0.8, -0.1))));
    float2 stripDir = float2(cos(2.4), sin(2.4));
    float across = abs(dot(d.xy, float2(-stripDir.y, stripDir.x)));
    float facing = step(0.0, dot(d.xy, stripDir));
    c += float3(1.3, 0.35, 0.95) * smoothstep(0.05, 0.0, across) * facing * smoothstep(0.7, 0.1, abs(z));
    float lat = asin(clamp(z, -1.0, 1.0));
    float lon = atan2(d.y, d.x);
    float g = max(smoothstep(0.012, 0.0, abs(fract(lat / 0.2618 + 0.5) - 0.5) * 0.2618),
                  smoothstep(0.012, 0.0, abs(fract(lon / 0.2618 + 0.5) - 0.5) * 0.2618) * (1.0 - abs(z)));
    c += float3(0.04, 0.09, 0.18) * g;
    return c;
}

/// Camera image at a screen position, decoded from ARKit's YCbCr planes to linear RGB.
static float3 cameraColor(float2 uv, texture2d<float> luma, texture2d<float> chroma, constant Uniforms& u) {
    float2 img = float2(u.camA.x * uv.x + u.camA.z * uv.y + u.camB.x, u.camA.y * uv.x + u.camA.w * uv.y + u.camB.y);
    float y = luma.sample(linearClamp, img).r;
    float2 c = chroma.sample(linearClamp, img).rg - 0.5;
    float3 rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
    return pow(saturate(rgb), float3(2.2));
}

/// What a surface facing `r` (bubble frame) reflects, blurred by roughness and smeared
/// along `streak` (brushed metal stretches reflections across its grooves): ARKit's
/// environment probe of the real room in AR, the holographic studio otherwise.
static float3 environment(float3 r, float rough, float3 streak, constant Uniforms& u, texturecube<float> probe) {
    float3 w = normalize(toWorld(r, u));
    float3 sw = toWorld(streak, u);
    sw -= dot(sw, w) * w;
    float3 t1 = length(sw) > 1e-4 ? normalize(sw) : normalize(cross(w, abs(w.z) < 0.9 ? float3(0, 0, 1) : float3(1, 0, 0)));
    float3 t2 = cross(w, t1);
    float along = rough * 0.7 + length(streak);
    float across = rough * 0.7;
    float3 taps[7] = { w, w + t1 * along, w - t1 * along, w + t1 * along * 0.5, w - t1 * along * 0.5,
                       w + t2 * across, w - t2 * across };
    float weights[7] = { 0.28, 0.1, 0.1, 0.16, 0.16, 0.1, 0.1 };
    float3 c = 0.0;
    for (int i = 0; i < 7; i++) {
        float3 d = normalize(taps[i]);
        if (u.misc.w > 0.5) {
            c += probe.sample(cubeSampler, float3(d.x, d.z, -d.y), level(rough * 7.0)).rgb * 1.3 * weights[i];
        } else {
            c += studio(d) * weights[i];
        }
    }
    return c;
}

// MARK: - Fullscreen

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 backgroundFragment(FSOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 px = in.position.xy;
    float f = u.camera.x;
    float3 ray = normalize(float3((px.x - u.viewport.z) / f, -(px.y - u.viewport.w) / f, -1.0));
    float3 c = sky(toWorld(ray, u), u);
    float2 rel = (px - u.viewport.zw) / max(u.misc.x, 1.0);
    c += float3(0.010, 0.030, 0.060) * exp(-dot(rel, rel) * 0.55);
    float2 q = in.uv - 0.5;
    c *= 1.0 - dot(q, q) * 0.8;
    return float4(c, 1.0);
}

// MARK: - Bubble

struct BubbleOut {
    float4 position [[position]];
    float3 pos;
    float3 normal;
    float wave;
};

vertex BubbleOut bubbleVertex(uint vid [[vertex_id]],
                              const device float4* verts [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    float3 n = verts[vid].xyz;
    float a = length(u.jiggle.xyz);
    float3 axis = a > 1e-5 ? u.jiggle.xyz / a : float3(0, 1, 0);
    float c = dot(n, axis);
    float r = 1.0 + a * (1.5 * c * c - 0.5) + u.jiggle.w;
    float wave = 0.0;
    for (int i = 0; i < 4; i++) {
        float4 rp = u.ripples[i];
        if (rp.w < 0.0) continue;
        float x = acos(clamp(dot(n, rp.xyz), -1.0, 1.0)) - rp.w * 1.7;
        wave += sin(x * 16.0) * exp(-x * x * 9.0) * exp(-rp.w * 1.6);
    }
    r += wave * 0.018;
    float3 p = n * r;
    BubbleOut o;
    o.position = u.viewProj * float4(p, 1.0);
    o.pos = p;
    o.normal = n;
    o.wave = wave;
    return o;
}

/// Soap-film interference: reflectance at red, green and blue for a film whose thickness
/// drains toward gravity, swirls with time, sloshes with the wobble and shivers with sound.
static float3 filmInterference(float3 n, float cosI, constant Uniforms& u) {
    float t = u.camera.z;
    float swirl = u.film.y;
    float3 q = n * 1.7 + u.jiggle.xyz * 4.0;
    float n1 = fbm(q * 1.3 + float3(0.0, 0.0, t * 0.07 * swirl));
    float n2 = fbm(q * 2.7 - float3(t * 0.05 * swirl, 0.0, 0.0));
    float drain = dot(n, u.gravity.xyz) * min(abs(u.gravity.w), 2.0) * u.film.x;
    float shiver = u.camB.z * 240.0 * sin(dot(n, float3(9.0, 7.0, 11.0)) + t * 31.0);
    float thickness = max(420.0 + 300.0 * drain + 260.0 * (n1 - 0.5) + 120.0 * (n2 - 0.5) + shiver, 15.0);
    float sinT2 = (1.0 - cosI * cosI) / (1.33 * 1.33);
    float cosT = sqrt(max(1.0 - sinT2, 0.0));
    float3 phase = 4.0 * M_PI_F * 1.33 * thickness * cosT / float3(640.0, 530.0, 450.0);
    return 0.5 - 0.5 * cos(phase);
}

fragment float4 bubbleFilmFragment(BubbleOut in [[stage_in]],
                                   bool front [[front_facing]],
                                   constant Uniforms& u [[buffer(0)]],
                                   texturecube<float> probe [[texture(0)]],
                                   texture2d<float> luma [[texture(1)]],
                                   texture2d<float> chroma [[texture(2)]]) {
    float3 n = normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float3 N = front ? n : -n;
    float cosI = saturate(dot(N, V));
    float3 film = filmInterference(n, cosI, u);
    float fresnel = 0.02 + 0.98 * pow(1.0 - cosI, 4.5);

    float3 R = reflect(-V, N);
    float3 env;
    if (u.eye.w > 0.5) {
        if (u.misc.w > 0.5) {
            env = environment(R, 0.05, 0.0, u, probe) * 0.8;
        } else {
            float2 uv = in.position.xy / u.viewport.xy;
            float2 centre = u.viewport.zw / u.viewport.xy;
            env = cameraColor(centre - (uv - centre) * 1.4, luma, chroma, u) * 0.6;
        }
    } else {
        env = sky(toWorld(R, u), u) * 5.0;
    }

    float3 H1 = normalize(u.lightA.xyz + V);
    float3 H2 = normalize(u.lightB.xyz + V);
    float nh1 = saturate(dot(N, H1));
    float nh2 = saturate(dot(N, H2));
    float spec = pow(nh1, 1400.0) * u.lightA.w + pow(nh1, 90.0) * 0.012 + pow(nh2, 900.0) * u.lightB.w;

    float3 color = film * (fresnel * 0.8 + 0.002 + u.camB.z * 0.05) * float3(0.92, 0.97, 1.1);
    color += env * fresnel * 0.3;
    color += spec * (0.5 + 0.8 * film);
    color += float3(0.04, 0.10, 0.20) * pow(1.0 - cosI, 6.0);
    color *= 1.0 + in.wave * 3.0;
    color *= front ? 1.0 : 0.5;
    return float4(max(color, 0.0), 1.0);
}

/// Liquid Glass-style lensing at the bubble's rim: the world behind bends inward. In AR
/// that world is the camera image.
fragment float4 bubbleLensFragment(BubbleOut in [[stage_in]],
                                   constant Uniforms& u [[buffer(0)]],
                                   texture2d<float> luma [[texture(1)]],
                                   texture2d<float> chroma [[texture(2)]]) {
    float3 n = normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float cosI = saturate(dot(n, V));
    float mask = smoothstep(0.5, 0.92, 1.0 - cosI);
    float3 c;
    if (u.eye.w > 0.5) {
        float2 uv = in.position.xy / u.viewport.xy;
        float2 centre = u.viewport.zw / u.viewport.xy;
        c = cameraColor(uv + (centre - uv) * 0.16 * mask, luma, chroma, u) * 1.06;
    } else {
        float3 T = refract(-V, n, 1.0 / 1.45);
        float3 dir = normalize(mix(-V, T, 1.7));
        c = sky(toWorld(dir, u), u) * 1.35;
    }
    c += float3(0.01, 0.02, 0.04) * mask;
    return float4(c, mask * 0.85);
}

// MARK: - Holo-metal gyroscope

struct MeshOut {
    float4 position [[position]];
    float3 pos;
    float3 normal;
};

vertex MeshOut meshVertex(uint vid [[vertex_id]],
                          const device MeshVertex* verts [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]],
                          constant MeshUniforms& m [[buffer(2)]]) {
    float4 p = m.model * float4(verts[vid].position.xyz, 1.0);
    MeshOut o;
    o.position = u.viewProj * p;
    o.pos = p.xyz;
    o.normal = normalize((m.normalModel * float4(verts[vid].normal.xyz, 0.0)).xyz);
    return o;
}

/// Anodised-oxide interference: the rainbow sheen on titanium, as a tint 0…1.
static float3 oxideFilm(float cosI, float thickness) {
    float sinT2 = (1.0 - cosI * cosI) / 4.0;
    float cosT = sqrt(max(1.0 - sinT2, 0.0));
    float3 phase = 4.0 * M_PI_F * 2.0 * thickness * cosT / float3(640.0, 530.0, 450.0);
    return 0.5 + 0.5 * cos(phase);
}

/// Physically based metal (GGX, Smith, Schlick) with circular brushing on the rotor,
/// image-based reflections of the environment, an oxide rainbow, and a holographic glow
/// at grazing angles that the scan band sweeps through.
fragment float4 metalFragment(MeshOut in [[stage_in]],
                              constant Uniforms& u [[buffer(0)]],
                              constant MeshUniforms& m [[buffer(1)]],
                              texturecube<float> probe [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float NdV = max(dot(N, V), 1e-3);
    float rough = m.material.x;
    float aniso = m.material.y;
    float tooling = 1.0;
    if (m.spinAxis.w > 0.5) {
        // Lathe tool marks: fine rings following the turned profile, too fine to see from
        // afar, so they fade out once they'd alias.
        float3 axis = m.spinAxis.xyz;
        float3 r = in.pos - m.spinCenter.xyz;
        float h = dot(r, axis) / max(m.extra.x, 1e-3);
        float rho = length(r - dot(r, axis) * axis) / max(m.extra.x, 1e-3);
        float g = (rho + abs(h)) * 160.0;
        float visible = 1.0 - smoothstep(0.25, 0.7, fwidth(g));
        float groove = (0.5 + 0.5 * sin(g * 6.2831853)) * visible;
        float chatter = vnoise(float3(rho * 37.0, h * 37.0, 0.0));
        rough *= 0.85 + 0.3 * groove + 0.1 * chatter;
        tooling = 0.94 + 0.08 * groove + 0.03 * chatter;
    }

    float3 T;
    if (m.spinCenter.w > 0.5) {
        float3 radial = in.pos - m.spinCenter.xyz;
        radial -= dot(radial, m.spinAxis.xyz) * m.spinAxis.xyz;
        T = cross(m.spinAxis.xyz, radial) + float3(1e-5, 0.0, 0.0);
    } else {
        T = cross(N, abs(N.y) < 0.9 ? float3(0, 1, 0) : float3(1, 0, 0));
    }
    T = normalize(T - dot(T, N) * N);
    float3 B = cross(N, T);

    float thickness = 300.0 + 150.0 * sin(dot(in.pos, float3(3.1, 2.3, 4.7)) + u.camera.z * 0.25);
    float3 oxide = oxideFilm(NdV, thickness);
    float3 F0 = mix(m.base.rgb, m.base.rgb * (0.3 + 1.4 * oxide), m.material.z) * tooling;

    float a = max(rough * rough, 0.002);
    float aT = max(a * (1.0 - 0.8 * aniso), 0.0015);  // along the grooves: crisp
    float aB = max(a * (1.0 + 2.5 * aniso), 0.0015);  // across them: smeared radially
    float k = a * 0.5;
    float3 color = 0.0;
    for (int i = 0; i < 2; i++) {
        float4 light = i == 0 ? u.lightA : u.lightB;
        float3 L = light.xyz;
        float NdL = dot(N, L);
        if (NdL <= 0.0) continue;
        float3 H = normalize(L + V);
        float NdH = saturate(dot(N, H));
        float th = dot(T, H) / aT;
        float bh = dot(B, H) / aB;
        float d = th * th + bh * bh + NdH * NdH;
        float D = 1.0 / (M_PI_F * aT * aB * d * d);
        float G = (NdL / (NdL * (1.0 - k) + k)) * (NdV / (NdV * (1.0 - k) + k));
        float3 F = F0 + (1.0 - F0) * pow(1.0 - saturate(dot(V, H)), 5.0);
        color += min(D * G, 60.0) * F / (4.0 * NdV) * light.w * 2.5;
    }

    float3 R = reflect(-V, N);
    float3 env = environment(R, rough, B * aniso * 0.55, u, probe) * (m.extra.y > 0.0 ? m.extra.y : 1.0);
    float3 Fr = F0 + (max(float3(1.0 - rough), F0) - F0) * pow(1.0 - NdV, 5.0);
    color += env * Fr;

    float rim = pow(1.0 - NdV, 3.0);
    float hue = 0.5 + 0.5 * sin(dot(in.pos, float3(2.0, 3.0, 1.0)) * 3.0 + u.camera.z * 0.8);
    float3 glow = mix(float3(0.30, 0.85, 1.00), float3(0.72, 0.45, 1.00), hue);
    float band = (in.pos.y - u.misc.y) / 0.07;
    float scan = exp(-band * band);
    color += glow * m.material.w * (rim * 0.9 + 0.03 + scan * 0.45) * u.misc.z;
    color += m.base.rgb * m.base.w;
    return float4(color, 1.0);
}

/// A gas giant and its rings: latitude bands stirred by turbulence and a storm that smears
/// into a band at speed, lit by the room's lights with a holographic atmosphere.
fragment float4 planetFragment(MeshOut in [[stage_in]],
                               constant Uniforms& u [[buffer(0)]],
                               constant MeshUniforms& m [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float3 axis = m.spinAxis.xyz;
    float3 su = m.spinU.xyz;
    float3 sv = cross(axis, su);
    float3 r = in.pos - m.spinCenter.xyz;
    float3 albedo;
    if (m.spinAxis.w > 2.5) {
        // Ring: bands by radius, with the Cassini division cut out.
        if (dot(N, V) < 0.0) N = -N;
        float d = length(r - dot(r, axis) * axis) / max(m.extra.x, 1e-3);
        if (d > 1.6 && d < 1.67) discard_fragment();
        float grain = 0.55 + 0.45 * sin(d * 47.0) * sin(d * 13.0 + 1.0);
        albedo = float3(0.95, 0.86, 0.66) * grain * (d < 1.6 ? 0.8 : 1.0);
    } else {
        float3 n0 = normalize(r);
        float lat = asin(clamp(dot(n0, axis), -1.0, 1.0));
        float phi = atan2(dot(n0, sv), dot(n0, su));
        float turb = fbm(float3(lat * 5.0, cos(phi) * 1.4, sin(phi) * 1.4) + 3.0);
        float t = lat * 7.0 + turb * 1.6;
        float3 cream = float3(0.95, 0.86, 0.68);
        float3 tan_ = float3(0.80, 0.56, 0.36);
        float3 rust = float3(0.66, 0.30, 0.20);
        float3 pale = float3(0.72, 0.80, 0.88);
        albedo = mix(cream, tan_, smoothstep(-0.6, 0.6, sin(t)));
        albedo = mix(albedo, rust, smoothstep(0.4, 0.9, sin(t * 0.53 + 1.3)) * 0.8);
        albedo = mix(albedo, pale, smoothstep(0.75, 1.0, abs(dot(n0, axis))));
        float smear = abs(m.spinU.w);
        float dphi = phi - 1.1;
        dphi -= 2.0 * M_PI_F * round(dphi / (2.0 * M_PI_F));
        float2 q = float2(dphi * cos(lat) / (0.28 + smear * 0.9), (lat + 0.38) / 0.11);
        float storm = exp(-dot(q, q)) / (1.0 + smear * 1.5);
        albedo = mix(albedo, float3(0.85, 0.32, 0.22), saturate(storm));
    }
    float lit = 0.1;
    lit += saturate(dot(N, u.lightA.xyz)) * u.lightA.w * 0.55;
    lit += saturate(dot(N, u.lightB.xyz)) * u.lightB.w * 0.4;
    float3 color = albedo * lit * 0.85;
    float rim = pow(1.0 - saturate(dot(N, V)), 2.5);
    color += float3(0.35, 0.70, 1.0) * rim * 0.7 * (m.spinAxis.w > 2.5 ? 0.3 : 1.0);
    float band = (in.pos.y - u.misc.y) / 0.07;
    color += float3(0.3, 0.85, 1.0) * exp(-band * band) * 0.3 * u.misc.z;
    return float4(color, 1.0);
}

/// The glass orb's abraded skin, in the orb's own frame so it turns with the gyroscope:
/// a fine frost, scuffed patches and curved scratches that come and go.
static float abrasion(float3 q) {
    float frost = fbm(q * 9.0);
    float scuff = smoothstep(0.5, 0.8, fbm(q * 2.6 + 5.0));
    float scratches = 0.0;
    for (int k = 0; k < 7; k++) {
        float fk = float(k);
        float3 a = normalize(float3(sin(fk * 2.3 + 0.4), cos(fk * 1.7 + 1.1), sin(fk * 3.1 + 2.0)));
        // Each family is a few long arcs, wandering a little and broken into pieces.
        float t = dot(q, a) * (3.0 + 1.3 * fk) + vnoise(q * 3.0 + fk * 3.7) * 0.6;
        float w = fwidth(t) * 1.4 + 0.006;
        float line = 1.0 - smoothstep(0.0, w, abs(fract(t) - 0.5));
        float mask = smoothstep(0.58, 0.72, vnoise(q * (1.6 + 0.4 * fk) + fk * 7.1));
        scratches = max(scratches, line * mask * (0.6 + 0.4 * vnoise(q * 20.0 + fk)));
    }
    return saturate(0.14 * frost + 0.55 * scuff + scratches);
}

/// The orb's near face. Everything inside was drawn first and copied (with mipmaps) into
/// `behind`, so this refracts it: a thick shell bends light mostly near the rim, red,
/// green and blue by different amounts, and the abrasion scatters it into frost.
fragment float4 glassOrbFragment(MeshOut in [[stage_in]],
                                 constant Uniforms& u [[buffer(0)]],
                                 constant MeshUniforms& m [[buffer(1)]],
                                 texturecube<float> probe [[texture(0)]],
                                 texture2d<float> luma [[texture(1)]],
                                 texture2d<float> chroma [[texture(2)]],
                                 texture2d<float> behind [[texture(3)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float cosI = saturate(dot(N, V));
    float rim = 1.0 - cosI;
    float3 e = m.spinAxis.xyz;
    float3 su = m.spinU.xyz;
    float3 n0 = normalize(in.pos - m.spinCenter.xyz);
    float3 q = float3(dot(n0, su), dot(n0, cross(e, su)), dot(n0, e));
    float refraction = m.extra.y;
    float frost = m.extra.z;
    float dispersion = m.extra.w;
    float scuff = abrasion(q) * frost;

    float2 uv = in.position.xy / u.viewport.xy;
    float4 c0 = u.viewProj * float4(in.pos, 1.0);
    float4 c1 = u.viewProj * float4(in.pos + N * 0.05, 1.0);
    float2 sn = (c1.xy / c1.w - c0.xy / c0.w) * float2(0.5, -0.5);
    sn = length(sn) > 1e-6 ? normalize(sn) : float2(0.0);
    float bend = refraction * (0.01 + 0.12 * pow(rim, 2.2));
    float2 shift = -sn * bend;
    float spread = dispersion * (0.2 + 1.3 * rim);
    float lod = 0.4 * frost + scuff * 5.0;

    float2 uvR = uv + shift * (1.0 - 0.5 * spread);
    float2 uvG = uv + shift;
    float2 uvB = uv + shift * (1.0 + 0.5 * spread);
    float4 g = behind.sample(mipClamp, uvG, level(lod));
    float3 c = float3(behind.sample(mipClamp, uvR, level(lod)).r, g.g, behind.sample(mipClamp, uvB, level(lod)).b);
    if (u.eye.w > 0.5) {
        float3 cam = float3(cameraColor(uvR, luma, chroma, u).r, cameraColor(uvG, luma, chroma, u).g,
                            cameraColor(uvB, luma, chroma, u).b);
        c += cam * (1.0 - saturate(g.a));
    }
    // Scattering in the abraded layer: milky and a little brighter where it's scuffed.
    c = mix(c, c * 0.75 + float3(0.06, 0.075, 0.095), saturate(scuff * 0.9));
    c += float3(0.07, 0.08, 0.1) * scuff;

    float fresnel = 0.04 + 0.96 * pow(rim, 5.0);
    float3 R = reflect(-V, N);
    float3 env = environment(R, 0.04 + scuff * 0.5, 0.0, u, probe);
    float3 H = normalize(u.lightA.xyz + V);
    float nh = saturate(dot(N, H));
    float spec = pow(nh, 700.0) * u.lightA.w * (1.0 - scuff) + pow(nh, 35.0) * scuff * 0.35;
    float3 H2 = normalize(u.lightB.xyz + V);
    spec += pow(saturate(dot(N, H2)), 500.0) * u.lightB.w * (1.0 - scuff);
    c += env * fresnel * 1.1 + spec;
    // A prism's rainbow right at the silhouette.
    float3 rainbow = 0.5 + 0.5 * cos(6.2831 * (rim * 2.2 + float3(0.0, 0.33, 0.67)));
    c += rainbow * pow(rim, 5.0) * dispersion * 0.6;
    return float4(c, 1.0);
}

/// The orb's far wall, seen through the near one: faint scuffs and reflections.
fragment float4 glassOrbBackFragment(MeshOut in [[stage_in]],
                                     constant Uniforms& u [[buffer(0)]],
                                     constant MeshUniforms& m [[buffer(1)]],
                                     texturecube<float> probe [[texture(0)]]) {
    float3 N = -normalize(in.normal);
    float3 V = normalize(u.eye.xyz - in.pos);
    float cosI = saturate(dot(N, V));
    float3 e = m.spinAxis.xyz;
    float3 su = m.spinU.xyz;
    float3 n0 = normalize(in.pos - m.spinCenter.xyz);
    float3 q = float3(dot(n0, su), dot(n0, cross(e, su)), dot(n0, e));
    float scuff = abrasion(q) * m.extra.z;
    float fresnel = 0.04 + 0.96 * pow(1.0 - cosI, 5.0);
    float3 env = environment(reflect(-V, N), 0.1 + scuff * 0.5, 0.0, u, probe);
    float3 c = env * fresnel * 0.35 + float3(0.05, 0.065, 0.085) * scuff;
    return float4(c, 0.0);
}

// MARK: - Hologram lines

struct LineOut {
    float4 position [[position]];
    float2 px;
    float2 sa;
    float2 sb;
    float wa;
    float wb;
    float4 ca;
    float4 cb;
};

vertex LineOut lineVertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          const device LineInstance* lines [[buffer(0)]],
                          constant Uniforms& u [[buffer(1)]]) {
    LineInstance L = lines[iid];
    // Nudge toward the eye so lines drawn on the metal's surface aren't hidden by it.
    float3 pa = L.a.xyz + normalize(u.eye.xyz - L.a.xyz) * 0.015;
    float3 pb = L.b.xyz + normalize(u.eye.xyz - L.b.xyz) * 0.015;
    float4 ka = u.viewProj * float4(pa, 1.0);
    float4 kb = u.viewProj * float4(pb, 1.0);
    LineOut o;
    o.px = 0.0;
    o.sa = 0.0;
    o.sb = 0.0;
    o.wa = L.a.w;
    o.wb = L.b.w;
    o.ca = L.ca;
    o.cb = L.cb;
    if (ka.w < 0.01 || kb.w < 0.01) {
        o.position = float4(10.0, 10.0, 0.5, 1.0);
        return o;
    }
    float2 sa = (ka.xy / ka.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 sb = (kb.xy / kb.w * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float wmax = max(L.a.w, L.b.w);
    float half_ = wmax * 0.5 + wmax * 2.2 + 2.0;
    float t = (vid & 1) ? 1.0 : 0.0;
    float s = (vid & 2) ? 1.0 : -1.0;
    // Segments of a polyline butt together without caps, so additive joints don't double
    // up into beads; a lone point gets a round dot.
    float cap = len > 1.5 ? 0.0 : half_;
    float2 p = mix(sa, sb, t) + dir * (t * 2.0 - 1.0) * cap + nrm * s * half_;
    float z = mix(ka.z / ka.w, kb.z / kb.w, len > 1.5 ? t : 0.0);
    o.position = float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, z, 1.0);
    o.px = p;
    o.sa = sa;
    o.sb = sb;
    return o;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    float2 d = in.sb - in.sa;
    float len2 = dot(d, d);
    float along = len2 > 1e-6 ? dot(in.px - in.sa, d) / len2 : 0.0;
    float t = saturate(along);
    float dist = length(in.px - (in.sa + d * (len2 > 2.25 ? along : t)));
    float w = mix(in.wa, in.wb, t) * 0.5;
    float4 c = mix(in.ca, in.cb, t);
    float core = 1.0 - smoothstep(w - 0.6, w + 0.9, dist);
    float g = w * 2.2 + 1.5;
    float glow = exp(-dist * dist / (g * g)) * 0.45;
    return float4(c.rgb * c.a * (core + glow), 0.0);
}

// MARK: - Bloom

fragment float4 prefilterFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    float3 c = src.sample(linearClamp, in.uv).rgb;
    float peak = max(c.r, max(c.g, c.b));
    return float4(c * smoothstep(0.35, 1.3, peak), 1.0);
}

fragment float4 copyFragment(FSOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return float4(src.sample(linearClamp, in.uv).rgb, 1.0);
}

fragment float4 blurFragment(FSOut in [[stage_in]],
                             texture2d<float> src [[texture(0)]],
                             constant float2& texelStep [[buffer(0)]]) {
    float3 c = src.sample(linearClamp, in.uv).rgb * 0.2270270270;
    float2 o1 = texelStep * 1.3846153846;
    float2 o2 = texelStep * 3.2307692308;
    c += src.sample(linearClamp, in.uv + o1).rgb * 0.3162162162;
    c += src.sample(linearClamp, in.uv - o1).rgb * 0.3162162162;
    c += src.sample(linearClamp, in.uv + o2).rgb * 0.0702702703;
    c += src.sample(linearClamp, in.uv - o2).rgb * 0.0702702703;
    return float4(c, 1.0);
}

// MARK: - Composite

static inline float softClip(float x, float headroom) {
    float k = 0.8;
    float h = max(headroom, 1.0);
    if (x <= k) return x;
    return k + (h - k) * (1.0 - exp(-(x - k) / (h - k)));
}

fragment float4 compositeFragment(FSOut in [[stage_in]],
                                  texture2d<float> scene [[texture(0)]],
                                  texture2d<float> bloomA [[texture(1)]],
                                  texture2d<float> bloomB [[texture(2)]],
                                  texture2d<float> luma [[texture(3)]],
                                  texture2d<float> chroma [[texture(4)]],
                                  constant Uniforms& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 centre = u.viewport.zw / u.viewport.xy;
    float2 off = (uv - centre) * u.post.z;
    float4 s = scene.sample(linearClamp, uv);
    float3 c = float3(scene.sample(linearClamp, uv + off).r, s.g, scene.sample(linearClamp, uv - off).b);
    c += bloomA.sample(linearClamp, uv).rgb * u.post.x;
    c += bloomB.sample(linearClamp, uv).rgb * u.post.x * 0.9;
    c *= 1.0 - u.post.y * (0.5 + 0.5 * sin(in.position.y * 2.0944 + u.camera.z * 4.0));
    if (u.eye.w > 0.5) {
        c += cameraColor(uv, luma, chroma, u) * (1.0 - saturate(s.a));
    }
    float headroom = min(u.camera.w, 3.0);
    c = float3(softClip(c.r, headroom), softClip(c.g, headroom), softClip(c.b, headroom));
    return float4(max(c, 0.0), 1.0);
}
