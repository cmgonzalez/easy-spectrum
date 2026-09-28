/*
 * android_prelude.h — se fuerza con -include antes de cada fuente.
 * Bionic declara `typedef unsigned int uint_t;` en <sys/types.h>, que choca con
 * la plantilla `uint_t<N>` de CLK (Numeric/Sizes.hpp). Se incluye aquí con el
 * nombre renombrado; el include guard evita que vuelva a declararse.
 */
#pragma once
#define uint_t bionic_uint_t
#include <sys/types.h>
#undef uint_t
