#version 450
// The model only makes luma: colour comes from the plain enlarged frame, corrected by the luma it gained.
#extension GL_EXT_samplerless_texture_functions : require
layout(set = 1, binding = 0) uniform texture2D luma;
layout(set = 1, binding = 1) uniform texture2D tex;
layout(set = 1, binding = 2) uniform sampler smp;
layout(location = 0) out vec4 frag;
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    vec3 c = texture(sampler2D(tex, smp), gl_FragCoord.xy / vec2(textureSize(luma, 0))).rgb;
    float gain = texelFetch(luma, p, 0).r - dot(c, vec3(0.2126, 0.7152, 0.0722));
    frag = vec4(clamp(c + gain, 0.0, 1.0), 1.0);
}
