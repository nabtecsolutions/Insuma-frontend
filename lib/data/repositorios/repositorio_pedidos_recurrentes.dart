import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/database.dart';
import '../../utils/agenda_recurrente.dart';
import '../../utils/fecha_recepcion.dart';
import '../mapeadores_supabase.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de pedidos recurrentes (HU-013): la REGLA de una
/// entrega que se repite, por proveedor.
///
/// Es la ÚNICA capa que toca la persistencia de las agendas: escribe en el store
/// local (Drift, offline-first) y encola la mutación hacia Supabase por el
/// Outbox. Toda la lógica de calendario —cuándo toca la próxima entrega, si la
/// serie está bloqueada— vive en el Service y en los módulos puros
/// `agenda_recurrente.dart` / `ancla_agenda.dart`. Acá NO hay una sola fecha
/// calculada.
abstract class RepositorioPedidosRecurrentes {
  /// Agendas de un proveedor. Por defecto sólo las vivas.
  Future<List<PedidosRecurrente>> deProveedor(
    String proveedorId, {
    bool incluirInactivas = false,
  });

  /// Todas las agendas vivas del negocio. Es la consulta que usa el generador
  /// al abrir la app: una sola lectura para todas, nunca una por proveedor.
  Future<List<PedidosRecurrente>> delNegocio(
    String negocioId, {
    bool incluirInactivas = false,
  });

  /// Observa las agendas vivas de un proveedor (reactividad, patrón HU-089).
  Stream<List<PedidosRecurrente>> observarDeProveedor(String proveedorId);

  Future<PedidosRecurrente?> porId(String id);

  /// Da de alta una agenda. [items] va en la forma canónica de `pedidos.items`
  /// (`cantidadPedida` / `precioUnitario`), porque se copia tal cual a cada
  /// entrega que se materializa.
  Future<PedidosRecurrente> crear({
    required String id,
    required String negocioId,
    required String proveedorId,
    required ConfigRecurrencia config,
    required List<Map<String, dynamic>> items,
    bool tieneEfectivo = false,
    String? nota,
  });

  /// Reemplaza la configuración y/o los ítems de una agenda existente.
  ///
  /// Los parámetros nulos NO se tocan, salvo [nota], que se escribe siempre
  /// (vaciarla es una edición legítima).
  Future<PedidosRecurrente> actualizar({
    required String id,
    ConfigRecurrencia? config,
    List<Map<String, dynamic>>? items,
    bool? tieneEfectivo,
    String? nota,
  });

  /// Deja registrado hasta qué fecha ya emitió la serie. Es la MEMORIA que evita
  /// que la grilla vuelva a ofrecer una entrega ya materializada.
  Future<PedidosRecurrente> marcarOcurrenciaEmitida(String id, DateTime fecha);

  /// Baja LÓGICA (nunca DELETE físico: por eso en Supabase no hay policy
  /// `FOR DELETE`). Un borrado real dejaría sin procedencia a los pedidos ya
  /// recibidos que nacieron de esta agenda.
  Future<PedidosRecurrente> darDeBaja(String id);
}

/// Implementación local (Drift) con encolado hacia Supabase.
class RepositorioPedidosRecurrentesDrift extends RepositorioSincronizable
    implements RepositorioPedidosRecurrentes {
  RepositorioPedidosRecurrentesDrift(super.db, super.sync);

  static const String _tabla = 'pedidos_recurrentes';

  @override
  Future<List<PedidosRecurrente>> deProveedor(
    String proveedorId, {
    bool incluirInactivas = false,
  }) {
    final q = db.select(db.pedidosRecurrentes)
      ..where(
        (a) => incluirInactivas
            ? a.proveedorId.equals(proveedorId)
            : a.proveedorId.equals(proveedorId) & a.activo.equals(true),
      );
    return q.get();
  }

  @override
  Future<List<PedidosRecurrente>> delNegocio(
    String negocioId, {
    bool incluirInactivas = false,
  }) {
    final q = db.select(db.pedidosRecurrentes)
      ..where(
        (a) => incluirInactivas
            ? a.negocioId.equals(negocioId)
            : a.negocioId.equals(negocioId) & a.activo.equals(true),
      );
    return q.get();
  }

  @override
  Stream<List<PedidosRecurrente>> observarDeProveedor(String proveedorId) {
    final q = db.select(db.pedidosRecurrentes)
      ..where((a) => a.proveedorId.equals(proveedorId) & a.activo.equals(true));
    return q.watch();
  }

  @override
  Future<PedidosRecurrente?> porId(String id) => _porIdOrNull(id);

  @override
  Future<PedidosRecurrente> crear({
    required String id,
    required String negocioId,
    required String proveedorId,
    required ConfigRecurrencia config,
    required List<Map<String, dynamic>> items,
    bool tieneEfectivo = false,
    String? nota,
  }) async {
    final ahora = DateTime.now();
    await db
        .into(db.pedidosRecurrentes)
        .insert(
          PedidosRecurrentesCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorId: proveedorId,
            tipo: AgendaRecurrente.codigoDeTipo(config.tipo),
            diasSemana: Value(_bitmaskDe(config)),
            diaMes: Value(
              config.tipo == TipoFrecuencia.mensual ? config.diaMes : null,
            ),
            cadaNDias: Value(
              config.tipo == TipoFrecuencia.cadaNDias ? config.cadaNDias : null,
            ),
            ancla: Value(_anclaDe(config)),
            fechaInicio: FechaRecepcion.soloDia(config.fechaInicio),
            items: Value(jsonEncode(items)),
            tieneEfectivo: Value(tieneEfectivo),
            nota: Value(nota),
            fechaCreacion: Value(ahora),
            fechaActualizacion: Value(ahora),
          ),
        );
    final creada = await _porId(id);
    await encolarInsert(
      _tabla,
      id,
      MapeadoresSupabase.pedidoRecurrente(creada),
    );
    return creada;
  }

  @override
  Future<PedidosRecurrente> actualizar({
    required String id,
    ConfigRecurrencia? config,
    List<Map<String, dynamic>>? items,
    bool? tieneEfectivo,
    String? nota,
  }) async {
    final actual = await _porId(id);
    // Al cambiar la configuración se reescriben las CUATRO columnas de
    // modalidad, no sólo la de la frecuencia nueva: pasar de semanal a mensual
    // sin limpiar `dias_semana` dejaría la fila incoherente y el CHECK de
    // Postgres rechazaría el push, que muere en la cola sin que nadie se entere.
    final cambios = config == null
        ? PedidosRecurrentesCompanion(
            items: items == null
                ? const Value.absent()
                : Value(jsonEncode(items)),
            tieneEfectivo: tieneEfectivo == null
                ? const Value.absent()
                : Value(tieneEfectivo),
            nota: Value(nota),
          )
        : PedidosRecurrentesCompanion(
            tipo: Value(AgendaRecurrente.codigoDeTipo(config.tipo)),
            diasSemana: Value(_bitmaskDe(config)),
            diaMes: Value(
              config.tipo == TipoFrecuencia.mensual ? config.diaMes : null,
            ),
            cadaNDias: Value(
              config.tipo == TipoFrecuencia.cadaNDias ? config.cadaNDias : null,
            ),
            ancla: Value(_anclaDe(config)),
            fechaInicio: Value(FechaRecepcion.soloDia(config.fechaInicio)),
            items: items == null
                ? const Value.absent()
                : Value(jsonEncode(items)),
            tieneEfectivo: tieneEfectivo == null
                ? const Value.absent()
                : Value(tieneEfectivo),
            nota: Value(nota),
          );
    return _escribir(actual, cambios);
  }

  @override
  Future<PedidosRecurrente> marcarOcurrenciaEmitida(
    String id,
    DateTime fecha,
  ) async => _escribir(
    await _porId(id),
    PedidosRecurrentesCompanion(
      fechaUltimaOcurrenciaEmitida: Value(FechaRecepcion.soloDia(fecha)),
    ),
  );

  @override
  Future<PedidosRecurrente> darDeBaja(String id) async => _escribir(
    await _porId(id),
    const PedidosRecurrentesCompanion(activo: Value(false)),
  );

  /// Aplica [cambios] avanzando la versión y encolando el UPDATE.
  ///
  /// HU-028: `versionBase` es la versión que la fila tenía ANTES de
  /// incrementarla — el token con el que el push detecta que alguien más la tocó.
  Future<PedidosRecurrente> _escribir(
    PedidosRecurrente actual,
    PedidosRecurrentesCompanion cambios,
  ) async {
    await (db.update(
      db.pedidosRecurrentes,
    )..where((a) => a.id.equals(actual.id))).write(
      cambios.copyWith(
        version: Value(actual.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    final actualizada = await _porId(actual.id);
    await encolarUpdate(
      _tabla,
      actual.id,
      MapeadoresSupabase.pedidoRecurrente(actualizada),
      versionBase: actual.version,
    );
    return actualizada;
  }

  /// El bitmask sólo tiene sentido en 'semanal'; en el resto va NULL para no
  /// violar el CHECK de coherencia de Postgres.
  static int? _bitmaskDe(ConfigRecurrencia c) =>
      c.tipo == TipoFrecuencia.semanal
      ? AgendaRecurrente.aBitmask(c.diasSemana)
      : null;

  /// Ídem el ancla: sólo 'cada N días' la usa.
  static String? _anclaDe(ConfigRecurrencia c) =>
      c.tipo == TipoFrecuencia.cadaNDias
      ? AgendaRecurrente.codigoDeAncla(c.ancla)
      : null;

  Future<PedidosRecurrente> _porId(String id) => (db.select(
    db.pedidosRecurrentes,
  )..where((a) => a.id.equals(id))).getSingle();

  Future<PedidosRecurrente?> _porIdOrNull(String id) => (db.select(
    db.pedidosRecurrentes,
  )..where((a) => a.id.equals(id))).getSingleOrNull();
}
