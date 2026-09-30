/*
 * windows_prelude.h — se fuerza con /FI antes de cada fuente al compilar para Windows.
 * CLK usa ssize_t (POSIX), que Windows no declara.
 */
#pragma once
#include <stddef.h>
typedef ptrdiff_t ssize_t;
