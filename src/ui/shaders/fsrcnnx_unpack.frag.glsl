#version 450
// The model's last layer keeps four luma pixels in each texel's channels.
#extension GL_EXT_samplerless_texture_functions : require
layout(set = 1, binding = 0) uniform texture2D packed_luma;
layout(location = 0) out vec4 frag;
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    float y = texelFetch(packed_luma, p / 2, 0)[(p.x & 1) * 2 + (p.y & 1)];
    frag = vec4(clamp(y, 0.0, 1.0), 0.0, 0.0, 1.0);
}
