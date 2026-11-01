// The model only makes luma: colour comes from the plain enlarged frame, corrected by the luma it gained.
@group(1) @binding(0) var luma: texture_2d<f32>;
@group(1) @binding(1) var tex: texture_2d<f32>;
@group(1) @binding(2) var smp: sampler;
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let c = textureSample(tex, smp, pos.xy / vec2f(textureDimensions(luma))).rgb;
    let gain = textureLoad(luma, vec2i(pos.xy), 0).r - dot(c, vec3f(0.2126, 0.7152, 0.0722));
    return vec4f(clamp(c + gain, vec3f(0.0), vec3f(1.0)), 1.0);
}
