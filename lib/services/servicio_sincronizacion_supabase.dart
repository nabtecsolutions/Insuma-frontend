import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../data/config_persistencia.dart';
import 'servicio_configuracion.dart';
import '../data/liberacion_pendientes.dart';
import 'contrato_sincronizacion.dart';
import 'servicio_conflictos.dart';
import 'politica_reintentos.dart';

/// Servicio de sincronización offline-first (Outbox Pattern) y ÚNICO punto de
/// conexión con Supabase para la escritura de datos (el "Model" remoto).
///
/// Las capas superiores (servicios/controladores) NO hablan con Supabase: sólo
/// encolan mutaciones locales mediante [encolarMutacion]. Este servicio las
/// envía en orden (FIFO) cuando hay conexión, con:
///   - deduplicación de mutaciones equivalentes (RN-015 idempotencia),
///   - reintentos con backoff exponencial y descarte (dead-letter) tras
///     [maxIntentosPorDefecto] rechazos DEFINITIVOS —un fallo de red, un
///     timeout o un 5xx transitorio no gastan intentos: no dicen nada sobre si
///     la mutación es válida (C-02, ver `PoliticaReintentos`)—,
///   - mapeo de claves camelCase → snake_case por seguridad,
///   - marcado del registro local como 'sincronizado'.
///
/// Al recuperar la conexión hace una sincronización COMPLETA (HU-027): primero
/// sube los pendientes (push) y luego baja las novedades del negocio (pull) a
/// través del hook [alReconectar].
class ServicioSincronizacionSupabase implements SincronizadorOutbox {
  final BaseDatosApp baseDatos;
  final SupabaseClient clienteSupabase;

  /// Hook opcional de DESCARGA (pull). Al recuperar conexión, además de subir los
  /// pendientes (push) se invoca este callback para bajar las actualizaciones de
  /// otros dispositivos del negocio activo (HU-027: "sincroniza pendientes Y
  /// descarga actualizaciones"). Se inyecta desde `main` para no acoplar este
  /// servicio a la sesión ni a [ServicioDescargaNegocio].
  final Future<void> Function()? alReconectar;

  /// Bitácora de conflictos (HU-028). Null en tests que no la ejercitan.
  final ServicioConflictos? conflictos;

  ServicioSincronizacionSupabase({
    required this.baseDatos,
    required this.clienteSupabase,
    this.conflictos,
    this.alReconectar,
    Duration? tiempoLimitePush,
  }) : tiempoLimitePush = tiempoLimitePush ?? tiempoLimitePushPorDefecto;

  /// Ver [tiempoLimitePushPorDefecto]. Se inyecta en test para no esperar 30s.
  final Duration tiempoLimitePush;

  static const int maxIntentosPorDefecto = 8;
  bool _sincronizando = false;

  /// Profundidad de transacciones locales en curso (HU-079 / C2). Mientras es > 0,
  /// [encolarMutacion] NO dispara el drenaje: las inserciones en la cola participan
  /// de la transacción y el envío a red se posterga al post-commit.
  int _drenajeSuspendido = 0;

  /// Monitorea los cambios de red para gatillar la sincronización al recuperar la conexión.
  void monitorearConectividad() {
    Connectivity().onConnectivityChanged.listen((
      List<ConnectivityResult> resultados,
    ) {
      if (resultados.isNotEmpty &&
          resultados.first != ConnectivityResult.none) {
        sincronizarAlReconectar();
      }
    });
  }

  /// Sincronización COMPLETA al recuperar conexión (HU-027): primero sube los
  /// cambios locales pendientes (push) y luego descarga las actualizaciones del
  /// negocio (pull). Así se cumple el criterio "sincroniza pendientes Y descarga
  /// actualizaciones" al volver la conectividad.
  Future<void> sincronizarAlReconectar() async {
    await sincronizarPendientes();
    await _descargarActualizaciones();
  }

  /// Ejecuta el pull inyectado ([alReconectar]) en modo best-effort: un fallo de
  /// descarga NO debe abortar ni revertir el push ya realizado.
  Future<void> _descargarActualizaciones() async {
    final descargar = alReconectar;
    if (descargar == null) return;
    try {
      await descargar();
    } catch (e) {
      debugPrint(
        '[SYNC] Error al descargar actualizaciones tras reconectar: $e',
      );
    }
  }

  bool get _puedeSincronizar {
    if (!ConfigPersistencia.sincronizacionActiva) return false;
    final url = ServicioConfiguracion.obtener('SUPABASE_URL');
    final key = ServicioConfiguracion.obtener('SUPABASE_ANON_KEY');
    if (url.isEmpty || key.isEmpty) return false;
    // Sin sesión de Supabase Auth, toda escritura viaja como rol `anon` y la RLS
    // la rechaza (42501). Dejamos los ítems en la cola SIN gastar reintentos hasta
    // que exista una sesión válida; así no caen en dead-letter por falta de
    // identidad y se drenan solos cuando el admin/usuario inicia sesión.
    return clienteSupabase.auth.currentSession != null;
  }

  /// Allow-list de nombres de tabla válidos para el push (B03). Se DERIVA del esquema
  /// Drift real (`allTables`), así nunca se desactualiza al agregar una tabla. Se usa
  /// como defensa en profundidad: sólo se envían mutaciones a tablas conocidas.
  late final Set<String> _tablasValidas = {
    for (final t in baseDatos.allTables) t.actualTableName,
  };

  /// ¿[nombreTabla] es una tabla conocida del esquema? (allow-list del push, B03.)
  @visibleForTesting
  bool esNombreTablaValido(String nombreTabla) =>
      _tablasValidas.contains(nombreTabla);

  /// Tope de tiempo para cada push individual.
  ///
  /// **Sin esto el drenaje se cuelga para siempre.** Ni postgrest ni el cliente
  /// HTTP por defecto aplican timeout, así que un servidor que ACEPTA la
  /// conexión y no contesta nunca —portal cautivo de wifi, handoff de celda, un
  /// balanceador que se traga la petición— dejaba el `await` colgado: el `for`
  /// no avanzaba, el `finally` no corría, y `_sincronizando` quedaba en `true`
  /// de por vida. La app no volvía a sincronizar hasta que alguien la
  /// reiniciara, y sin un solo log.
  ///
  /// El socket cortado, que es el caso que uno imagina primero, es el benigno:
  /// ése al menos lanza.
  ///
  /// Un `TimeoutException` no es un `PostgrestException`, así que cae del lado
  /// "no llegamos": no gasta intento y el bucle sigue con el resto de la cola.
  @visibleForTesting
  static const Duration tiempoLimitePushPorDefecto = Duration(seconds: 30);

  /// Ítems de la cola que corresponde intentar en [ahora] (C-02).
  ///
  /// Se expone para test porque el bucle de [sincronizarPendientes] no arranca
  /// sin una sesión de Supabase viva, y el filtro por `fechaProximoIntento` es
  /// justo lo que hace que el backoff exista: sin él, el ítem que acaba de
  /// fallar vuelve a salir en el drenaje siguiente —que dispara con cada
  /// mutación local— y el backoff es decorativo.
  @visibleForTesting
  Future<List<ColaSincronizacionData>> itemsDrenables(DateTime ahora) =>
      (baseDatos.select(baseDatos.colaSincronizacion)
            ..where(
              (t) =>
                  t.intentos.isSmallerThan(t.maxIntentos) &
                  // NULL = "intentalo ya": todo lo encolado antes de v18 y todo
                  // lo que nunca falló.
                  (t.fechaProximoIntento.isNull() |
                      t.fechaProximoIntento.isSmallerOrEqualValue(ahora)),
            )
            ..orderBy([
              (t) => OrderingTerm(
                expression: t.fechaCreacion,
                mode: OrderingMode.asc,
              ),
            ]))
          .get();

  /// Procesa los registros pendientes en la cola (FIFO) que no superaron su tope de reintentos.
  @override
  Future<void> sincronizarPendientes() async {
    if (_sincronizando || !_puedeSincronizar) return;
    _sincronizando = true;

    try {
      // C-02: el backoff se evalúa contra UN instante fijo y no contra
      // `DateTime.now()` dentro de la query, así el corte es el mismo para todos
      // los ítems del lote y el orden FIFO no depende de cuánto tardó la
      // consulta.
      final ahora = DateTime.now();
      final itemsCola = await itemsDrenables(ahora);

      for (final item in itemsCola) {
        // B03 (defensa en profundidad): el `nombreTabla` de la cola SIEMPRE lo setean
        // los repos con literales, pero se valida contra el esquema real antes de
        // mandarlo a PostgREST. Una fila corrupta/manipulada con una tabla desconocida
        // se descarta —no se envía— en vez de disparar una petición a un identificador
        // arbitrario.
        if (!esNombreTablaValido(item.nombreTabla)) {
          // Tabla desconocida en la cola: nunca es legítima (fila corrupta/manipulada).
          // Se marca DEAD-LETTER (igual que el fallo por reintentos) en vez de borrarla:
          // detiene el reintento pero PRESERVA la evidencia para auditoría. B03.
          debugPrint(
            '[SYNC] Tabla no reconocida en la cola: "${item.nombreTabla}" — dead-letter (B03).',
          );
          await (baseDatos.update(
            baseDatos.colaSincronizacion,
          )..where((t) => t.id.equals(item.id))).write(
            ColaSincronizacionCompanion(
              intentos: Value(item.maxIntentos),
              ultimoError: const Value('Tabla no reconocida (allow-list B03)'),
              fechaActualizacion: Value(DateTime.now()),
            ),
          );
          continue;
        }
        final datos = _aSnakeCase(
          jsonDecode(item.payload) as Map<String, dynamic>,
        );
        bool exito = false;
        // C-02: arranca en false = "no es culpa de la mutación". Sólo un rechazo
        // definitivo del backend la pone en true, y sólo eso gasta un intento.
        bool rechazoDefinitivo = false;
        bool conflicto = false;
        String? error;

        try {
          switch (item.accion) {
            case 'INSERT':
              // upsert: idempotente ante reintentos (RN-015).
              await clienteSupabase
                  .from(item.nombreTabla)
                  .upsert(datos)
                  .timeout(tiempoLimitePush);
              exito = true;
              break;
            case 'UPDATE':
              // HU-028: CONCURRENCIA OPTIMISTA. El UPDATE lleva `version` (la
              // nueva) y se condiciona a que la fila remota siga en la versión
              // que este dispositivo conocía (`versionBase`). `.select()` nos
              // dice cuántas filas afectó:
              //   • 1 fila  → nadie más la tocó: éxito.
              //   • 0 filas → otro dispositivo escribió esa fila (o no existe):
              //     ANTES esto se descartaba como éxito y la mutación se perdía
              //     EN SILENCIO; ahora se marca CONFLICTO y el dato local se
              //     conserva para revisión.
              final base = item.versionBase;
              var consulta = clienteSupabase
                  .from(item.nombreTabla)
                  .update(
                    base == null ? datos : {...datos, 'version': base + 1},
                  )
                  .eq('id', item.registroId);
              if (base != null) consulta = consulta.eq('version', base);
              final afectadas = await consulta.select().timeout(
                tiempoLimitePush,
              );
              if (hayConflictoDeConcurrencia(
                versionBase: base,
                filasAfectadas: (afectadas as List).length,
              )) {
                conflicto = true;
                error =
                    'Conflicto de concurrencia: la fila remota cambió '
                    '(versionBase=$base) o no existe.';
              } else {
                exito = true;
              }
              break;
            case 'DELETE':
              await clienteSupabase
                  .from(item.nombreTabla)
                  .delete()
                  .eq('id', item.registroId)
                  .timeout(tiempoLimitePush);
              exito = true;
              break;
            default:
              // Acción desconocida: fila corrupta/manipulada, o una acción nueva
              // que alguien agregó sin tocar este `switch`. Antes caía sin hacer
              // NADA y sin lanzar, así que el ítem quedaba con `error = null`
              // —indiagnosticable— y, con la regla de C-02, sin gastar intentos:
              // se quedaba en la cola para siempre.
              //
              // Se trata igual que la tabla desconocida (B03): rechazo
              // definitivo, con el error escrito para que se pueda auditar.
              rechazoDefinitivo = true;
              error = 'Acción no reconocida en la cola: "${item.accion}"';
              debugPrint(
                '[SYNC] $error — ${item.nombreTabla}/${item.registroId}',
              );
          }
        } catch (e) {
          error = e.toString();
          // C-02: ¿el backend miró ESTA mutación y dijo que no, o el fallo no
          // habla de la mutación? La regla vive en `PoliticaReintentos`.
          rechazoDefinitivo = PoliticaReintentos.esRechazoDefinitivo(e);
          debugPrint(
            '[SYNC] Error en ${item.nombreTabla}/${item.registroId} (${item.accion}): $e',
          );
        }

        if (conflicto) {
          // No es un fallo transitorio: reintentar con la misma versionBase
          // fallaría siempre. Se saca de la cola de reintentos (dead-letter) y
          // se marca el registro local para que la Fase 3/4 lo resuelva.
          debugPrint(
            '[SYNC] CONFLICTO en ${item.nombreTabla}/${item.registroId}: $error',
          );
          await (baseDatos.update(
            baseDatos.colaSincronizacion,
          )..where((t) => t.id.equals(item.id))).write(
            ColaSincronizacionCompanion(
              intentos: Value(item.maxIntentos),
              ultimoError: Value(error),
              fechaActualizacion: Value(DateTime.now()),
            ),
          );
          await _marcarEstadoSync(
            item.nombreTabla,
            item.registroId,
            'conflicto',
          );
          // HU-028 fase 4: queda en la bitácora para revisión (antes el conflicto
          // no existía como concepto: la mutación se perdía sin rastro).
          await conflictos?.registrar(
            nombreTabla: item.nombreTabla,
            registroId: item.registroId,
            motivo: MotivoConflicto.pushRechazado,
            versionLocal: item.versionBase == null
                ? null
                : item.versionBase! + 1,
            versionRemota: null,
            detalle: error,
          );
          continue;
        }

        if (exito) {
          await (baseDatos.delete(
            baseDatos.colaSincronizacion,
          )..where((t) => t.id.equals(item.id))).go();
          await _marcarSincronizado(item.nombreTabla, item.registroId);
          // HU-028: el registro volvió a sincronizar bien → si tenía conflictos
          // vivos, quedan saldados (criterio 'un conflicto resuelto no reaparece').
          await conflictos?.marcarResueltosDe(
            nombreTabla: item.nombreTabla,
            registroId: item.registroId,
          );
        } else {
          // C-02 — la regla vive en `PoliticaReintentos`, no acá: dentro de este
          // bucle no se puede probar sin una sesión de Supabase viva.
          final decision = PoliticaReintentos.decidir(
            esRechazoDefinitivo: rechazoDefinitivo,
            intentosPrevios: item.intentos,
          );
          final nuevosIntentos =
              item.intentos + (decision.gastaIntento ? 1 : 0);
          await (baseDatos.update(
            baseDatos.colaSincronizacion,
          )..where((t) => t.id.equals(item.id))).write(
            ColaSincronizacionCompanion(
              // Sin `gastaIntento` el contador NO se mueve, a propósito: un
              // fallo de red no dice nada sobre si la mutación es válida.
              intentos: Value(nuevosIntentos),
              ultimoError: Value(error),
              // Desde AHORA y no desde el inicio del lote: un lote lento (50
              // ítems con timeout) puede durar minutos, y los últimos quedarían
              // con una espera ya vencida, o sea sin backoff.
              fechaProximoIntento: Value(DateTime.now().add(decision.espera)),
              fechaActualizacion: Value(DateTime.now()),
            ),
          );
          // Se SIGUE con el resto de la cola, aunque este ítem no haya llegado
          // al servidor.
          //
          // La primera versión cortaba acá ("si no hubo red para éste tampoco
          // la hay para los otros 200"), y esa premisa es falsa: el fallo puede
          // ser del ítem —un payload que hace que el servidor corte la
          // conexión, un timeout puntual— y no de la red. Como además un fallo
          // así no gasta intentos, el ítem nunca llegaba a `maxIntentos`, nunca
          // salía de la cola, y por ser el más viejo volvía a ser el primero en
          // cada drenaje: la cola entera dejaba de subir, para siempre y en
          // silencio. Cambiaba "se pierde una mutación" por "no sube ninguna".
          //
          // El costo de seguir es una ronda de timeouts durante un corte real,
          // y está acotado: cada ítem que falla queda con su `fechaProximoIntento`
          // 30s adelante, así que el drenaje siguiente los saltea a todos.
          if (nuevosIntentos >= item.maxIntentos) {
            // Dead-letter: deja de reintentar; queda registrado el último error para auditoría.
            debugPrint(
              '[SYNC] DEAD-LETTER ${item.nombreTabla}/${item.registroId}: alcanzó ${item.maxIntentos} intentos.',
            );
            // #223: y se SUELTA la fila local. Hasta acá quedaba en
            // 'pendiente' para siempre, y esa marca es lo que hace que el pull
            // conserve lo local y descarte lo remoto (`_pendienteLocalGana`).
            // Con la mutación muerta no hay nada que proteger: el cambio local
            // no va a subir nunca, así que defenderlo sólo logra que ese
            // registro no vuelva a recibir NINGUNA actualización del servidor.
            // Divergencia permanente y muda entre dispositivos.
            //
            // El dato local NO se pisa acá: se pisará en el próximo pull, que
            // es exactamente lo que corresponde cuando el cambio propio se
            // perdió.
            await _marcarEstadoSync(
              item.nombreTabla,
              item.registroId,
              'sincronizado',
            );
          }
        }
      }
    } finally {
      _sincronizando = false;
    }
  }

  /// Descarta TODA la cola pendiente. Se usa al reconciliar el tenant tras un
  /// login (HU-029/HU-072): las mutaciones encoladas se crearon bajo el
  /// `negocio_id` viejo y la RLS las rechazaría (42501), así que no deben enviarse.
  @override
  Future<void> descartarPendientes() async {
    // #223: antes de borrar la cola hay que SOLTAR las filas que esas
    // mutaciones dejaban marcadas. Si no, quedan en 'pendiente' sin nada que
    // subir y el pull no vuelve a tocarlas nunca más.
    final items = await baseDatos.select(baseDatos.colaSincronizacion).get();
    await liberarFilasDeMutaciones(baseDatos, items);
    await baseDatos.delete(baseDatos.colaSincronizacion).go();
  }

  /// Ejecuta [cuerpo] en una transacción de la base LOCAL con el drenaje del Outbox
  /// SUSPENDIDO (HU-079 / C2). Así las inserciones que los repos hacen en la cola
  /// PARTICIPAN de la transacción —un rollback no deja mutaciones huérfanas— y no se
  /// dispara red a mitad de camino. Si commitea, drena UNA vez; si lanza, revierte
  /// todo y no drena.
  Future<T> enTransaccion<T>(Future<T> Function() cuerpo) async {
    _drenajeSuspendido++;
    try {
      final resultado = await baseDatos.transaction(cuerpo);
      // Drena sólo en el nivel MÁS EXTERNO (si esta transacción estuviera anidada
      // dentro de otra, el drenaje se posterga al commit de la externa) y sólo si
      // commiteó (si `transaction` lanzó, no se llega acá y no se drena).
      if (_drenajeSuspendido == 1) unawaited(sincronizarPendientes());
      return resultado;
    } finally {
      _drenajeSuspendido--;
    }
  }

  /// Encola una mutación local para enviarla al backend más tarde.
  /// [datos] debe venir en snake_case (claves de columnas de Supabase).
  /// Deduplica mutaciones equivalentes pendientes (misma tabla+registro+acción).
  Future<void> encolarMutacion({
    required String nombreTabla,
    required String registroId,
    required String accion,
    required Map<String, dynamic> datos,

    /// HU-028: `version` de la fila tal como la conocía el cliente ANTES de
    /// mutarla. Es el token de concurrencia optimista del push.
    int? versionBase,
  }) async {
    if (!ConfigPersistencia.sincronizacionActiva) return;

    // Deduplicación: reemplaza cualquier mutación pendiente equivalente por la última.
    // HU-028: se CONSERVA la versionBase de la mutación más vieja — es la base
    // real contra la que se calculó la cadena de cambios locales; usar la última
    // haría que el push compare contra una versión que el servidor nunca vio.
    final pendientes =
        await (baseDatos.select(baseDatos.colaSincronizacion)
              ..where(
                (t) =>
                    t.nombreTabla.equals(nombreTabla) &
                    t.registroId.equals(registroId) &
                    t.accion.equals(accion),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.fechaCreacion)]))
            .get();
    final baseConservada = pendientes.isEmpty
        ? versionBase
        : (pendientes.first.versionBase ?? versionBase);

    // El dedup es delete + insert, así que la fila nueva nace con `intentos = 0`
    // y `fechaProximoIntento` en NULL: reeditar el mismo registro RESETEA el
    // backoff y el contador de dead-letter. Es deliberado —el usuario acaba de
    // decir algo nuevo sobre esa fila, y el payload viejo ya no se va a subir—
    // pero conviene saberlo: un flujo que reescriba el mismo registro en bucle
    // nunca deja que el tope de intentos actúe.
    await (baseDatos.delete(baseDatos.colaSincronizacion)..where(
          (t) =>
              t.nombreTabla.equals(nombreTabla) &
              t.registroId.equals(registroId) &
              t.accion.equals(accion),
        ))
        .go();

    await baseDatos
        .into(baseDatos.colaSincronizacion)
        .insert(
          ColaSincronizacionCompanion.insert(
            id: const Uuid().v4(),
            nombreTabla: nombreTabla,
            registroId: registroId,
            accion: accion,
            payload: jsonEncode(datos),
            versionBase: Value(baseConservada),
            fechaCreacion: Value(DateTime.now()),
            fechaActualizacion: Value(DateTime.now()),
          ),
        );

    // Drena de inmediato si hay conexión, salvo que estemos dentro de una transacción
    // local (HU-079): ahí el drenaje se posterga al post-commit (ver [enTransaccion]).
    if (_drenajeSuspendido == 0) sincronizarPendientes();
  }

  /// Decisión PURA del desenlace de un UPDATE pusheado (HU-028), separada del
  /// I/O para poder testearla sin backend.
  ///
  /// Hay conflicto cuando el UPDATE llevaba guarda de concurrencia
  /// ([versionBase] no nulo) y **no afectó ninguna fila**: la versión remota ya
  /// no es la que este dispositivo conocía —otro la escribió— o la fila no
  /// existe. Sin guarda (INSERT/DELETE o tablas append-only sin `version`) no se
  /// puede afirmar un conflicto: se conserva el comportamiento previo.
  static bool hayConflictoDeConcurrencia({
    required int? versionBase,
    required int filasAfectadas,
  }) => versionBase != null && filasAfectadas == 0;

  /// Marca el registro local como sincronizado (best-effort).
  Future<void> _marcarSincronizado(String tabla, String registroId) =>
      _marcarEstadoSync(tabla, registroId, 'sincronizado');

  /// Escribe el `estado_sync` del registro local (best-effort). HU-028: además
  /// de 'sincronizado' ahora se usa 'conflicto', que hasta hoy estaba declarado
  /// en el esquema pero no lo escribía nadie.
  Future<void> _marcarEstadoSync(
    String tabla,
    String registroId,
    String estado,
  ) async {
    try {
      await customStatementSeguro(
        'UPDATE $tabla SET estado_sync = ? WHERE id = ?',
        [estado, registroId],
      );
    } catch (_) {
      /* la tabla puede no tener estado_sync: se ignora */
    }
  }

  Future<void> customStatementSeguro(String sql, List<Object?> args) async {
    await baseDatos.customStatement(sql, args);
  }

  /// Convierte claves camelCase a snake_case por seguridad (los payloads ya deberían venir en snake_case).
  Map<String, dynamic> _aSnakeCase(Map<String, dynamic> origen) {
    final salida = <String, dynamic>{};
    origen.forEach((clave, valor) {
      salida[_snake(clave)] = valor;
    });
    return salida;
  }

  String _snake(String entrada) {
    if (!entrada.contains(RegExp(r'[A-Z]'))) return entrada; // ya es snake_case
    return entrada.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (m) => '_${m[0]!.toLowerCase()}',
    );
  }
}
