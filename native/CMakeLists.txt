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

# Modelos Timex (TC2048, TS2068): se agregan AL FINAL del enum de CLK (0-5 no cambian) en una
# copia de Target.hpp que tapa a la original (directorio de includes antepuesto, ver más abajo).
# Todos los que la usan la incluyen como "Analyser/Static/ZXSpectrum/Target.hpp".
set(CLK_OVER "${CMAKE_CURRENT_BINARY_DIR}/clk_over")
set(TARGET_SRC "${CLK}/Analyser/Static/ZXSpectrum/Target.hpp")
configure_file("${TARGET_SRC}" "${CMAKE_CURRENT_BINARY_DIR}/Target.hpp.orig" COPYONLY)
file(READ "${TARGET_SRC}" TARGET_TEXT)
string(REPLACE "\r\n" "\n" TARGET_TEXT "${TARGET_TEXT}")
clk_patch(TARGET_TEXT modelos-timex "\t\tPlus3,\n\t);" "\t\tPlus3,\n\t\tTC2048,\n\t\tTS2068,\n\t);")
file(WRITE "${CLK_OVER}/Analyser/Static/ZXSpectrum/Target.hpp" "${TARGET_TEXT}")

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
#    Desactivable (zx_ulaplus_mode = 0: los puertos no responden). Con el modo extendido
#    (zx_ulaplus_mode = 2) el subgrupo del registro de modo replica los modos de vídeo Timex.
zx_patch(ulaplus-escritura
    "\t\t\t\t// Test for classic 128kb paging register (i.e. port 7ffd).\n"
    "\t\t\t\t// ULAplus.\n\t\t\t\tif(zx_ulaplus_mode) {\n\t\t\t\t\tif(address == 0xbf3b) {\n\t\t\t\t\t\tvideo_->ulaplus_write_register(*cycle.value);\n\t\t\t\t\t\ttimex_sync_video();\n\t\t\t\t\t}\n\t\t\t\t\tif(address == 0xff3b) video_->ulaplus_write_data(*cycle.value);\n\t\t\t\t}\n\n@TIMEX_OUT@\t\t\t\t// Test for classic 128kb paging register (i.e. port 7ffd).\n")
zx_patch(ulaplus-lectura
    "\t\t\t\tif constexpr (model <= Model::Plus2) {\n\t\t\t\t\tif(!did_match) {\n"
    "\t\t\t\tif(address == 0xff3b && zx_ulaplus_mode) {\n\t\t\t\t\tdid_match = true;\n\t\t\t\t\t*cycle.value = video_->ulaplus_read_data();\n\t\t\t\t}\n\n@TIMEX_IN@\t\t\t\tif constexpr (model <= Model::Plus2) {\n\t\t\t\t\tif(!did_match) {\n")
zx_patch(ulaplus-reset
    "\t\tupdate_video_base();\n\t\tz80_.set_power_on_reset();\n"
    "\t\tupdate_video_base();\n\t\tvideo_->ulaplus_reset();\n\t\ttimex_reset();\n\t\tz80_.set_power_on_reset();\n")

# 4. Ratón Kempston (zx_mouse.h): FBDF/FFDF/FADF. Va antes de la lectura del joystick Kempston
#    porque esos puertos (byte bajo DF) también tienen A5 a 0 y el joystick los taparía.
zx_patch(raton-include
    "#include \"ZXSpectrum.hpp\"\n"
    "#include \"ZXSpectrum.hpp\"\n#include \"zx_mouse.h\"\n")
zx_patch(raton-lectura
    "\t\t\t\tif(!(address&32)) {\n\t\t\t\t\tdid_match = true;\n\t\t\t\t\t*cycle.value &= static_cast<Joystick *>(joysticks_[0].get())->get_kempston();\n\t\t\t\t}\n"
    "\t\t\t\tuint8_t mouse_value;\n\t\t\t\tif(g_zx_mouse.read(address, mouse_value)) {\n\t\t\t\t\tdid_match = true;\n\t\t\t\t\t*cycle.value = mouse_value;\n\t\t\t\t} else if(!(address&32)) {\n\t\t\t\t\tdid_match = true;\n\t\t\t\t\t*cycle.value &= static_cast<Joystick *>(joysticks_[0].get())->get_kempston();\n\t\t\t\t}\n")

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
    "#include \"ZXSpectrum.hpp\"\n#include \"zx_debug.h\"\n#include \"clk_patches/snapshot_access.h\"\n")
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

# 5. Grabación de SAVE (gestor de cintas, doc/TAPE_MANAGER.md): con la grabación activa, al
#    entrar en SA-BYTES (0x04C2) del ROM 48 BASIC se copia el bloque (A = flag, IX = origen,
#    DE = longitud) y se devuelve con RET sin emitir sonido. Los guardadores con rutina propia
#    no pasan por aquí y no se capturan.
zx_patch(cinta-grabar-include
    "#include \"ZXSpectrum.hpp\"\n"
    "#include \"ZXSpectrum.hpp\"\n#include \"zx_tape.h\"\n")
zx_patch(cinta-grabar
    "\t\t\tcase PartialMachineCycle::ReadOpcode:\n\t\t\t\t// Fast loading: ROM version.\n"
    "\t\t\tcase PartialMachineCycle::ReadOpcode:\n\t\t\t\tif(Model::TS2068 != model && address == 0x04c2 && zxtape::recording() && banks_[0].read == &rom_[classic_rom_offset()]) {\n\t\t\t\t\tusing Register = CPU::Z80::Register;\n\t\t\t\t\tconst uint8_t flag = uint8_t(z80_.value_of(Register::A));\n\t\t\t\t\tuint16_t length = z80_.value_of(Register::DE);\n\t\t\t\t\tuint16_t source = z80_.value_of(Register::IX);\n\t\t\t\t\tstd::vector<uint8_t> block;\n\t\t\t\t\tblock.reserve(size_t(length) + 2);\n\t\t\t\t\tblock.push_back(flag);\n\t\t\t\t\tuint8_t parity = flag;\n\t\t\t\t\twhile(length--) {\n\t\t\t\t\t\tconst uint8_t byte = banks_[source >> 14].read[source];\n\t\t\t\t\t\tblock.push_back(byte);\n\t\t\t\t\t\tparity ^= byte;\n\t\t\t\t\t\t++source;\n\t\t\t\t\t}\n\t\t\t\t\tblock.push_back(parity);\n\t\t\t\t\tzxtape::record_block(block.data(), block.size());\n\t\t\t\t\t*cycle.value = 0xc9;\t// RET\n\t\t\t\t\tbreak;\n\t\t\t\t}\n\t\t\t\t// Fast loading: ROM version.\n")

# 6. Unidad del +3 con dos cabezas: FDC.hpp de CLK la crea con una sola y +3DOS rechaza los
#    discos de doble cara (720K, 80 pistas) al leer el ID de la cara 1. Se usa una copia
#    parcheada (FDC_plus3.hpp) que queda junto a ZXSpectrum_patched.cpp.
set(FDC_SRC "${CLK}/Machines/AmstradCPC/FDC.hpp")
configure_file("${FDC_SRC}" "${CMAKE_CURRENT_BINARY_DIR}/FDC_plus3.hpp.orig" COPYONLY)
file(READ "${FDC_SRC}" FDC_TEXT)
string(REPLACE "\r\n" "\n" FDC_TEXT "${FDC_TEXT}")
clk_patch(FDC_TEXT disco-dos-caras
    "emplace_drive(clock_rate.as<int>(), 300, 1);" "emplace_drive(clock_rate.as<int>(), 300, 2);")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/FDC_plus3.hpp" "${FDC_TEXT}")
zx_patch(disco-dos-caras-include
    "#include \"Machines/AmstradCPC/FDC.hpp\"\n" "#include \"FDC_plus3.hpp\"\n")

# 7. Timex TC2048 / TS2068 (clk_patches/timex_*.inc). Puertos $FF/$F4/$F5/$F6, MMU de 8K,
#    EXROM/DOCK, NTSC del TS2068, sin interrupción con el bit 6 de $FF.
foreach(INC timex_machine timex_out timex_in)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/clk_patches/${INC}.inc" INC_TEXT)
    string(REPLACE "\r\n" "\n" INC_TEXT "${INC_TEXT}")
    string(TOUPPER "${INC}" INC_VAR)
    set(${INC_VAR} "${INC_TEXT}")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/clk_patches/${INC}.inc")
endforeach()
zx_patch(timex-puertos-out "@TIMEX_OUT@" "${TIMEX_OUT}")
zx_patch(timex-puertos-in "@TIMEX_IN@" "${TIMEX_IN}")
zx_patch(timex-miembros
    "private:\n\tCPU::Z80::Processor<ConcreteMachine, false, false> z80_;"
    "private:\n${TIMEX_MACHINE}\tCPU::Z80::Processor<ConcreteMachine, false, false> z80_;")
zx_patch(timex-crear
    "\t\tcase Plus3:\t\t\treturn std::make_unique<ConcreteMachine<Plus3>>(zx_target, rom_fetcher);\n"
    "\t\tcase Plus3:\t\t\treturn std::make_unique<ConcreteMachine<Plus3>>(zx_target, rom_fetcher);\n\t\tcase TC2048:\t\treturn std::make_unique<ConcreteMachine<TC2048>>(zx_target, rom_fetcher);\n\t\tcase TS2068:\t\treturn std::make_unique<ConcreteMachine<TS2068>>(zx_target, rom_fetcher);\n")
zx_patch(timex-rom "\t\tconst auto request = ROM::Request(rom_name);"
    "\t\tif constexpr (Model::TS2068 == model) rom_name = ROM::Name::SpectrumPlus3;	// 24K: casa + EXROM\n\t\tconst auto request = ROM::Request(rom_name);")
zx_patch(timex-switch "switch(model) {" "switch(base_model) {")
zx_patch(timex-reloj "\t\treturn model < Model::OneTwoEightK ? OriginalClockRate : Plus3ClockRate;"
    "\t\tif constexpr (Model::TS2068 == model) return 3'528'000;\n\t\treturn model < Model::OneTwoEightK ? OriginalClockRate : Plus3ClockRate;")
# El ROM del TS2068 no tiene LD-BYTES en 0x056B: sin trap (carga a velocidad real + turbo).
zx_patch(timex-trap "if(use_fast_tape_hack_ && address == 0x056b"
    "if(Model::TS2068 != model && use_fast_tape_hack_ && address == 0x056b")
zx_patch(timex-int "z80_.set_interrupt_line(video_.get()->get_interrupt_line(),"
    "z80_.set_interrupt_line(video_.get()->get_interrupt_line() && !(timex_ff_ & 0x40),")
zx_patch(timex-puerto-fe "if(!(address&1)) {" "if(ula_port(address)) {")
zx_patch(timex-bancos "std::array<Bank, 4> banks_;" "std::array<Bank, 8> banks_;	// chunks de 8K (MMU del TS2068)")
zx_patch(timex-bancos-a "banks_[address >> 14]" "banks_[address >> 13]")
zx_patch(timex-bancos-t "banks_[target >> 14]" "banks_[target >> 13]")
zx_patch(timex-bancos-s "banks_[source >> 14]" "banks_[source >> 13]")
zx_patch(timex-bancos-snap "&banks_[c + 1].write[(c+1) * 0x4000]" "&banks_[(c + 1) * 2].write[(c+1) * 0x4000]")
zx_patch(timex-bancos-video
    "\t\tbanks_[0].is_video = banks_[0].page == video_page;\n\t\tbanks_[1].is_video = banks_[1].page == video_page;\n\t\tbanks_[2].is_video = banks_[2].page == video_page;\n\t\tbanks_[3].is_video = banks_[3].page == video_page;\n"
    "\t\tfor(auto &bank : banks_) bank.is_video = bank.page == video_page;\n")
clk_patch_block(ZX_TEXT timex-set-memory
    "\tvoid set_memory(std::size_t bank, uint8_t source) {"
    "\t\tbanks_[bank].write = ((source < 0x80) ? read : scratch_.data()) - offset;\n\t}\n"
    "\tvoid set_memory(std::size_t bank, uint8_t source) {
		uint8_t *const base = (source < 0x80) ? &ram_[source * 16384] : &rom_[(source & 0x7f) * 16384];
		for(std::size_t half = 0; half < 2; half++) {
			auto &chunk = banks_[bank * 2 + half];
			if constexpr (model >= Model::Plus2a) {
				chunk.is_contended = source >= 4 && source < 8;
			} else {
				chunk.is_contended = source < 0x80 && source & 1;
			}
			chunk.page = source;

			uint8_t *const read = base + half * 8192;
			const auto offset = bank * 16384 + half * 8192;
			chunk.read = read - offset;
			chunk.write = ((source < 0x80) ? read : scratch_.data()) - offset;
		}
	}
")
zx_patch(timex-mmu "\t\tdisable_paging_ = port7ffd_ & 0x20;\n"
    "\t\tdisable_paging_ = port7ffd_ & 0x20;\n\t\ttimex_overlay();\n")
zx_patch(timex-flush-video "(address & 0x3fff) < 6912" "(address & 0x3fff) < video_write_limit()")
# Snapshot de Timex: el lector .z80 deja $F4 en last_7ffd y $FF en last_1ffd.
zx_patch(timex-snapshot
    "\t\t\t} else {\n\t\t\t\tstd::copy_n(state->ram.begin(), std::min(ram_.size(), state->ram.size()), ram_.data());"
    "\t\t\t\tif constexpr (is_timex) {\n\t\t\t\t\ttimex_f4_ = state->last_7ffd;\n\t\t\t\t\ttimex_write_ff(state->last_1ffd);\n\t\t\t\t}\n\t\t\t} else {\n\t\t\t\tstd::copy_n(state->ram.begin(), std::min(ram_.size(), state->ram.size()), ram_.data());")
zx_patch(timex-video "\tJustInTimeActor<VideoType> video_;"
    "\tusing VideoTypeTimex = std::conditional_t<Model::TS2068 == model, Video::Video<Video::Timing::TS2068>,\n\t\tstd::conditional_t<Model::TC2048 == model, Video::Video<Video::Timing::TC2048>, VideoType>>;\n\tJustInTimeActor<VideoTypeTimex> video_;")
# Al final: toda comparación "model <op> Model::X" pasa a base_model (los Timex son 48K para
# el resto de la máquina). El código inyectado escribe "Model::X == model" para no caer aquí.
string(REGEX REPLACE "([^_A-Za-z0-9])model ([<>=]=?) Model::" "\\1base_model \\2 Model::" ZX_TEXT "${ZX_TEXT}")
file(WRITE "${ZX_PATCHED}" "${ZX_TEXT}")

# Posición de la cinta (gestor de cintas): copias de ZXSpectrumTAP.cpp y TZX.cpp que avisan
# a zx_tape.h el offset de cada bloque justo cuando empieza a sonar (offset >= tamaño = fin).
function(tape_patched_copy SRC OUT VAR)
    configure_file("${CLK}/${SRC}" "${OUT}.orig" COPYONLY)  # re-configura si cambia
    file(READ "${CLK}/${SRC}" TEXT)
    string(REPLACE "\r\n" "\n" TEXT "${TEXT}")
    set(${VAR} "${TEXT}" PARENT_SCOPE)
endfunction()

set(TAP_PATCHED "${CMAKE_CURRENT_BINARY_DIR}/ZXSpectrumTAP_patched.cpp")
tape_patched_copy(Storage/Tape/Formats/ZXSpectrumTAP.cpp "${TAP_PATCHED}" TAP_TEXT)
clk_patch(TAP_TEXT cinta-bloque-include
    "#include \"ZXSpectrumTAP.hpp\"\n" "#include \"ZXSpectrumTAP.hpp\"\n#include \"zx_tape.h\"\n")
clk_patch(TAP_TEXT cinta-bloque-fin
    "\tif(file_.tell() == file_.stats().st_size) {\n\t\tphase_ = Phase::Gap;\n"
    "\tif(file_.tell() == file_.stats().st_size) {\n\t\tzxtape::note_block(long(file_.tell()));\n\t\tphase_ = Phase::Gap;\n")
# Último bloque de datos: CLK da la cinta por terminada en cuanto empieza su pausa final.
clk_patch(TAP_TEXT cinta-bloque-ultimo
    "\t\t\t\t\tif(block_type_) {\n\t\t\t\t\t\tdistance_into_phase_ = 0;\n\t\t\t\t\t\tphase_ = Phase::Gap;\n"
    "\t\t\t\t\tif(block_type_) {\n\t\t\t\t\t\tdistance_into_phase_ = 0;\n\t\t\t\t\t\tphase_ = Phase::Gap;\n\t\t\t\t\t\tif(file_.tell() == file_.stats().st_size) zxtape::note_block(long(file_.tell()));\n")
clk_patch(TAP_TEXT cinta-bloque
    "\t} else {\n\t\tblock_length_ = file_.get_le<uint16_t>();\n"
    "\t} else {\n\t\tzxtape::note_block(long(file_.tell()));\n\t\tblock_length_ = file_.get_le<uint16_t>();\n")
file(WRITE "${TAP_PATCHED}" "${TAP_TEXT}")

set(TZX_PATCHED "${CMAKE_CURRENT_BINARY_DIR}/TZX_patched.cpp")
tape_patched_copy(Storage/Tape/Formats/TZX.cpp "${TZX_PATCHED}" TZX_TEXT)
clk_patch(TZX_TEXT cinta-bloque-include
    "#include \"TZX.hpp\"\n" "#include \"TZX.hpp\"\n#include \"zx_tape.h\"\n")
clk_patch(TZX_TEXT cinta-bloque
    "\twhile(empty()) {\n\t\tconst uint8_t chunk_id = file_.get();\n"
    "\twhile(empty()) {\n\t\tzxtape::note_block(long(file_.tell()));\n\t\tconst uint8_t chunk_id = file_.get();\n")
file(WRITE "${TZX_PATCHED}" "${TZX_TEXT}")

# 8272: los bits "unidad N buscando" del registro de estado principal se encendían al empezar un
# SEEK/RECALIBRATE y no se apagaban nunca. +3DOS no los mira, pero los cargadores propios que
# esperan a que se apaguen antes de pedir SENSE INTERRUPT STATUS se quedaban colgados (Flashback +3).
set(FDC8272_PATCHED "${CMAKE_CURRENT_BINARY_DIR}/i8272_patched.cpp")
tape_patched_copy(Components/8272/i8272.cpp "${FDC8272_PATCHED}" FDC8272_TEXT)
clk_patch(FDC8272_TEXT seek-fin
    "drives_[c].phase = Drive::CompletedSeeking;"
    "drives_[c].phase = Drive::CompletedSeeking; status_.set(MainStatus(1 << c), false);")
clk_patch(FDC8272_TEXT seek-cancelado
    "drives_[c].phase = Drive::NotSeeking;"
    "drives_[c].phase = Drive::NotSeeking; status_.set(MainStatus(1 << c), false);")
clk_patch(FDC8272_TEXT seek-inmediato
    "drives_[drive].phase = Drive::CompletedSeeking;"
    "drives_[drive].phase = Drive::CompletedSeeking; status_.set(MainStatus(1 << drive), false);")
file(WRITE "${FDC8272_PATCHED}" "${FDC8272_TEXT}")
list(REMOVE_ITEM CLK_SOURCES "${CLK}/Components/8272/i8272.cpp")
set_source_files_properties("${FDC8272_PATCHED}" PROPERTIES
    INCLUDE_DIRECTORIES "${CLK}/Components/8272")
list(APPEND CLK_SOURCES "${FDC8272_PATCHED}")

# .z80: el modo de hardware 3 es 128K en la v2 pero 48K + M.G.T. en la v3 (cabecera de 54/55
# bytes), donde 128K es el 4 (5 y 6 = 128K con Interface 1 / M.G.T.). CLK solo conocía la
# tabla de la v2 y rechazaba los .z80 v3 de 128K que guardan Fuse y casi todos los emuladores.
set(Z80_PATCHED "${CMAKE_CURRENT_BINARY_DIR}/Z80_patched.cpp")
tape_patched_copy(Storage/State/Z80.cpp "${Z80_PATCHED}" Z80_TEXT)
clk_patch(Z80_TEXT z80-modos-v3
    "\t\tcase 3:\t\tresult->model = Target::Model::OneTwoEightK;\tbreak;\n"
    "\t\tcase 3:\t\tresult->model = bonus_header_size == 23 ? Target::Model::OneTwoEightK : Target::Model::FortyEightK;\tbreak;\n\t\tcase 4:\n\t\tcase 5:\n\t\tcase 6:\t\tresult->model = Target::Model::OneTwoEightK;\tbreak;\n")
# El color del borde (bits 1-3 del byte 12) no se leía: todo .z80 abría con borde negro.
clk_patch(Z80_TEXT z80-borde
    "\tconst uint8_t misc = (raw_misc == 0xff) ? 1 : raw_misc;\n"
    "\tconst uint8_t misc = (raw_misc == 0xff) ? 1 : raw_misc;\n\tstate->video.border_colour = (misc >> 1) & 7;\n")
# Timex en .z80 v3: hardware 14 = TC2048, 15 = TC2068 y 128 = TS2068 (los dos últimos como
# TS2068). El byte 35 es el último OUT a $F4 (queda en last_7ffd) y el 36 el último a $FF
# (queda en last_1ffd; en la cabecera de 55 bytes el $1FFD se ignora). Memoria como el 48K.
clk_patch(Z80_TEXT z80-timex-modelo
    "\t\tcase 13:\tresult->model = Target::Model::Plus2a;\t\t\tbreak;\n"
    "\t\tcase 13:\tresult->model = Target::Model::Plus2a;\t\t\tbreak;\n\t\tcase 14:\tresult->model = Target::Model::TC2048;\t\t\tbreak;\n\t\tcase 15:\n\t\tcase 128:\tresult->model = Target::Model::TS2068;\t\t\tbreak;\n")
clk_patch(Z80_TEXT z80-timex-ff
    "\tstate->last_7ffd = file.get();\n\n\tfile.seek(1, Whence::CUR);\n"
    "\tstate->last_7ffd = file.get();\n\n\tconst bool timex = result->model == Target::Model::TC2048 || result->model == Target::Model::TS2068;\n\tif(timex) state->last_1ffd = file.get();\n\telse file.seek(1, Whence::CUR);\n")
clk_patch(Z80_TEXT z80-timex-1ffd "\t\t\tstate->last_1ffd = file.get();\n"
    "\t\t\tconst uint8_t port_1ffd = file.get();\n\t\t\tif(!timex) state->last_1ffd = port_1ffd;\n")
clk_patch(Z80_TEXT z80-timex-tstates
    "\t\t\tcase Target::Model::FortyEightK:\n\t\t\t\tstate->video.half_cycles_since_interrupt"
    "\t\t\tcase Target::Model::FortyEightK:\n\t\t\tcase Target::Model::TC2048:\n\t\t\tcase Target::Model::TS2068:\n\t\t\t\tstate->video.half_cycles_since_interrupt")
clk_patch(Z80_TEXT z80-timex-ram
    "\t\tcase Target::Model::FortyEightK:\tstate->ram.resize(48 * 1024);"
    "\t\tcase Target::Model::TC2048:\n\t\tcase Target::Model::TS2068:\n\t\tcase Target::Model::FortyEightK:\tstate->ram.resize(48 * 1024);")
clk_patch(Z80_TEXT z80-timex-paginas
    "if(result->model == Target::Model::SixteenK || result->model == Target::Model::FortyEightK) {"
    "if(result->model == Target::Model::SixteenK || result->model == Target::Model::FortyEightK || timex) {")
file(WRITE "${Z80_PATCHED}" "${Z80_TEXT}")
list(REMOVE_ITEM CLK_SOURCES "${CLK}/Storage/State/Z80.cpp")
set_source_files_properties("${Z80_PATCHED}" PROPERTIES INCLUDE_DIRECTORIES "${CLK}/Storage/State")
list(APPEND CLK_SOURCES "${Z80_PATCHED}")

list(REMOVE_ITEM CLK_SOURCES
    "${CLK}/Storage/Tape/Formats/ZXSpectrumTAP.cpp"
    "${CLK}/Storage/Tape/Formats/TZX.cpp")
set_source_files_properties("${TAP_PATCHED}" "${TZX_PATCHED}" PROPERTIES
    INCLUDE_DIRECTORIES "${CLK}/Storage/Tape/Formats")
list(APPEND CLK_SOURCES "${TAP_PATCHED}" "${TZX_PATCHED}")

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

# Video::State(const Video &) llama a time_since_interrupt(), que no era const: el
# constructor no compilaba (CLK no lo usa). Lo usa zx_save_snapshot.
clk_patch(VIDEO_TEXT tiempo-const "\tHalfCycles time_since_interrupt() {" "\tHalfCycles time_since_interrupt() const {")
clk_patch(VIDEO_TEXT salida-rgb8 "InputDataType::Red2Green2Blue2" "InputDataType::Red8Green8Blue8")
clk_patch(VIDEO_TEXT buffer-pixeles "\tuint8_t *pixel_target_ = nullptr;" "\tuint32_t *pixel_target_ = nullptr;")
clk_patch(VIDEO_TEXT begin-data "pixel_target_ = crt_.begin_data(256);"
    "pixel_target_ = reinterpret_cast<uint32_t *>(crt_.begin_data(256, alignof(uint32_t)));")
clk_patch(VIDEO_TEXT nivel-borde "crt_.output_level<uint8_t>(" "crt_.output_level<uint32_t>(")
clk_patch(VIDEO_TEXT color-borde "\tuint8_t border_colour_ = 0;" "\tuint32_t border_colour_ = 0;")
clk_patch(VIDEO_TEXT set-borde "border_colour_ = palette[colour];" "border_colour_ = border_rgb(colour);")
# Cada columna de 16 píxeles la dibuja output_column() (ulaplus_private.inc): colores ULAplus,
# FLASH, escala de grises y los modos Timex (segunda pantalla, hi-color 8x1, hi-res 512).
clk_patch_block(VIDEO_TEXT columna
    "							for(int column = start_column; column < end_column; column++) {"
    "#undef Output
"
    "							for(int column = start_column; column < end_column; column++) {
								output_column();
")
# Timex: TC2048 (50 Hz, 48K con la primera línea de papel 15 ciclos antes) y TS2068 (NTSC:
# 262 líneas, interrupción 9169 ciclos antes del papel). Datos de libspectrum (Fuse).
clk_patch(VIDEO_TEXT timing-timex "	Plus3,
};" "	Plus3,
	TC2048,
	TS2068,
};")
clk_patch(VIDEO_TEXT timings-timex "	static constexpr Timings get_timings() {
"
    "	static constexpr Timings get_timings() {
		if constexpr (timing == Timing::TS2068) {
			constexpr int delays[] = {6, 5, 4, 3, 2, 1, 0, 0};
			return Timings(224, 262, 4, 128, 9168, delays);
		}
		if constexpr (timing == Timing::TC2048) {
			constexpr int delays[] = {6, 5, 4, 3, 2, 1, 0, 0};
			return Timings(224, 312, 4, 128, 14320, delays);
		}
")
clk_patch(VIDEO_TEXT timex-como-48k "timing == Timing::FortyEightK" "(timing == Timing::FortyEightK || timing >= Timing::TC2048)")
clk_patch(VIDEO_TEXT timex-burst "if constexpr (timing >= Timing::OneTwoEightK) {"
    "if constexpr (timing == Timing::OneTwoEightK || timing == Timing::Plus3) {")
clk_patch(VIDEO_TEXT timex-ntsc "Outputs::Display::Type::PAL50"
    "(timing == Timing::TS2068 ? Outputs::Display::Type::NTSC60 : Outputs::Display::Type::PAL50)")
# Floating bus exacto (aline, multicolor por floating bus): el original devuelve
# last_fetches_, que solo se rellena al COMPLETAR una columna del raster (y solo si hay
# buffer de pixeles): va una columna por detras, la pareja 15 de una linea aparece al
# principio de la siguiente y la primera nunca en su sitio. Se lee directo de la memoria
# de video segun el tiempo, con el desfase zx_fb_lag (half cycles).
clk_patch(VIDEO_TEXT floating-oob "if(time_into_line >= 256 || (time_into_line&8)) {"
    "const int fb_t = time_into_line - zx_fb_lag;
		if(fb_t < 0 || fb_t >= 256 || (fb_t&8)) {")
clk_patch(VIDEO_TEXT floating-valor "const uint8_t value = last_fetches_[(time_into_line >> 1) & 3];"
    "const int fb_slot = (fb_t >> 1) & 3;
		const int fb_base = (fb_slot & 1) ?
			(((line >> 3) << 5) + 6144) :
			(((line & 0x07) << 8) | ((line & 0x38) << 2) | ((line & 0xc0) << 5));
		const uint8_t value = memory_[fb_base + ((fb_t >> 4) << 1) + (fb_slot >> 1)];")
clk_patch(VIDEO_TEXT decl-ulaplus "namespace Sinclair::ZXSpectrum::Video {"
    "extern volatile int zx_ulaplus_active;
extern volatile int zx_ulaplus_mode;
extern volatile int zx_fb_lag;

namespace Sinclair::ZXSpectrum::Video {")
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
    "${CLK_OVER}"
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
