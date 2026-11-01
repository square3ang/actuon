// The model's last layer keeps four luma pixels in each texel's channels.
@group(1) @binding(0) var packed_luma: texture_2d<f32>;
@fragment fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let p = vec2i(pos.xy);
    let y = textureLoad(packed_luma, p / 2, 0)[(p.x & 1) * 2 + (p.y & 1)];
    return vec4f(clamp(y, 0.0, 1.0), 0.0, 0.0, 1.0);
}
