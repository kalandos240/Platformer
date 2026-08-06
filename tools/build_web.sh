#!/usr/bin/env bash
set -euo pipefail

# Build the original Pingus 0.7.6 C++ game and data for WebAssembly.
mkdir -p ../dist
rm -rf ../dist/*

# Pingus only uses Boost headers in this browser target.
rm -rf external/boost
cp -a /usr/include/boost external/boost

python3 - <<'PY'
from pathlib import Path
import re


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text(encoding='utf-8')
    if old not in source:
        raise SystemExit(f'{label} patch mismatch in {path}')
    path.write_text(source.replace(old, new, 1), encoding='utf-8')

# The desktop editor is not part of the published game and depends on obsolete
# native-only Boost.Signals code. Remove only its command-line entry points.
path = Path('src/pingus/pingus_main.cpp')
source = path.read_text(encoding='utf-8')
for include in ('#include "editor/editor_level.hpp"\n', '#include "editor/editor_screen.hpp"\n'):
    if include not in source:
        raise SystemExit(f'Pingus editor include patch mismatch: {include!r}')
    source = source.replace(include, '', 1)

editor_option = '''  argp.add_group("Editor Options:");
  argp.add_option('e', "editor", "",
                  _("Loads the level editor"));

'''
if editor_option not in source:
    raise SystemExit('Pingus editor option patch mismatch')
source = source.replace(editor_option, '', 1)

editor_case = '''      case 'e': // -e, --editor
        cmd_options.editor.set(true);
        break;

'''
if editor_case not in source:
    raise SystemExit('Pingus editor switch patch mismatch')
source = source.replace(editor_case, '', 1)

editor_start = re.compile(
    r'  if \(cmd_options\.editor\.is_set\(\) && cmd_options\.editor\.get\(\)\)\n'
    r'  \{ // Editor\n.*?\n  \}\n'
    r'  else if \(cmd_options\.rest\.is_set\(\)\)',
    re.DOTALL,
)
source, count = editor_start.subn('  if (cmd_options.rest.is_set())', source, count=1)
if count != 1:
    raise SystemExit('Pingus editor startup patch mismatch')
path.write_text(source, encoding='utf-8')

# The old SCons build injected the exception helper globally. Include it only
# in translation units that use it.
for path in Path('src').rglob('*.cpp'):
    source = path.read_text(encoding='utf-8')
    if ('raise_exception(' in source or 'raise_error(' in source) and \
       'util/raise_exception.hpp' not in source:
        match = re.search(r'^#include ', source, flags=re.MULTILINE)
        if not match:
            raise SystemExit(f'No include location in {path}')
        source = source[:match.start()] + '#include "util/raise_exception.hpp"\n\n' + source[match.start():]
        path.write_text(source, encoding='utf-8')

# Emscripten's SDL 1 compatibility layer stores alpha and colour-key state on
# SDL_Surface rather than exposing the removed SDL_PixelFormat fields.
path = Path('src/engine/display/blitter.cpp')
source = path.read_text(encoding='utf-8')
replacements = {
    '    ckey = surface->format->colorkey;':
        '    ckey = 0;\n    SDL_GetColorKey(surface, &ckey);',
    '  if (surface->flags & SDL_SRCALPHA)\n    SDL_SetAlpha(new_surface, SDL_SRCALPHA, surface->format->alpha);':
        '  if (surface->flags & SDL_SRCALPHA)\n  {\n    Uint8 alpha = SDL_ALPHA_OPAQUE;\n    SDL_GetSurfaceAlphaMod(surface, &alpha);\n    SDL_SetAlpha(new_surface, SDL_SRCALPHA, alpha);\n  }',
    '  if (surface->flags & SDL_SRCCOLORKEY)\n    SDL_SetColorKey(new_surface, SDL_SRCCOLORKEY, surface->format->colorkey);':
        '  if (surface->flags & SDL_SRCCOLORKEY)\n  {\n    Uint32 color_key = 0;\n    SDL_GetColorKey(surface, &color_key);\n    SDL_SetColorKey(new_surface, SDL_SRCCOLORKEY, color_key);\n  }',
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f'Pingus SDL blitter patch mismatch: {old!r}')
    source = source.replace(old, new, 1)
path.write_text(source, encoding='utf-8')

path = Path('src/engine/display/surface.cpp')
source = path.read_text(encoding='utf-8')
replacements = {
    '          if (impl->surface->flags & SDL_SRCCOLORKEY &&\n              pixel == impl->surface->format->colorkey)':
        '          Uint32 color_key = 0;\n          if (SDL_GetColorKey(impl->surface, &color_key) == 0 &&\n              pixel == color_key)',
    '    Uint8 alpha = impl->surface->format->alpha;':
        '    Uint8 alpha = SDL_ALPHA_OPAQUE;\n    SDL_GetSurfaceAlphaMod(impl->surface, &alpha);',
    '  if (impl->surface->flags & SDL_SRCCOLORKEY)\n    out << "Colorkey: " << static_cast<int>(impl->surface->format->colorkey) << std::endl;':
        '  if (impl->surface->flags & SDL_SRCCOLORKEY)\n  {\n    Uint32 color_key = 0;\n    SDL_GetColorKey(impl->surface, &color_key);\n    out << "Colorkey: " << static_cast<int>(color_key) << std::endl;\n  }',
    '  if (impl->surface->flags & SDL_SRCALPHA)\n    out << "Alpha: " << static_cast<int>(impl->surface->format->alpha) << std::endl;':
        '  if (impl->surface->flags & SDL_SRCALPHA)\n  {\n    Uint8 alpha = SDL_ALPHA_OPAQUE;\n    SDL_GetSurfaceAlphaMod(impl->surface, &alpha);\n    out << "Alpha: " << static_cast<int>(alpha) << std::endl;\n  }',
}
for old, new in replacements.items():
    if old not in source:
        raise SystemExit(f'Pingus SDL surface patch mismatch: {old!r}')
    source = source.replace(old, new, 1)
path.write_text(source, encoding='utf-8')

replace_once(
    Path('src/engine/input/event.hpp'),
    '  SDL_keysym keysym;',
    '  SDL_Keysym keysym;',
    'Pingus SDL Keysym',
)

# Browser lifecycle: yield while hidden, signal Yandex Game Ready after the
# first rendered frame, and flush the IDBFS save directory on exit.
path = Path('src/engine/screen/screen_manager.cpp')
source = path.read_text(encoding='utf-8')
include_anchor = '#include <iostream>\n'
include_patch = '#include <iostream>\n\n#ifdef __EMSCRIPTEN__\n#include <emscripten.h>\n#endif\n'
if include_anchor not in source:
    raise SystemExit('Pingus ScreenManager include patch mismatch')
source = source.replace(include_anchor, include_patch, 1)

loop_anchor = '''  while (!screens.empty())
  {
    events.clear();'''
loop_patch = '''  while (!screens.empty())
  {
#ifdef __EMSCRIPTEN__
    if (EM_ASM_INT({ return document.hidden ? 1 : 0; }))
    {
      emscripten_sleep(100);
      last_ticks = SDL_GetTicks();
      continue;
    }
#endif
    events.clear();'''
if loop_anchor not in source:
    raise SystemExit('Pingus ScreenManager hidden-page patch mismatch')
source = source.replace(loop_anchor, loop_patch, 1)

end_loop_anchor = '''  }
}
 
void
ScreenManager::update'''
end_loop_patch = '''  }
#ifdef __EMSCRIPTEN__
  EM_ASM({
    if (typeof window.pingusSaveNow === 'function') {
      window.pingusSaveNow();
    }
  });
#endif
}
 
void
ScreenManager::update'''
if end_loop_anchor not in source:
    raise SystemExit('Pingus ScreenManager save hook mismatch')
source = source.replace(end_loop_anchor, end_loop_patch, 1)

flip_anchor = '''  Display::flip_display();
}'''
flip_patch = '''  Display::flip_display();
#ifdef __EMSCRIPTEN__
  static bool game_ready_sent = false;
  if (!game_ready_sent)
  {
    game_ready_sent = true;
    EM_ASM({
      if (typeof window.pingusMarkReady === 'function') {
        window.pingusMarkReady();
      }
    });
  }
#endif
}'''
if flip_anchor not in source:
    raise SystemExit('Pingus ScreenManager first-frame patch mismatch')
source = source.replace(flip_anchor, flip_patch, 1)
path.write_text(source, encoding='utf-8')
PY

mapfile -t SOURCES < <(
  find external/tinygettext/tinygettext src -type f -name '*.cpp' \
    ! -path 'src/editor/*' \
    ! -path '*/opengl/*' \
    ! -path '*/evdev/*' \
    ! -path '*/xinput/*' \
    ! -path '*/wiimote/*' \
    -print | sort
)

if (( ${#SOURCES[@]} < 200 )); then
  echo "Unexpectedly small Pingus source set: ${#SOURCES[@]}" >&2
  exit 1
fi
printf 'Compiling %s original C++ source files (desktop editor omitted)\n' "${#SOURCES[@]}"

em++ "${SOURCES[@]}" \
  -I. -Isrc -Iexternal -Iexternal/tinygettext \
  -std=c++11 -O1 -fexceptions \
  -Wno-invalid-source-encoding \
  -DVERSION='"0.7.6-web"' \
  -DHAVE_ICONV_CONST=1 -DICONV_CONST= \
  -sUSE_SDL=1 \
  -sUSE_SDL_IMAGE=1 \
  -sUSE_SDL_MIXER=1 \
  -sUSE_LIBPNG=1 \
  -sUSE_OGG=1 \
  -sUSE_VORBIS=1 \
  -sDISABLE_EXCEPTION_CATCHING=0 \
  -sFORCE_FILESYSTEM=1 \
  -sASYNCIFY=1 \
  -sASYNCIFY_STACK_SIZE=65536 \
  -sINITIAL_MEMORY=67108864 \
  -sALLOW_MEMORY_GROWTH=1 \
  -sMAXIMUM_MEMORY=1073741824 \
  -sASSERTIONS=1 \
  -sERROR_ON_UNDEFINED_SYMBOLS=1 \
  -sEXIT_RUNTIME=0 \
  -sENVIRONMENT=web \
  -lidbfs.js \
  --shell-file ../web/shell.html \
  --preload-file data@/data \
  -o ../dist/index.html
