#version 450
layout(set = 0, binding = 0) uniform params { vec4 size; };
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv_in;
layout(location = 2) in vec4 color_in;
layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
void main() {
    uv = uv_in;
    color = color_in;
    gl_Position = vec4(pos.x / size.x * 2.0 - 1.0, 1.0 - pos.y / size.y * 2.0, 0.0, 1.0);
}
