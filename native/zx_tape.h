// zx_tape.h — ganchos de cinta que se inyectan en copias parcheadas de CLK (ver
// native/CMakeLists.txt, parches "cinta-bloque-*" y "cinta-grabar") y estado del gestor de
// cintas (doc/TAPE_MANAGER.md). La implementación está en zx_bridge.cpp.
//
// Posición de la cinta: CLK lee cada bloque de un .tap (ZXSpectrumTAP::read_next_block) o de
// un .tzx (TZX::push_next_pulses) en un único punto, justo cuando empieza a emitir sus
// pulsos. Ahí se avisa el offset del bloque en el archivo; el bridge lo traduce a índice.
// El trap de carga rápida (LD-BYTES) lee del mismo serialiser, así que también se cuenta.
#pragma once

#include <cstddef>
#include <cstdint>

namespace zxtape {

// Empieza a sonar el bloque que está en `offset` del archivo (offset >= tamaño = fin de cinta).
void note_block(long offset);

// Grabación de SAVE (trap de SA-BYTES 0x04C2 del ROM 48 BASIC).
bool recording();
// Bloque completo: flag + datos + checksum (sin la longitud de 2 bytes del .tap).
void record_block(const uint8_t *data, size_t length);

}	// namespace zxtape
