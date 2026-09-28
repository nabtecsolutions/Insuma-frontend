import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../utils/id_determinista.dart';
import '../database.dart';

/// Paso v13 → v14 (HU-138): backfill de la tabla puente [InsumoProveedores].
///
/// Vive aparte de `BaseDatosApp` por responsabilidad única y para poder testearlo
/// solo, con una base en memoria.
///
/// Qué hace y qué NO hace:
///  • SÍ crea un vínculo insumo↔proveedor por cada insumo que hoy tiene
///    `proveedor_id`, con `precio = NULL`.
///  • NO copia `costoPorUnidad` al precio del vínculo: ese caché es el último
///    precio de INGRESO (lo que alimenta el FoodCost), no un precio de lista
///    pactado con ese proveedor. Copiarlo inventaría un acuerdo que nadie hizo.
///  • NO renombra insumos duplicados: el nombre único se hace cumplir SOLO en
///    Supabase, así que el saneo lo hace el servidor una vez y baja por el pull.
///    Si el cliente renombrara por su cuenta, cada dispositivo podría elegir un
///    superviviente distinto y la divergencia sería permanente.
///  • NO toca `historial_precios` ni `costoPorUnidad`.
class MigradorInsumosV14 {
  const MigradorInsumosV14._();

  /// Crea un vínculo por cada insumo que tenga proveedor asignado.
  ///
  /// Es IDEMPOTENTE: el id del vínculo se deriva del par (ver [IdDeterminista]),
  /// así que correrlo dos veces —o que además lo cree el servidor— converge a la
  /// misma fila en vez de duplicarla.
  static Future<void> backfillVinculos(BaseDatosApp db) async {
    // JOIN contra proveedores: si `proveedor_id` apunta a un proveedor que ya no
    // existe, no se crea el vínculo. Durante onUpgrade SQLite todavía no tiene
    // activado el chequeo de claves foráneas (se enciende en beforeOpen), así que
    // una fila colgada no fallaría acá: entraría y rompería después.
    final filas = await db
        .customSelect(
          'SELECT i.id AS insumo_id, i.negocio_id AS negocio_id, i.proveedor_id AS proveedor_id '
          'FROM insumos i JOIN proveedores p ON p.id = i.proveedor_id '
          'WHERE i.proveedor_id IS NOT NULL',
        )
        .get();
    if (filas.isEmpty) return;

    final pendientesEnCola = await _insumosConMutacionPendiente(db);
    final ahora = DateTime.now();

    for (final fila in filas) {
      final insumoId = fila.read<String>('insumo_id');
      final negocioId = fila.read<String>('negocio_id');
      final proveedorId = fila.read<String>('proveedor_id');
      final vinculoId = IdDeterminista.parInsumoProveedor(
        insumoId,
        proveedorId,
      );

      // El servidor hace su propio backfill recorriendo SUS insumos. Un insumo
      // creado offline y todavía sin pushear NO existe allá, así que su vínculo
      // no lo va a generar nadie: hay que encolarlo desde acá. Para el resto, el
      // vínculo ya nace del lado del servidor con el MISMO id determinista, así
      // que encolarlo sería ruido.
      final loConoceElServidor = !pendientesEnCola.contains(insumoId);

      await db
          .into(db.insumoProveedores)
          .insertOnConflictUpdate(
            InsumoProveedoresCompanion.insert(
              id: vinculoId,
              negocioId: negocioId,
              insumoId: insumoId,
              proveedorId: proveedorId,
              activo: const Value(true),
              fechaCreacion: Value(ahora),
              fechaActualizacion: Value(ahora),
              estadoSync: Value(
                loConoceElServidor ? 'sincronizado' : 'pendiente',
              ),
            ),
          );

      if (!loConoceElServidor) {
        await _encolarAlta(
          db,
          vinculoId,
          negocioId,
          insumoId,
          proveedorId,
          ahora,
        );
      }
    }
  }

  /// Insumos que tienen alguna mutación viva en la cola: son los que el servidor
  /// todavía no conoce (o no conoce en su forma actual).
  ///
  /// No se filtran los que ya agotaron sus reintentos: si esa mutación se
  /// recupera a mano, el vínculo tiene que viajar con ella. Encolar de más es
  /// inocuo —el alta es idempotente por el id determinista—; encolar de menos
  /// pierde el vínculo para siempre.
  static Future<Set<String>> _insumosConMutacionPendiente(
    BaseDatosApp db,
  ) async {
    final filas = await db
        .customSelect(
          "SELECT DISTINCT registro_id FROM cola_sincronizacion WHERE nombre_tabla = 'insumos'",
        )
        .get();
    return filas.map((f) => f.read<String>('registro_id')).toSet();
  }

  /// Encola el alta del vínculo directamente en la tabla de la cola.
  ///
  /// No se usa `ServicioSincronizacionSupabase.encolarMutacion` a propósito: la
  /// migración corre durante la apertura de la base, cuando los servicios todavía
  /// no existen, y ese método además consulta la configuración de sincronización.
  /// El payload replica el del mapeador de la tabla puente.
  static Future<void> _encolarAlta(
    BaseDatosApp db,
    String vinculoId,
    String negocioId,
    String insumoId,
    String proveedorId,
    DateTime ahora,
  ) async {
    await db
        .into(db.colaSincronizacion)
        .insert(
          ColaSincronizacionCompanion.insert(
            id: const Uuid().v4(),
            nombreTabla: 'insumo_proveedores',
            registroId: vinculoId,
            accion: 'INSERT',
            payload: jsonEncode({
              'id': vinculoId,
              'negocio_id': negocioId,
              'insumo_id': insumoId,
              'proveedor_id': proveedorId,
              'precio': null,
              'activo': true,
              'version': 0,
            }),
            fechaCreacion: Value(ahora),
          ),
        );
  }
}
