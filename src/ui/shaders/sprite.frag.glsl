#version 450
layout(set = 1, binding = 0) uniform texture2D tex;
layout(set = 1, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 0) out vec4 frag;
// A negative u is a plain shape, so shapes share a draw with whatever texture is bound.
void main() {
    frag = uv.x < 0.0 ? color : texture(sampler2D(tex, smp), uv) * color;
}
