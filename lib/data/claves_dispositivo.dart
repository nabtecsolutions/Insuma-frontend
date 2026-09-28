/// Claves de `SharedPreferences` que describen al DISPOSITIVO y no a la persona.
///
/// Viven en un módulo neutro, y no dentro de `ServicioSesion`, porque no son
/// datos de sesión: que la sesión las declarara obligaba al servicio de
/// apariencia a importar el de sesión —con su almacén cifrado detrás— sólo para
/// construir una clave, y dejaba una dependencia cruzada entre dos servicios sin
/// relación.
///
/// **Lo que se guarda acá sobrevive al cierre de sesión.** Ésa es toda la razón
/// de que el conjunto exista, y también por qué hay que ser estricto: el barrido
/// de `cerrarSesion` borra por DESCARTE, de modo que una clave de sesión nueva
/// queda protegida sin que nadie se acuerde de sumarla. Cada prefijo que se
/// agregue acá le quita esa garantía a una familia entera de claves.
library;

/// Marca "este dispositivo ya completó el primer pull del negocio N" (HU-090).
///
/// Sobrevive al logout porque la base local Drift sigue completa: re-bloquear el
/// dispositivo obligaría a un pull que, offline, no se puede hacer.
const String prefijoPrimerPull = 'insuma_primer_pull_';

/// Preferencias de apariencia: tamaño de letra, y más adelante el tema (HU-054).
///
/// El prefijo dice `dispositivo` a propósito. Con un nombre genérico —`pref_`—
/// la próxima preferencia que aparezca (filtros del historial, último negocio,
/// columnas visibles) caería acá por inercia, y esos datos SÍ son de la persona:
/// en la tablet compartida de la cocina sobrevivirían al logout y el turno
/// siguiente abriría la app con los ajustes del turno anterior.
///
/// **Cambiar este valor es cambiar un contrato de datos ya guardados**, no
/// renombrar una variable: lo escrito con el prefijo viejo queda huérfano, la
/// preferencia vuelve al valor por defecto y el barrido del logout —que ahora lo
/// ve como clave ajena— lo borra. Un cambio futuro necesita migración de una
/// sola vez en `inicializar()`.
///
/// Acá NO se migró, y es una decisión, no un olvido: el prefijo anterior
/// (`insuma_pref_`) nunca llegó a `dev`, sólo existió en commits intermedios de
/// la rama de HU-054. El único dato en riesgo es el tamaño de letra en un
/// dispositivo de prueba que haya corrido esos commits; migrarlo dejaría código
/// muerto por construcción en cualquier instalación real.
const String prefijoPreferenciasDispositivo = 'insuma_dispositivo_';

/// Lo que el cierre de sesión NO borra. Ver la advertencia de arriba antes de
/// sumar un prefijo.
const List<String> prefijosDelDispositivo = [
  prefijoPrimerPull,
  prefijoPreferenciasDispositivo,
];
