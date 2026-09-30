#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>
#include <vector>

// Instancia única: abrir un archivo con Easy Spectrum ya abierto lo carga en esa
// ventana (WM_COPYDATA) en vez de lanzar otro emulador.

// Propiedad que marca la ventana principal (para encontrarla desde otra instancia).
constexpr wchar_t kMainWindowProp[] = L"EasySpectrum.MainWindow";
// dwData de WM_COPYDATA: argumentos en UTF-8 separados por '\n'.
constexpr ULONG_PTR kOpenArgsMagic = 0x5A585350;  // 'ZXSP'

// Rutas de archivo relativas → absolutas (la otra instancia tiene otro directorio actual).
// Las opciones "--x" y el valor de "--model" quedan igual.
std::vector<std::string> AbsolutizePaths(std::vector<std::string> args);

// Si ya hay otra instancia, le pasa [args], la trae al frente y devuelve true.
bool ForwardToRunningInstance(const std::vector<std::string>& args);

// Decodifica el WM_COPYDATA de ForwardToRunningInstance; false si no es nuestro.
bool DecodeOpenArgs(const COPYDATASTRUCT* data, std::vector<std::string>* args);

#endif  // RUNNER_SINGLE_INSTANCE_H_
