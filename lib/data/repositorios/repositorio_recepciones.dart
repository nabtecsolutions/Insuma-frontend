import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Recepciones (APPEND-ONLY, RN-013 / HU-014 / HU-015).
abstract class RepositorioRecepciones {
  Future<List<Recepcion>> listarPorPedido(String pedidoId);

  /// Todas las recepciones de un negocio (más recientes primero). Base de la vista
  /// admin de recepciones/pagos (HU-067); el aislamiento por negocio es directo por
  /// la columna `negocioId` de cada recepción.
  Future<List<Recepcion>> listarPorNegocio(String negocioId);
  Future<int> proximoNumero(String pedidoId);
  Future<Recepcion> registrarEvento({
    required String negocioId,
    required String pedidoId,
    required List<Map<String, dynamic>> items,
    String? recepcionadoPor,
    String? recepcionadoPorNombre,
    String? nota,
    double? totalRecibido,
    String? totalEditadoPor,
    String? totalEditadoPorNombre,
  });

  /// HU-143: escribe (o borra, con [nuevoTotal] null) el total manual de una
  /// recepción ya registrada. ÚNICA mutación permitida post-alta: los items y
  /// la evidencia siguen siendo inmutables. Patrón mutable de HU-028:
  /// version+1 + fechaActualizacion + UPDATE encolado con versionBase.
  /// Devuelve la recepción actualizada.
  Future<Recepcion> actualizarTotalRecibido({
    required Recepcion recepcion,
    double? nuevoTotal,
    String? usuarioId,
    String? usuarioNombre,
  });
}

class RepositorioRecepcionesDrift extends RepositorioSincronizable
    implements RepositorioRecepciones {
  RepositorioRecepcionesDrift(super.db, super.sync);

  static const String _tabla = 'recepciones';

  @override
  Future<List<Recepcion>> listarPorPedido(String pedidoId) {
    return (db.select(db.recepciones)
          ..where((r) => r.pedidoId.equals(pedidoId))
          ..orderBy([(r) => OrderingTerm(expression: r.numeroRecepcion)]))
        .get();
  }

  @override
  Future<List<Recepcion>> listarPorNegocio(String negocioId) {
    return (db.select(db.recepciones)
          ..where((r) => r.negocioId.equals(negocioId))
          ..orderBy([
            (r) => OrderingTerm(
              expression: r.fechaRecepcion,
              mode: OrderingMode.desc,
            ),
          ]))
        .get();
  }

  @override
  Future<int> proximoNumero(String pedidoId) async {
    final existentes = await listarPorPedido(pedidoId);
    if (existentes.isEmpty) return 1;
    return existentes
            .map((r) => r.numeroRecepcion)
            .reduce((a, b) => a > b ? a : b) +
        1;
  }

  @override
  Future<Recepcion> registrarEvento({
    required String negocioId,
    required String pedidoId,
    required List<Map<String, dynamic>> items,
    String? recepcionadoPor,
    String? recepcionadoPorNombre,
    String? nota,
    double? totalRecibido,
    String? totalEditadoPor,
    String? totalEditadoPorNombre,
  }) async {
    final id = const Uuid().v4();
    final numero = await proximoNumero(pedidoId);
    final itemsJson = jsonEncode(items);
    final ahora = DateTime.now();
    // HU-143: la autoría del total sólo tiene sentido si hay total manual.
    final hayTotalManual = totalRecibido != null;

    await db
        .into(db.recepciones)
        .insert(
          RecepcionesCompanion.insert(
            id: id,
            negocioId: negocioId,
            pedidoId: pedidoId,
            numeroRecepcion: Value(numero),
            recepcionadoPor: Value(recepcionadoPor),
            recepcionadoPorNombre: Value(recepcionadoPorNombre),
            items: itemsJson,
            nota: Value(nota),
            totalRecibido: Value(totalRecibido),
            totalEditadoPor: Value(hayTotalManual ? totalEditadoPor : null),
            totalEditadoPorNombre: Value(
              hayTotalManual ? totalEditadoPorNombre : null,
            ),
            fechaTotalEditado: Value(hayTotalManual ? ahora : null),
            fechaRecepcion: Value(ahora),
            fechaCreacion: Value(ahora),
            fechaActualizacion: Value(ahora),
          ),
        );

    final creada = await (db.select(
      db.recepciones,
    )..where((r) => r.id.equals(id))).getSingle();

    await encolarInsert(_tabla, id, {
      'id': id,
      'negocio_id': negocioId,
      'pedido_id': pedidoId,
      'numero_recepcion': numero,
      'recepcionado_por': recepcionadoPor,
      'recepcionado_por_nombre': recepcionadoPorNombre,
      'items': items, // JSONB en Supabase
      'nota': nota,
      'total_recibido': totalRecibido,
      'total_editado_por': hayTotalManual ? totalEditadoPor : null,
      'total_editado_por_nombre': hayTotalManual ? totalEditadoPorNombre : null,
      'fecha_total_editado': hayTotalManual ? iso(ahora) : null,
      'fecha_recepcion': iso(ahora),
    });

    return creada;
  }

  @override
  Future<Recepcion> actualizarTotalRecibido({
    required Recepcion recepcion,
    double? nuevoTotal,
    String? usuarioId,
    String? usuarioNombre,
  }) async {
    // Se relee la fila viva: el snapshot de la UI puede ser viejo y la
    // versionBase del push debe ser la REAL (HU-028).
    final previa = await (db.select(
      db.recepciones,
    )..where((r) => r.id.equals(recepcion.id))).getSingle();
    final ahora = DateTime.now();
    final borra = nuevoTotal == null; // null ⇒ vuelve a valer el derivado

    await (db.update(
      db.recepciones,
    )..where((r) => r.id.equals(previa.id))).write(
      RecepcionesCompanion(
        totalRecibido: Value(nuevoTotal),
        totalEditadoPor: Value(borra ? null : usuarioId),
        totalEditadoPorNombre: Value(borra ? null : usuarioNombre),
        fechaTotalEditado: Value(borra ? null : ahora),
        version: Value(siguienteVersion(previa.version)),
        fechaActualizacion: Value(ahora),
        estadoSync: const Value('pendiente'),
      ),
    );

    final actualizada = await (db.select(
      db.recepciones,
    )..where((r) => r.id.equals(previa.id))).getSingle();

    // Payload MÍNIMO: sólo el total y su autoría. El push agrega `version` y
    // condiciona a versionBase (concurrencia optimista, HU-028).
    await encolarUpdate(_tabla, previa.id, {
      'id': previa.id,
      'total_recibido': nuevoTotal,
      'total_editado_por': borra ? null : usuarioId,
      'total_editado_por_nombre': borra ? null : usuarioNombre,
      'fecha_total_editado': borra ? null : iso(ahora),
    }, versionBase: previa.version);

    return actualizada;
  }
}
