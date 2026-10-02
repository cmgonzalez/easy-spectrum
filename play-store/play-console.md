# Respuestas para Play Console (las dos ediciones)

## Configuración de la app
| Campo | Free | Pro |
|---|---|---|
| Idioma predeterminado | en-US | en-US |
| Tipo | App | App |
| Categoría | Entretenimiento (alternativa: Herramientas) | igual |
| Gratis / de pago | Gratis | De pago (sugerido USD 2,99; precio no se puede bajar a gratis después sin crear otra app) |
| Contiene anuncios | Sí | No |
| Correo de contacto | soporte@easysoft.cl | soporte@easysoft.cl |
| Sitio web | https://www.easysoft.cl | igual |
| Política de privacidad | https://www.easysoft.cl/easy-spectrum/privacy.html | igual |

## Público objetivo
- Edades: **13-15, 16-17, 18+** (no marcar menores de 13: evita la política de Familias y los requisitos de anuncios para niños).
- ¿Atrae a niños sin querer? No (las capturas no deben tener personajes infantiles).

## Acceso a la app
- Todas las funciones disponibles sin restricciones (no hay login).

## Clasificación de contenido (cuestionario IARC)
- Categoría: «Todas las demás tipos de apps» o «Juego» según cómo se clasifique; responder sobre la app en sí.
- Violencia, sexo, lenguaje, drogas, apuestas: No.
- ¿Los usuarios interactúan o comparten contenido entre ellos? No.
- ¿Comparte la ubicación? No. ¿Compras digitales? Free: No / Pro: No (es de pago, no IAP).
- Nota: la app carga archivos del usuario; la app no incluye juegos.

## Anuncios / ID de publicidad
- Free: ¿usa ID de publicidad? **Sí** → finalidad: Publicidad o marketing; Estadísticas; Prevención de fraude.
- Pro: **No** (el manifiesto Pro elimina AD_ID; verificar con `aapt dump permissions`).

## Seguridad de los datos

### Free (AdMob)
¿Recopila o comparte datos? **Sí**. ¿Cifrado en tránsito? **Sí**. ¿Permite solicitar eliminación? No hay cuenta → «No» (o ofrecer correo de soporte).

| Tipo de dato | Recopilado | Compartido | Opcional | Finalidad |
|---|---|---|---|---|
| Ubicación aproximada | Sí | Sí | No | Publicidad, Estadísticas, Prevención de fraude |
| Interacciones con la app | Sí | Sí | No | Publicidad, Estadísticas |
| Diagnósticos (rendimiento) | Sí | Sí | No | Estadísticas |
| IDs del dispositivo u otros | Sí | Sí | No | Publicidad, Estadísticas, Prevención de fraude |

(Basado en la guía de Google para el SDK de Google Mobile Ads: revisar https://developers.google.com/admob/android/privacy/play-data-disclosure al completar.)
La consulta a ZXDB envía solo una huella MD5 del archivo, sin identificadores del usuario: no se declara como dato de usuario.

### Pro
¿Recopila o comparte datos? **No** (solo la huella MD5 a ZXDB, sin identificadores).

## Declaración de apps de noticias / salud / financieras / gobierno
- No aplica a ninguna.
