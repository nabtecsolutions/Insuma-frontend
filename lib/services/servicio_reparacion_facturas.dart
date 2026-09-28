import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../data/repositorios/repositorio_facturas.dart';
import '../data/repositorios/repositorio_cuenta_corriente.dart';
import 'servicio_sincronizacion_supabase.dart';
import '../data/transaccionador.dart';

/// Reparación única de facturas huérfanas (HU-070).
///
/// Antes del fix de HU-070, facturar una recepción cuyo pedido no tenía `proveedorId`
/// válido creaba una factura sin proveedor: no aparecía en la cuenta corriente y NO se
/// registraba su débito. Este servicio, corriendo una sola vez sobre la base local,
/// re-vincula esas facturas (por el pedido / por nombre) y crea el movimiento de cuenta
/// corriente que faltó. Usa repos sync-aware, así el arreglo también viaja al remoto
/// por el Outbox. Es idempotente (no duplica movimientos).
class ServicioReparacionFacturas {
  final BaseDatosApp _db;

  /// #269: la regla de atomicidad vive en UN solo lugar. Ver
  /// `Transaccionador`: el ternario que estaba acá se repetia en seis
  /// services, y escribirlo al revés no tiene sintoma.
  late final Transaccionador _tx = Transaccionador(_db, _sync);
  final RepositorioFacturas _facturas;
  final RepositorioCuentaCorriente _cuenta;

  /// Sync-aware (HU-086): con el Outbox presente, cada reparación corre dentro de
  /// `enTransaccion` para que la re-vinculación, el débito y sus mutaciones encoladas
  /// sean ATÓMICAS. Null (tests / sin backend) → transacción Drift local.
  final ServicioSincronizacionSupabase? _sync;

  ServicioReparacionFacturas(
    this._db,
    this._facturas,
    this._cuenta, [
    this._sync,
  ]);

  /// Repara las facturas huérfanas de toda la base local. Devuelve cuántas reparó.
  Future<int> reparar() async {
    final proveedores = await _db.select(_db.proveedores).get();
    final porId = {for (final p in proveedores) p.id: p};
    // Clave "negocioId|nombre" → id del proveedor (se prefiere el ACTIVO ante repetidos).
    final porNombre = <String, String>{};
    for (final p in proveedores) {
      final clave = _claveNombre(p.negocioId, p.nombre);
      final actual = porNombre[clave];
      if (actual == null || (!porId[actual]!.activo && p.activo)) {
        porNombre[clave] = p.id;
      }
    }

    final facturas = await _db.select(_db.facturas).get();
    var reparadas = 0;
    var fallos = 0;
    for (final f in facturas) {
      final idActual = f.proveedorId;
      // Bien vinculada sólo si apunta a un proveedor ACTIVO (la cuenta corriente lista
      // activos). Null, inexistente o inactivo → se intenta re-vincular.
      final ligadaActivo =
          idActual != null && (porId[idActual]?.activo ?? false);
      if (ligadaActivo) continue;

      final resuelto = await _resolverProveedor(f, porId, porNombre);
      if (resuelto == null) continue; // no se pudo resolver: se deja como está

      // HU-086 (C2): la re-vinculación y el débito son UNA transacción. Sin esto, un
      // fallo entre ambas escrituras dejaba la factura re-vinculada pero SIN débito; y
      // como el guard `ligadaActivo` la saltea, el reintento NO la recuperaba nunca.
      // Con el Outbox suspendido (enTransaccion) la cola participa; un fallo revierte
      // ambas escrituras y el reintento vuelve a procesar la factura entera.
      Future<void> cuerpo() async {
        await _facturas.actualizarProveedor(f.id, resuelto);
        // Débito idempotente: sólo si no existe. Se usa la fecha de la factura para no
        // reordenar la cronología con "hoy".
        final movimientoExistente =
            await (_db.select(_db.movimientosCuentaCorriente)..where(
                  (m) =>
                      m.referenciaId.equals(f.id) &
                      m.tipoMovimiento.equals('factura'),
                ))
                .getSingleOrNull();
        if (movimientoExistente == null) {
          await _cuenta.registrarMovimiento(
            negocioId: f.negocioId,
            proveedorId: resuelto,
            tipoMovimiento: 'factura',
            monto: f.totalBruto,
            referenciaId: f.id,
            descripcion: 'Factura ${f.numeroFactura}',
            fecha: f.fechaFactura,
          );
        }
      }

      // Aislamiento POR FACTURA (HU-086): una factura que falla no debe abortar el loop
      // ni hambrear a las siguientes. Se loguea y se sigue; si al final hubo fallos se
      // lanza, para que el arranque NO marque la reparación como completa y reintente en
      // el próximo boot (las ya reparadas se saltean por el guard `ligadaActivo`).
      try {
        await _tx.correr(cuerpo);
        reparadas++;
      } catch (e) {
        fallos++;
        debugPrint(
          '[REPARACION] Factura ${f.id} no se pudo reparar (se reintentará en el próximo arranque): $e',
        );
      }
    }
    if (fallos > 0) {
      throw ReparacionIncompletaException(reparadas, fallos);
    }
    return reparadas;
  }

  /// Resuelve el proveedor de una factura huérfana a partir de su pedido: el
  /// `proveedorId` del pedido si es válido, o el proveedor que matchea el nombre
  /// denormalizado del pedido. Devuelve null si no hay forma de resolverlo.
  Future<String?> _resolverProveedor(
    Factura f,
    Map<String, Proveedore> porId,
    Map<String, String> porNombre,
  ) async {
    final pedidoId = f.pedidoId;
    if (pedidoId == null) return null;
    final pedido = await (_db.select(
      _db.pedidos,
    )..where((p) => p.id.equals(pedidoId))).getSingleOrNull();
    if (pedido == null) return null;

    final pid = pedido.proveedorId;
    if (pid != null && (porId[pid]?.activo ?? false)) return pid;
    return porNombre[_claveNombre(f.negocioId, pedido.proveedorNombre)];
  }

  String _claveNombre(String negocioId, String nombre) =>
      '$negocioId|${nombre.trim().toLowerCase()}';
}

/// Se lanza al final de [ServicioReparacionFacturas.reparar] si alguna factura no se
/// pudo reparar (HU-086). Señala al arranque que NO marque la reparación como completa,
/// para reintentar las fallidas en el próximo boot sin hambrear a las que sí se
/// repararon (esas quedaron committeadas y el guard las saltea).
class ReparacionIncompletaException implements Exception {
  final int reparadas;
  final int fallos;
  const ReparacionIncompletaException(this.reparadas, this.fallos);

  @override
  String toString() =>
      'Reparación incompleta: $reparadas reparada(s), $fallos con error (se reintentarán).';
}
