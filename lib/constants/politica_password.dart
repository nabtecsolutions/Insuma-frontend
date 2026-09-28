/// Política de contraseñas de la app (HU-112). Fuente ÚNICA de la longitud mínima
/// para unificar TODOS los flujos de CREACIÓN / cambio de contraseña (onboarding,
/// alta de negocio, alta y reset de miembros de equipo, recuperación).
///
/// Se unificó en 10 —el valor más estricto que ya usaban `ServicioGestionEquipo` y
/// `ServicioRecuperacionPassword`— para no debilitar ningún flujo (la HU es de
/// hardening): antes convivían 6 (onboarding), 8 (alta) y 10 (equipo/recuperación).
///
/// Nota: el LOGIN usa un piso más lenient a propósito (no rechaza contraseñas
/// legacy más cortas que ya existían en la base); la fuerza se exige al CREAR, no
/// al entrar.
class PoliticaPassword {
  static const int longitudMinima = 10;
}
