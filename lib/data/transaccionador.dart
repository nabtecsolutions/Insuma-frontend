import '../database/database.dart';
import '../services/servicio_sincronizacion_supabase.dart';

/// Corre un bloque dentro de una transacción, coordinando el Outbox si lo hay.
///
/// ## Por qué existe, y por qué es un objeto y no un `if` suelto
///
/// En esta app **escribir son DOS pasos**: escribir en Drift **y** encolar la
/// mutación en el Outbox. Las dos tienen que ir en la MISMA transacción, porque
/// si sólo pasa la primera la fila queda en `estadoSync: 'pendiente'` sin nada
/// en la cola, y ese estado es **terminal**: el pull no la pisa porque cree que
/// hay un cambio en vuelo, y nadie la vuelve a encolar. Eso ya pasó (#223).
///
/// `ServicioSincronizacionSupabase.enTransaccion` es lo que garantiza eso:
/// además de abrir la transacción, **suspende el drenaje** mientras dura. Una
/// `db.transaction` a secas NO lo hace.
///
/// Hasta #269, seis services repetían este mismo ternario:
///
/// ```dart
/// _sync != null ? _sync.enTransaccion(cuerpo) : _db.transaction(cuerpo);
/// ```
///
/// Seis copias de una regla de atomicidad es seis oportunidades de escribir la
/// séptima al revés, y el modo de falla de escribirla al revés **no tiene
/// síntoma**: todo anda, y los cambios dejan de subir. Acá hay una sola.
///
/// ## Por qué el null no se elimina
///
/// El caso sin sincronización es real y está soportado por diseño: la app corre
/// con la persistencia local sola (ver `ConfigPersistencia`), y ahí no hay
/// Outbox que coordinar. Lo que NO puede pasar es que alguien elija mal entre
/// las dos ramas, y eso es justamente lo que esta clase saca de la mesa.
class Transaccionador {
  final BaseDatosApp _db;
  final ServicioSincronizacionSupabase? _sync;

  const Transaccionador(this._db, [this._sync]);

  /// Corre [cuerpo] atómicamente. Anidable: con Outbox, el drenaje arranca
  /// recién al commit de la transacción MÁS EXTERNA.
  Future<T> correr<T>(Future<T> Function() cuerpo) {
    final sync = _sync;
    return sync != null ? sync.enTransaccion(cuerpo) : _db.transaction(cuerpo);
  }

  /// `true` si las escrituras de este bloque además se encolan para subir.
  ///
  /// Para que un service pueda DECIRLO en vez de deducirlo mirando si su `_sync`
  /// es nulo, que es la misma comparación que esta clase vino a centralizar.
  bool get coordinaOutbox => _sync != null;
}
