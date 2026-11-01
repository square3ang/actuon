@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var smp: sampler;
// A negative u is a plain shape, so shapes share a draw with whatever texture is bound.
@fragment fn main(@location(0) uv: vec2f, @location(1) color: vec4f) -> @location(0) vec4f {
    return select(textureSample(tex, smp, uv) * color, color, uv.x < 0.0);
}
