// Servidor PDP (Prisma Debug Protocol) — ver doc/PDP.md.
// JSON por línea sobre TCP (solo 127.0.0.1). El hilo del servidor solo mueve bytes: todos los
// comandos se ejecutan en el hilo del emulador, dentro de pdp_pump() (llamado desde zx_run).
#pragma once
#include <functional>
#include <string>

namespace pdp {

struct Host {
	bool supported = true;			// false: máquina sin depuración (p. ej. la Next, fase posterior)
	std::string machine;			// "zx48", "zx128"…
	std::function<void()> reset;	// reinicia la máquina
	std::function<double()> emulated_seconds;
	std::function<void(int key, bool down)> set_key;	// key = (fila << 8) | bit
	std::function<void(int mask)> set_joy;			// ZX_JOY_*
	std::function<void(const std::string &)> type;	// texto con el Typer de CLK
};

// Arranca el servidor en `port` (0 = puerto libre). Devuelve el puerto o -1 si falla.
int start(int port);
void stop();
bool running();

// Ejecuta los comandos pendientes y emite eventos. Hilo del emulador.
void pump(const Host &host);

}  // namespace pdp
