cmake_minimum_required(VERSION 3.22.1)
project(zx_bridge CXX)

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
    Machines/Sinclair/ZXSpectrum/ZXSpectrum.cpp
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

add_library(zx_bridge SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/zx_bridge.cpp"
    ${CLK_SOURCES}
)

target_include_directories(zx_bridge PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CLK}"
)

target_compile_definitions(zx_bridge PRIVATE NDEBUG)

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
