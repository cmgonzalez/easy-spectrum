cmake_minimum_required(VERSION 3.22.1)
project(zx_bridge C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CLK "${CMAKE_CURRENT_SOURCE_DIR}/CLK")

# Subconjunto de Clock Signal necesario para el ZX Spectrum (16K/48K/128K/+2/+2a/+3).
# Obtenido enlazando con --no-undefined; no incluir Analyser/Static/StaticAnalyser.cpp
# (arrastra todas las máquinas).
set(CLK_SOURCES
    Components/8272/i8272.cpp
    Components/AY38910/AY38910.cpp
    Components/AudioToggle/AudioToggle.cpp
    Inputs/Keyboard.cpp
    Machines/KeyboardMachine.cpp
    Machines/Sinclair/Keyboard/Keyboard.cpp
    Machines/Utility/MemoryFuzzer.cpp
    Machines/Utility/ROMCatalogue.cpp
    Machines/Utility/Typer.cpp
    Outputs/CRT/CRT.cpp
    Outputs/ScanTarget.cpp
    Processors/Z80/Implementation/PartialMachineCycle.cpp
    Processors/Z80/Implementation/Z80Base.cpp
    Processors/Z80/Implementation/Z80Storage.cpp
    Processors/Z80/State/State.cpp
    SignalProcessing/FIRFilter.cpp
    Storage/Disk/Controller/DiskController.cpp
    Storage/Disk/Controller/MFMDiskController.cpp
    Storage/Disk/DiskImage/Formats/CPCDSK.cpp
    Storage/Disk/Drive.cpp
    Storage/Disk/Encodings/MFM/Encoder.cpp
    Storage/Disk/Encodings/MFM/Parser.cpp
    Storage/Disk/Encodings/MFM/SegmentParser.cpp
    Storage/Disk/Encodings/MFM/Shifter.cpp
    Storage/Disk/Track/PCMSegment.cpp
    Storage/Disk/Track/PCMTrack.cpp
    Storage/Disk/Track/TrackSerialiser.cpp
    Storage/Disk/Track/UnformattedTrack.cpp
    Storage/FileHolder.cpp
    Storage/State/SNA.cpp
    Storage/State/SZX.cpp
    Storage/State/Z80.cpp
    Storage/Tape/Formats/CSW.cpp
    Storage/Tape/Formats/TZX.cpp
    Storage/Tape/Formats/ZXSpectrumTAP.cpp
    Storage/Tape/Parsers/Spectrum.cpp
    Storage/Tape/PulseQueuedTape.cpp
    Storage/Tape/Tape.cpp
    Storage/TimedEventLoop.cpp
)
list(TRANSFORM CLK_SOURCES PREPEND "${CLK}/")

# ZXSpectrum.cpp se compila desde una copia parcheada (el submódulo no se toca).
# Si CLK cambia upstream alguno de los textos, el configure falla con un error claro.
set(ZX_SRC "${CLK}/Machines/Sinclair/ZXSpectrum/ZXSpectrum.cpp")
set(ZX_PATCHED "${CMAKE_CURRENT_BINARY_DIR}/ZXSpectrum_patched.cpp")
configure_file("${ZX_SRC}" "${ZX_PATCHED}.orig" COPYONLY)  # re-configura si cambia
file(READ "${ZX_SRC}" ZX_TEXT)
string(REPLACE "\r\n" "\n" ZX_TEXT "${ZX_TEXT}")  # por si el checkout usa CRLF

# Reemplaza FIND por REPLACEMENT (todas las apariciones) en la variable VAR; si el texto no
# está (CLK cambió upstream) el configure falla con un error claro.
function(clk_patch VAR NAME FIND REPLACEMENT)
    string(FIND "${${VAR}}" "${FIND}" POS)
    if(POS EQUAL -1)
        message(FATAL_ERROR "Parche ${VAR} '${NAME}': no se encontró el texto (¿cambió CLK upstream?)")
    endif()
    string(REPLACE "${FIND}" "${REPLACEMENT}" RESULT "${${VAR}}")
    set(${VAR} "${RESULT}" PARENT_SCOPE)
endfunction()

# Reemplaza el tramo de VAR que va de START hasta END (incluidos) por REPLACEMENT.
function(clk_patch_block VAR NAME START END REPLACEMENT)
    string(FIND "${${VAR}}" "${START}" A)
    string(FIND "${${VAR}}" "${END}" B)
    if(A EQUAL -1 OR B EQUAL -1 OR B LESS A)
        message(FATAL_ERROR "Parche ${VAR} '${NAME}': no se encontró el tramo (¿cambió CLK upstream?)")
    endif()
    string(LENGTH "${END}" END_LEN)
    math(EXPR B "${B} + ${END_LEN}")
    string(SUBSTRING "${${VAR}}" 0 ${A} HEAD)
    string(SUBSTRING "${${VAR}}" ${B} -1 TAIL)
    set(${VAR} "${HEAD}${REPLACEMENT}${TAIL}" PARENT_SCOPE)
endfunction()

function(zx_patch NAME FIND REPLACEMENT)
    clk_patch(ZX_TEXT "${NAME}" "${FIND}" "${REPLACEMENT}")
    set(ZX_TEXT "${ZX_TEXT}" PARENT_SCOPE)
endfunction()

# 1. Bug: al instalar el estado de un snapshot 128K asigna port7ffd_ y actualiza el
#    mapa de memoria, pero no la base de vídeo → se ignora la pantalla sombra (banco 7).
#    Afecta a .sna 128K, .z80 y .szx.
zx_patch(pantalla-sombra
    "\t\t\t\tport7ffd_ = state->last_7ffd;\n\t\t\t\tupdate_memory_map();\n"
    "\t\t\t\tport7ffd_ = state->last_7ffd;\n\t\t\t\tupdate_memory_map();\n\t\t\t\tset_video_address();\n")

# 2. "Cinta reproduciéndose" = motor encendido y cinta sin terminar. El motor automático
#    se enciende con cualquier bucle cerrado de lectura del puerto FE, incluido un menú
#    que lee el teclado; sin esto el turbo de carga (zx_run) seguiría activo en el juego.
zx_patch(cinta-terminada
    "\t\treturn tape_player_.motor_control();\n"
    "\t\treturn tape_player_.motor_control() && !tape_player_.is_at_end();\n")

# 3. ULAplus: puertos BF3B (registro) y FF3B (dato); el reset apaga el modo ULAplus.
#    La paleta y la salida de color están en la copia parcheada de Video.hpp (más abajo).
zx_patch(ulaplus-escritura
    "\t\t\t\t// Test for classic 128kb paging register (i.e. port 7ffd).\n"
    "\t\t\t\t// ULAplus.\n\t\t\t\tif(address == 0xbf3b) video_->ulaplus_write_register(*cycle.value);\n\t\t\t\tif(address == 0xff3b) video_->ulaplus_write_data(*cycle.value);\n\n\t\t\t\t// Test for classic 128kb paging register (i.e. port 7ffd).\n")
zx_patch(ulaplus-lectura
    "\t\t\t\tif constexpr (model <= Model::Plus2) {\n\t\t\t\t\tif(!did_match) {\n"
    "\t\t\t\tif(address == 0xff3b) {\n\t\t\t\t\tdid_match = true;\n\t\t\t\t\t*cycle.value = video_->ulaplus_read_data();\n\t\t\t\t}\n\n\t\t\t\tif constexpr (model <= Model::Plus2) {\n\t\t\t\t\tif(!did_match) {\n")
zx_patch(ulaplus-reset
    "\t\tupdate_video_base();\n\t\tz80_.set_power_on_reset();\n"
    "\t\tupdate_video_base();\n\t\tvideo_->ulaplus_reset();\n\t\tz80_.set_power_on_reset();\n")

# Métodos de depuración que se inyectan dentro de ConcreteMachine (native/clk_patches/pdp_methods.inc).
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/clk_patches/pdp_methods.inc" PDP_METHODS)
string(REPLACE "

" "
" PDP_METHODS "${PDP_METHODS}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/clk_patches/pdp_methods.inc")
# 4. PDP (depuración, ver zx_debug.h): hook en cada ReadOpcode + acceso a registros/memoria.
#    La máquina se engancha al núcleo de depuración al primer run_for; con el servidor apagado
#    el coste es un bool global por opcode.
zx_patch(pdp-include
    "#include \"ZXSpectrum.hpp\"\n"
    "#include \"ZXSpectrum.hpp\"\n#include \"zx_debug.h\"\n")
zx_patch(pdp-attach
    "\tvoid run_for(const Cycles cycles) override {\n\t\tz80_.run_for(cycles);\n"
    "\tvoid run_for(const Cycles cycles) override {\n\t\tif(zxdbg::g.t.ctx != this) debug_attach();\n\t\tz80_.run_for(cycles);\n")
zx_patch(pdp-detach
    "\t~ConcreteMachine() {\n\t\taudio_queue_.lock_flush();\n"
    "\t~ConcreteMachine() {\n\t\tzxdbg::detach(this);\n\t\taudio_queue_.lock_flush();\n")
zx_patch(pdp-hook
    "\t\treturn HalfCycles(0);\n\t}\n\nprivate:\n\tvoid advance(const HalfCycles duration) {\n"
    "\t\tif(zxdbg::g.armed) {\n\t\t\tif(cycle.operation == PartialMachineCycle::ReadOpcode) {\n\t\t\t\tconst int64_t d = zxdbg::on_fetch(address, *cycle.value);\n\t\t\t\tif(d) return HalfCycles(d);\n\t\t\t} else if(zxdbg::g.watch_any && (cycle.operation == PartialMachineCycle::Read || cycle.operation == PartialMachineCycle::Write)) {\n\t\t\t\tconst int64_t d = zxdbg::on_mem(address, *cycle.value, cycle.operation == PartialMachineCycle::Write);\n\t\t\t\tif(d) return HalfCycles(d);\n\t\t\t}\n\t\t}\n\t\treturn HalfCycles(0);\n\t}\n\n${PDP_METHODS}private:\n\tvoid advance(const HalfCycles duration) {\n")

zx_patch(pdp-clock
    "\tvoid advance(const HalfCycles duration) {\n"
    "\tvoid advance(const HalfCycles duration) {\n\t\tif(zxdbg::g.armed) zxdbg::g.clock += duration.get();\n")
file(WRITE "${ZX_PATCHED}" "${ZX_TEXT}")

# Video.hpp parcheado (ULAplus): salida Red8Green8Blue8 en vez de Red2Green2Blue2 (la
# paleta ULAplus tiene 3 bits por canal), colores de tinta/papel/borde por funciones que
# miran la paleta ULAplus, y FLASH sin parpadeo con ULAplus activo. El código nuevo está en
# native/clk_patches/*.inc. State.hpp se copia sin cambios junto a la copia de
# ZXSpectrum.cpp para que su #include "Video.hpp" encuentre la parcheada.
set(ZX_DIR "${CLK}/Machines/Sinclair/ZXSpectrum")
set(PATCH_DIR "${CMAKE_CURRENT_SOURCE_DIR}/clk_patches")
configure_file("${ZX_DIR}/Video.hpp" "${CMAKE_CURRENT_BINARY_DIR}/Video.hpp.orig" COPYONLY)
configure_file("${ZX_DIR}/State.hpp" "${CMAKE_CURRENT_BINARY_DIR}/State.hpp" COPYONLY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${PATCH_DIR}/ulaplus_public.inc" "${PATCH_DIR}/ulaplus_private.inc")
file(READ "${ZX_DIR}/Video.hpp" VIDEO_TEXT)
string(REPLACE "\r\n" "\n" VIDEO_TEXT "${VIDEO_TEXT}")
file(READ "${PATCH_DIR}/ulaplus_public.inc" ULAPLUS_PUBLIC)
file(READ "${PATCH_DIR}/ulaplus_private.inc" ULAPLUS_PRIVATE)
string(REPLACE "\r\n" "\n" ULAPLUS_PUBLIC "${ULAPLUS_PUBLIC}")
string(REPLACE "\r\n" "\n" ULAPLUS_PRIVATE "${ULAPLUS_PRIVATE}")

clk_patch(VIDEO_TEXT salida-rgb8 "InputDataType::Red2Green2Blue2" "InputDataType::Red8Green8Blue8")
clk_patch(VIDEO_TEXT buffer-pixeles "\tuint8_t *pixel_target_ = nullptr;" "\tuint32_t *pixel_target_ = nullptr;")
clk_patch(VIDEO_TEXT begin-data "pixel_target_ = crt_.begin_data(256);"
    "pixel_target_ = reinterpret_cast<uint32_t *>(crt_.begin_data(256, alignof(uint32_t)));")
clk_patch(VIDEO_TEXT nivel-borde "crt_.output_level<uint8_t>(" "crt_.output_level<uint32_t>(")
clk_patch(VIDEO_TEXT color-borde "\tuint8_t border_colour_ = 0;" "\tuint32_t border_colour_ = 0;")
clk_patch(VIDEO_TEXT set-borde "border_colour_ = palette[colour];" "border_colour_ = border_rgb(colour);")
clk_patch(VIDEO_TEXT flash "masks[flash_mask_ & (last_fetches_[n+1] >> 7)]"
    "masks[flash_mask_ & flash_enable_ & (last_fetches_[n+1] >> 7)]")
clk_patch(VIDEO_TEXT tipo-colores "const uint8_t colours[2] = {" "const uint32_t colours[2] = {")
clk_patch(VIDEO_TEXT papel "palette[(last_fetches_[n+1] & 0x78) >> 3]," "paper_colour(last_fetches_[n+1]),")
clk_patch(VIDEO_TEXT tinta "palette[((last_fetches_[n+1] & 0x40) >> 3) | (last_fetches_[n+1] & 0x07)],"
    "ink_colour(last_fetches_[n+1]),")
clk_patch(VIDEO_TEXT api-ulaplus "\t/// Sets the scan target.\n" "${ULAPLUS_PUBLIC}\t/// Sets the scan target.\n")
clk_patch_block(VIDEO_TEXT paleta "#define RGB(r, g, b)" "#undef RGB\n" "${ULAPLUS_PRIVATE}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/Video.hpp" "${VIDEO_TEXT}")

# La copia de ZXSpectrum.cpp está fuera de su carpeta: sus #include "State.hpp"/"Video.hpp"
# encuentran primero las copias de al lado (build); el resto de includes relativos, la original.
set_source_files_properties("${ZX_PATCHED}" PROPERTIES
    INCLUDE_DIRECTORIES "${CLK}/Machines/Sinclair/ZXSpectrum")
list(APPEND CLK_SOURCES "${ZX_PATCHED}")

# ZX Spectrum Next (solo .nex): máquina propia, sin CLK (ver next/next_machine.h).
set(NEXT_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/next/z80n.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/next/next_machine.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/next/next_video.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/next/next_esxdos.cpp"
)

add_library(zx_bridge SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/zx_bridge.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/zx_pdp.cpp"
    ${NEXT_SOURCES}
    ${CLK_SOURCES}
)

target_include_directories(zx_bridge PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CLK}"
)

target_compile_definitions(zx_bridge PRIVATE NDEBUG)

if(WIN32)
    # Windows (Flutter desktop): se compila con clang-cl (CLK usa extensiones de GCC/Clang
    # que MSVC no acepta). zlib (lo usa SZX) no viene con el sistema: se baja y se enlaza
    # estática. Se exportan todos los símbolos (sin marcar la API con __declspec).
    include(FetchContent)
    set(ZLIB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(zlib
        URL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
        URL_HASH SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23)
    FetchContent_MakeAvailable(zlib)
    target_include_directories(zx_bridge PRIVATE "${zlib_SOURCE_DIR}" "${zlib_BINARY_DIR}")
    target_link_libraries(zx_bridge zlibstatic)
    set_target_properties(zx_bridge PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    target_compile_definitions(zx_bridge PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX)
    # wchar_t es de 16 bits sin signo: CLK lo inicializa con char (narrowing en Windows).
    target_compile_options(zx_bridge PRIVATE /O2 /EHsc /bigobj /w -Wno-c++11-narrowing
        "/FI${CMAKE_CURRENT_SOURCE_DIR}/windows_prelude.h")
    set_source_files_properties(
        "${CLK}/Processors/Z80/Implementation/Z80Storage.cpp"
        PROPERTIES COMPILE_OPTIONS "/O1")
    return()
endif()

target_compile_options(zx_bridge PRIVATE
    -O3
    -include "${CMAKE_CURRENT_SOURCE_DIR}/android_prelude.h"
    -fvisibility=hidden
    -w
)

# Exportar solo la API del bridge (zx_*).
set_source_files_properties(
    "${CMAKE_CURRENT_SOURCE_DIR}/zx_bridge.cpp"
    PROPERTIES COMPILE_FLAGS "-fvisibility=default"
)

# Z80Storage.cpp solo arma las tablas de microcódigo al crear la CPU; con -O3 -g
# clang (x86_64) pasa de 13 GB de RAM y no termina. -O1 sin debug info basta.
set_source_files_properties(
    "${CLK}/Processors/Z80/Implementation/Z80Storage.cpp"
    PROPERTIES COMPILE_OPTIONS "-O1;-g0"
)

find_library(log-lib log)
find_library(z-lib z)
target_link_libraries(zx_bridge ${log-lib} ${z-lib})
target_link_options(zx_bridge PRIVATE "-Wl,-z,max-page-size=16384")
