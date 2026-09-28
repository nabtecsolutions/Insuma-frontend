import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import '../../utils/dinero.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de Facturas (RN-014 / HU-023): la deuda nace con la factura.
abstract class RepositorioFacturas {
  Future<List<Factura>> listarPorNegocio(String negocioId);
  Future<List<Factura>> listarPorProveedor(String proveedorId);
  Future<Factura?> obtener(String id);
  Future<Factura> crear({
    required String negocioId,
    String? proveedorId,
    String? pedidoId,
    String? recepcionId,
    required String numeroFactura,
    required DateTime fechaVencimiento,
    DateTime? fechaFactura,
    required double totalNeto,
    double ivaTotal,
    required double totalBruto,
    String? comprobanteUrl,
    String? comentario,
    String? creadoPor,
  });
  Future<void> actualizarEstado(String id, String estado);

  /// Re-vincula una factura a un proveedor (reparación de facturas huérfanas, HU-070).
  Future<void> actualizarProveedor(String id, String proveedorId);
}

class RepositorioFacturasDrift extends RepositorioSincronizable
    implements RepositorioFacturas {
  RepositorioFacturasDrift(super.db, super.sync);

  static const String _tabla = 'facturas';

  @override
  Future<List<Factura>> listarPorNegocio(String negocioId) {
    return (db.select(db.facturas)
          ..where((f) => f.negocioId.equals(negocioId))
          ..orderBy([(f) => OrderingTerm(expression: f.fechaVencimiento)]))
        .get();
  }

  @override
  Future<List<Factura>> listarPorProveedor(String proveedorId) {
    return (db.select(
      db.facturas,
    )..where((f) => f.proveedorId.equals(proveedorId))).get();
  }

  @override
  Future<Factura?> obtener(String id) =>
      (db.select(db.facturas)..where((f) => f.id.equals(id))).getSingleOrNull();

  @override
  Future<Factura> crear({
    required String negocioId,
    String? proveedorId,
    String? pedidoId,
    String? recepcionId,
    required String numeroFactura,
    required DateTime fechaVencimiento,
    DateTime? fechaFactura,
    required double totalNeto,
    double ivaTotal = 0.0,
    required double totalBruto,
    String? comprobanteUrl,
    String? comentario,
    String? creadoPor,
  }) async {
    // HU-081 (C3): redondear a 2 decimales antes de persistir/pushear (numeric(14,2)).
    totalNeto = Dinero.redondear(totalNeto);
    ivaTotal = Dinero.redondear(ivaTotal);
    totalBruto = Dinero.redondear(totalBruto);
    final id = const Uuid().v4();
    final fFactura = fechaFactura ?? DateTime.now();
    await db
        .into(db.facturas)
        .insert(
          FacturasCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorId: Value(proveedorId),
            pedidoId: Value(pedidoId),
            recepcionId: Value(recepcionId),
            numeroFactura: numeroFactura,
            fechaFactura: Value(fFactura),
            fechaVencimiento: fechaVencimiento,
            totalNeto: totalNeto,
            ivaTotal: Value(ivaTotal),
            totalBruto: totalBruto,
            comprobanteUrl: Value(comprobanteUrl),
            comentario: Value(comentario),
            creadoPor: Value(creadoPor),
          ),
        );
    final creada = await (db.select(
      db.facturas,
    )..where((f) => f.id.equals(id))).getSingle();
    await encolarInsert(_tabla, id, {
      'id': id,
      'negocio_id': negocioId,
      'proveedor_id': proveedorId,
      'pedido_id': pedidoId,
      'recepcion_id': recepcionId,
      'numero_factura': numeroFactura,
      'fecha_factura': iso(fFactura),
      'fecha_vencimiento': iso(fechaVencimiento),
      'total_neto': totalNeto,
      'iva_total': ivaTotal,
      'total_bruto': totalBruto,
      'estado': 'pendiente',
      'comprobante_url': comprobanteUrl,
      'comentario': comentario,
      'creado_por': creadoPor,
    });
    return creada;
  }

  @override
  Future<void> actualizarEstado(String id, String estado) async {
    // HU-028: se captura la version previa como token de concurrencia y se
    // incrementa la local (antes las facturas nunca la tocaban: quedaba en 0).
    final previa = await (db.select(
      db.facturas,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    await (db.update(db.facturas)..where((f) => f.id.equals(id))).write(
      FacturasCompanion(
        estado: Value(estado),
        version: previa == null
            ? const Value.absent()
            : Value(siguienteVersion(previa.version)),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    await encolarUpdate(_tabla, id, {
      'id': id,
      'estado': estado,
    }, versionBase: previa?.version);
  }

  @override
  Future<void> actualizarProveedor(String id, String proveedorId) async {
    final previa = await (db.select(
      db.facturas,
    )..where((f) => f.id.equals(id))).getSingleOrNull();
    await (db.update(db.facturas)..where((f) => f.id.equals(id))).write(
      FacturasCompanion(
        proveedorId: Value(proveedorId),
        version: previa == null
            ? const Value.absent()
            : Value(siguienteVersion(previa.version)),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    await encolarUpdate(_tabla, id, {
      'id': id,
      'proveedor_id': proveedorId,
    }, versionBase: previa?.version);
  }
}
