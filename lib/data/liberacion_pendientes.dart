/// Devolver a `sincronizado` las filas que quedaron marcadas para subir cuando
/// su mutación ya no existe (#223).
///
/// ── El agujero que cierra ───────────────────────────────────────────────────
/// Una fila con `estado_sync = 'pendiente'` está protegida: el pull conserva lo
/// local y descarta lo remoto (`PoliticaConflictos._pendienteLocalGana`). Es
/// correcto MIENTRAS haya un cambio en vuelo esperando subir.
///
/// Pero ese cambio puede dejar de existir sin que nada devuelva la fila a
/// `sincronizado`: la mutación agota sus 8 intentos y cae en dead-letter, o la
/// cola entera se descarta al reconciliar el tenant (HU-132). La marca
/// sobrevive igual, y desde ese momento ese insumo —o receta, o pedido— NO
/// vuelve a recibir NUNCA MÁS una actualización del servidor en ese
/// dispositivo. Cada pull la rechaza y deja un `pull_rechazado` que ninguna
/// pantalla lee todavía. Divergencia permanente y silenciosa entre dispositivos
/// del mismo negocio.
///
/// ── Por qué vive acá y no en el sincronizador ───────────────────────────────
/// Los DOS descartadores de cola tienen que hacer lo mismo, y uno de ellos
/// (`DescartadorColaDrift`) existe justamente para funcionar sin el
/// sincronizador. Un módulo con la base como única dependencia es lo que los
/// dos pueden compartir sin que ninguno dependa del otro.
library;

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';

/// Las tablas que tienen `estado_sync`, por su nombre REAL en SQL.
///
/// Se derivan del esquema en vez de escribirse a mano: una tabla nueva con
/// `estado_sync` entra sola, sin que nadie se acuerde de sumarla acá — que es
/// exactamente el olvido que produce este bug.
Set<String> tablasConEstadoSync(BaseDatosApp db) => {
  for (final t in db.allTables)
    if (t.$columns.any((c) => c.name == 'estado_sync')) t.actualTableName,
};

/// Devuelve a `sincronizado` las filas apuntadas por [items].
///
/// Se usa cuando esas mutaciones se van a descartar: sin esto, sus filas quedan
/// marcadas de por vida. Best-effort por tabla: una tabla que no exista o que
/// no tenga la columna no puede hacer fracasar la limpieza de las demás.
///
/// Devuelve cuántas filas se liberaron, para poder afirmarlo en un test y para
/// que el log diga algo verificable.
Future<int> liberarFilasDeMutaciones(
  BaseDatosApp db,
  List<ColaSincronizacionData> items,
) async {
  if (items.isEmpty) return 0;
  final validas = tablasConEstadoSync(db);

  // Se agrupa por tabla para hacer UN update por tabla y no uno por fila: la
  // cola descartada puede tener cientos de ítems.
  final porTabla = <String, Set<String>>{};
  for (final i in items) {
    if (!validas.contains(i.nombreTabla)) continue;
    porTabla.putIfAbsent(i.nombreTabla, () => <String>{}).add(i.registroId);
  }

  var liberadas = 0;
  for (final entrada in porTabla.entries) {
    final marcas = List.filled(entrada.value.length, '?').join(',');
    try {
      await db.customUpdate(
        "UPDATE ${entrada.key} SET estado_sync = 'sincronizado' "
        "WHERE id IN ($marcas) AND estado_sync = 'pendiente'",
        variables: [for (final id in entrada.value) Variable<String>(id)],
        updates: {},
      );
      liberadas += entrada.value.length;
    } catch (e) {
      debugPrint('[SYNC] No se pudo liberar ${entrada.key}: $e');
    }
  }
  return liberadas;
}

/// Auto-reparador: libera las filas `pendiente` que NO tienen ninguna mutación
/// encolada (#223).
///
/// Es lo único que cura a un dispositivo que YA quedó roto: los arreglos de los
/// dos disparadores evitan que vuelva a pasar, pero no destraban lo que quedó
/// trabado antes de instalar esta versión. Sin esto, la única salida para esos
/// registros es reinstalar la app.
///
/// ── La ventana de carrera, asumida a conciencia ─────────────────────────────
/// Varios llamadores escriben la fila (marcándola `pendiente`) y encolan la
/// mutación DESPUÉS, en dos `await` separados y fuera de una transacción — por
/// ejemplo `ControladorInsumos.eliminarInsumo`. Entre esos dos pasos existe un
/// instante donde una fila está `pendiente` sin cola LEGÍTIMAMENTE, y este
/// reparador la liberaría.
///
/// El daño posible está acotado y NO incluye perder el dato: la mutación se
/// encola igual un instante después y el push la sube; lo que puede pasar es
/// que un pull intermedio muestre el valor viejo por un momento. Se prefiere
/// eso —visible y transitorio— a la divergencia permanente y muda que produce
/// no reparar. Decisión del PO, 2026-08-29.
///
/// Corre ANTES del pull, no durante: así no compite con los upserts que el pull
/// mismo está aplicando.
Future<int> repararPendientesHuerfanas(BaseDatosApp db) async {
  final encoladas = await db.select(db.colaSincronizacion).get();

  // Índice de lo que SÍ tiene mutación viva, por tabla.
  final vivas = <String, Set<String>>{};
  for (final i in encoladas) {
    vivas.putIfAbsent(i.nombreTabla, () => <String>{}).add(i.registroId);
  }

  var reparadas = 0;
  for (final tabla in tablasConEstadoSync(db)) {
    try {
      final pendientes = await db
          .customSelect(
            "SELECT id FROM $tabla WHERE estado_sync = 'pendiente'",
            readsFrom: {},
          )
          .get();
      if (pendientes.isEmpty) continue;

      final huerfanas = [
        for (final fila in pendientes)
          if (!(vivas[tabla]?.contains(fila.read<String>('id')) ?? false))
            fila.read<String>('id'),
      ];
      if (huerfanas.isEmpty) continue;

      final marcas = List.filled(huerfanas.length, '?').join(',');
      await db.customUpdate(
        "UPDATE $tabla SET estado_sync = 'sincronizado' WHERE id IN ($marcas)",
        variables: [for (final id in huerfanas) Variable<String>(id)],
        updates: {},
      );
      reparadas += huerfanas.length;
      debugPrint(
        '[SYNC] #223: $tabla — ${huerfanas.length} fila(s) liberada(s): '
        'estaban marcadas para subir sin nada encolado.',
      );
    } catch (e) {
      debugPrint('[SYNC] No se pudo reparar $tabla: $e');
    }
  }
  return reparadas;
}
