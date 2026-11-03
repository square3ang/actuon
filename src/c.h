// Single translation unit for every C API the client uses (see addTranslateC in build.zig).
#include <SDL3/SDL.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <portaudio.h>
#include <sqlite3.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <archive.h>
#include <locale.h>
#include <archive_entry.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#include "dr_wav.h"
#include "dr_flac.h"
#include "dr_mp3.h"
#include "stb_image.h"
#include "sokol_gfx.h"
#include "ui/render_backend.h"
#ifdef _WIN32
#include <pa_win_wasapi.h>
#endif
#ifdef __linux__
#include <alsa/asoundlib.h>
#endif
