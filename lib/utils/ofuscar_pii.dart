/// Ofuscación de datos personales (PII) para logs — hallazgo B03 de la auditoría.
///
/// Los logs NUNCA deben filtrar PII (línea base de seguridad del equipo). `ofuscarEmail`
/// deja una pista mínima para correlacionar fallos del mismo usuario dentro de una
/// corrida —el primer carácter del local-part— sin exponer la dirección ni el dominio.
library;

/// Devuelve una versión ofuscada de [email] apta para logs: `c***@***`. Ante un valor
/// vacío o sin `@` visible devuelve `***` (no filtra nada).
String ofuscarEmail(String email) {
  final e = email.trim();
  final arroba = e.indexOf('@');
  if (arroba <= 0) return '***';
  return '${e[0]}***@***';
}
