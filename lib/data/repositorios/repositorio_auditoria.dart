import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Auditoría inmutable (HU-030 / RNF-006).
abstract class RepositorioAuditoria {
  Future<void> registrar({
    required String negocioId,
    String? usuarioId,
    required String tablaAfectada,
    required String registroId,
    required String accion, // INSERT, UPDATE, DELETE
    Map<String, dynamic>? datosAntes,
    Map<String, dynamic>? datosDespues,
    String origen,
  });
  Future<List<RegistroAuditoria>> listar(String negocioId, {int limite});
}

class RepositorioAuditoriaDrift extends RepositorioSincronizable
    implements RepositorioAuditoria {
  RepositorioAuditoriaDrift(super.db, super.sync);

  static const String _tabla = 'registros_auditoria';

  @override
  Future<void> registrar({
    required String negocioId,
    String? usuarioId,
    required String tablaAfectada,
    required String registroId,
    required String accion,
    Map<String, dynamic>? datosAntes,
    Map<String, dynamic>? datosDespues,
    String origen = 'app_offline',
  }) async {
    final id = const Uuid().v4();
    // #273: el instante del HECHO, capturado acá y no deducido después. Se usa
    // el MISMO valor para la fila local y para el payload: si cada uno leyera
    // el reloj por su lado, diferirían en milisegundos y el registro local no
    // sería el mismo que el remoto.
    final ocurrio = DateTime.now();
    final antesJson = datosAntes == null ? null : jsonEncode(datosAntes);
    final despuesJson = datosDespues == null ? null : jsonEncode(datosDespues);
    await db
        .into(db.registrosAuditoria)
        .insert(
          RegistrosAuditoriaCompanion.insert(
            id: id,
            negocioId: negocioId,
            usuarioId: Value(usuarioId),
            tablaAfectada: tablaAfectada,
            registroId: registroId,
            accion: accion,
            datosAntes: Value(antesJson),
            datosDespues: Value(despuesJson),
            origen: Value(origen),
            ocurridoEn: Value(ocurrio),
          ),
        );
    await encolarInsert(_tabla, id, {
      'id': id,
      'negocio_id': negocioId,
      'usuario_id': usuarioId,
      'tabla_afectada': tablaAfectada,
      'registro_id': registroId,
      'accion': accion,
      'datos_antes': datosAntes,
      'datos_despues': datosDespues,
      'origen': origen,
      // #273 — LA FECHA DEL HECHO, que no es la del flush.
      //
      // Sin esto, la tabla remota estampaba `created_at DEFAULT now()` en el
      // momento en que el Outbox drenaba: como la app es offline-first, un
      // hecho del lunes subido el jueves quedaba fechado el jueves. Una
      // auditoría con la fecha del flush no sirve para auditar.
      //
      // Va en una columna APARTE y no en `created_at`, que es el cursor del
      // pull incremental (#250): escribirle la fecha del hecho dejaría a un
      // registro viejo por debajo del cursor y el pull no lo vería nunca.
      'ocurrido_en': ocurrio.toUtc().toIso8601String(),
    });
  }

  @override
  Future<List<RegistroAuditoria>> listar(String negocioId, {int limite = 200}) {
    return (db.select(db.registrosAuditoria)
          ..where((a) => a.negocioId.equals(negocioId))
          ..orderBy([
            (a) => OrderingTerm(
              expression: a.fechaCreacion,
              mode: OrderingMode.desc,
            ),
          ])
          ..limit(limite))
        .get();
  }
}
