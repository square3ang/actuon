struct Params { size: vec4f }
@group(0) @binding(0) var<uniform> params: Params;
struct Out {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) color: vec4f,
}
@vertex fn main(@location(0) pos: vec2f, @location(1) uv: vec2f, @location(2) color: vec4f) -> Out {
    return Out(vec4f(pos.x / params.size.x * 2.0 - 1.0, 1.0 - pos.y / params.size.y * 2.0, 0.0, 1.0), uv, color);
}
