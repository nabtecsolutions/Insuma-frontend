import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import '../../utils/dinero.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio de cuenta corriente: pagos, imputaciones, anticipos
/// y la cronología de movimientos por proveedor (HU-024 / HU-025).
/// Un hecho puntual: quién y cuándo. `null` en `cuando` = todavía no pasó.
typedef HechoDeCuenta = ({String? usuarioId, DateTime? cuando});

/// Lo que #273 necesita saber de la cadena factura → pago de un pedido.
typedef HechosDeFacturacion = ({HechoDeCuenta? factura, HechoDeCuenta? pago});

abstract class RepositorioCuentaCorriente {
  Future<Pago> crearPago({
    required String negocioId,
    required String proveedorId,
    required double monto,
    required String metodo,
    String? referenciaExterna,
    DateTime? fechaPago,
    String? nota,
    String? creadoPor,
  });
  Future<Pago?> buscarPagoPorReferencia(
    String negocioId,
    String referenciaExterna,
  );
  Future<ImputacionPago> imputar({
    required String pagoId,
    required String facturaId,
    required double monto,
  });
  Future<double> totalImputadoFactura(String facturaId);
  Future<MovimientoCuentaCorriente> registrarMovimiento({
    required String negocioId,
    required String proveedorId,
    required String tipoMovimiento,
    required double monto,
    String? referenciaId,
    String? descripcion,
    DateTime? fecha,
  });

  /// Quién facturó y quién pagó este pedido, con sus fechas (#273).
  ///
  /// Tres saltos: `pedido → facturas.pedido_id → imputaciones_pago.factura_id →
  /// pagos`. Va en UNA lectura del repositorio y no en tres desde el Service,
  /// para no pasear ids intermedios por la capa de negocio.
  ///
  /// Devuelve los PRIMEROS de cada uno. Un pedido puede tener varias facturas
  /// (HU-067 factura contra remito) y varios pagos parciales; lo que este bloque
  /// responde es "cuándo se facturó" y "cuándo se empezó a pagar", no el detalle
  /// financiero, que tiene su propia pantalla.
  Future<HechosDeFacturacion> hechosDeFacturacion(String pedidoId);

  Future<double> saldoProveedor(String proveedorId);
  Future<List<MovimientoCuentaCorriente>> movimientos(String proveedorId);
  Future<double> anticipoProveedor(String proveedorId);
}

class RepositorioCuentaCorrienteDrift extends RepositorioSincronizable
    implements RepositorioCuentaCorriente {
  RepositorioCuentaCorrienteDrift(super.db, super.sync);

  @override
  Future<Pago> crearPago({
    required String negocioId,
    required String proveedorId,
    required double monto,
    required String metodo,
    String? referenciaExterna,
    DateTime? fechaPago,
    String? nota,
    String? creadoPor,
  }) async {
    monto = Dinero.redondear(monto); // HU-081 (C3)
    final id = const Uuid().v4();
    final fecha = fechaPago ?? DateTime.now();
    await db
        .into(db.pagos)
        .insert(
          PagosCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorId: proveedorId,
            monto: monto,
            metodo: metodo,
            referenciaExterna: Value(referenciaExterna),
            fechaPago: Value(fecha),
            nota: Value(nota),
            creadoPor: Value(creadoPor),
          ),
        );
    final creado = await (db.select(
      db.pagos,
    )..where((p) => p.id.equals(id))).getSingle();
    await encolarInsert('pagos', id, {
      'id': id,
      'negocio_id': negocioId,
      'proveedor_id': proveedorId,
      'monto': monto,
      'metodo': metodo,
      'referencia_externa': referenciaExterna,
      'fecha_pago': iso(fecha),
      'nota': nota,
      'creado_por': creadoPor,
    });
    return creado;
  }

  @override
  Future<Pago?> buscarPagoPorReferencia(
    String negocioId,
    String referenciaExterna,
  ) {
    return (db.select(db.pagos)..where(
          (p) =>
              p.negocioId.equals(negocioId) &
              p.referenciaExterna.equals(referenciaExterna),
        ))
        .getSingleOrNull();
  }

  @override
  Future<ImputacionPago> imputar({
    required String pagoId,
    required String facturaId,
    required double monto,
  }) async {
    monto = Dinero.redondear(monto); // HU-081 (C3)
    final id = const Uuid().v4();
    // El tenant de la imputación se deriva de la factura (HU-045): el hijo hereda el
    // negocio del padre, nunca se recibe suelto desde afuera.
    final factura = await (db.select(
      db.facturas,
    )..where((f) => f.id.equals(facturaId))).getSingleOrNull();
    if (factura == null) {
      throw StateError('No se puede imputar: la factura $facturaId no existe.');
    }
    final negocioId = factura.negocioId;
    await db
        .into(db.imputacionesPago)
        .insert(
          ImputacionesPagoCompanion.insert(
            id: id,
            negocioId: negocioId,
            pagoId: pagoId,
            facturaId: facturaId,
            montoImputado: monto,
          ),
        );
    final creada = await (db.select(
      db.imputacionesPago,
    )..where((i) => i.id.equals(id))).getSingle();
    await encolarInsert('imputaciones_pago', id, {
      'id': id,
      'negocio_id': negocioId,
      'pago_id': pagoId,
      'factura_id': facturaId,
      'monto_imputado': monto,
    });
    return creada;
  }

  @override
  Future<double> totalImputadoFactura(String facturaId) async {
    final filas = await (db.select(
      db.imputacionesPago,
    )..where((i) => i.facturaId.equals(facturaId))).get();
    return filas.fold<double>(0.0, (suma, i) => suma + i.montoImputado);
  }

  @override
  Future<MovimientoCuentaCorriente> registrarMovimiento({
    required String negocioId,
    required String proveedorId,
    required String tipoMovimiento,
    required double monto,
    String? referenciaId,
    String? descripcion,
    DateTime? fecha,
  }) async {
    monto = Dinero.redondear(monto); // HU-081 (C3)
    final saldoPrevio = await saldoProveedor(proveedorId);
    final nuevoSaldo = Dinero.redondear(saldoPrevio + monto);
    final id = const Uuid().v4();
    final ahora = fecha ?? DateTime.now();
    await db
        .into(db.movimientosCuentaCorriente)
        .insert(
          MovimientosCuentaCorrienteCompanion.insert(
            id: id,
            negocioId: negocioId,
            proveedorId: proveedorId,
            tipoMovimiento: tipoMovimiento,
            monto: monto,
            saldo: nuevoSaldo,
            referenciaId: Value(referenciaId),
            descripcion: Value(descripcion),
            fechaMovimiento: Value(ahora),
          ),
        );
    final creado = await (db.select(
      db.movimientosCuentaCorriente,
    )..where((m) => m.id.equals(id))).getSingle();
    await encolarInsert('movimientos_cuenta_corriente', id, {
      'id': id,
      'negocio_id': negocioId,
      'proveedor_id': proveedorId,
      'tipo_movimiento': tipoMovimiento,
      'monto': monto,
      'saldo': nuevoSaldo,
      'referencia_id': referenciaId,
      'descripcion': descripcion,
      'fecha_movimiento': iso(ahora),
    });
    return creado;
  }

  @override
  Future<HechosDeFacturacion> hechosDeFacturacion(String pedidoId) async {
    final facturas =
        await (db.select(db.facturas)
              ..where((f) => f.pedidoId.equals(pedidoId))
              ..orderBy([(f) => OrderingTerm.asc(f.fechaCreacion)]))
            .get();
    if (facturas.isEmpty) return (factura: null, pago: null);

    final primera = facturas.first;
    final hechoFactura = (
      usuarioId: primera.creadoPor,
      cuando: primera.fechaCreacion,
    );

    // Los pagos cuelgan de la factura por `imputaciones_pago`, no del pedido:
    // un pago puede cubrir varias facturas y una factura recibir varios pagos.
    // Se miran las imputaciones de TODAS las facturas del pedido, no sólo de la
    // primera: con facturación contra remito (HU-067) un pedido tiene una
    // factura por recepción, y el primer pago puede haber sido de cualquiera.
    final idsFactura = facturas.map((f) => f.id).toList();
    final imputaciones = await (db.select(
      db.imputacionesPago,
    )..where((i) => i.facturaId.isIn(idsFactura))).get();
    if (imputaciones.isEmpty) {
      return (factura: hechoFactura, pago: null);
    }

    final pagos =
        await (db.select(db.pagos)
              ..where(
                (pg) => pg.id.isIn(imputaciones.map((i) => i.pagoId).toList()),
              )
              ..orderBy([(pg) => OrderingTerm.asc(pg.fechaPago)]))
            .get();
    if (pagos.isEmpty) return (factura: hechoFactura, pago: null);

    return (
      factura: hechoFactura,
      pago: (usuarioId: pagos.first.creadoPor, cuando: pagos.first.fechaPago),
    );
  }

  @override
  Future<double> saldoProveedor(String proveedorId) async {
    // HU-083 (C5): el saldo es DERIVADO = SUM(monto) de TODOS los movimientos del
    // proveedor, no el `saldo` guardado del último (que divergía entre dispositivos en
    // la cadena append-only). Independiente del orden de inserción y del dispositivo.
    final sumaMonto = db.movimientosCuentaCorriente.monto.sum();
    final fila =
        await (db.selectOnly(db.movimientosCuentaCorriente)
              ..addColumns([sumaMonto])
              ..where(
                db.movimientosCuentaCorriente.proveedorId.equals(proveedorId),
              ))
            .getSingle();
    return Dinero.redondear(fila.read(sumaMonto) ?? 0.0);
  }

  @override
  Future<List<MovimientoCuentaCorriente>> movimientos(String proveedorId) {
    // Orden cronológico por fecha del movimiento y, como desempate ("secuencia"
    // que pide HU-025), la fecha de creación = orden de inserción. Así dos
    // movimientos del mismo día (p. ej. factura y pago) quedan en orden estable.
    return (db.select(db.movimientosCuentaCorriente)
          ..where((m) => m.proveedorId.equals(proveedorId))
          ..orderBy([
            (m) => OrderingTerm(expression: m.fechaMovimiento),
            (m) => OrderingTerm(expression: m.fechaCreacion),
          ]))
        .get();
  }

  @override
  Future<double> anticipoProveedor(String proveedorId) async {
    // HU-092 (familia C5): el anticipo (saldo a favor) es DERIVADO = lo pagado al
    // proveedor menos lo imputado a sus facturas, NO un acumulador mutable (que sufría
    // lost-update entre dispositivos). = SUM(pagos.monto) − SUM(imputaciones de esos pagos).
    final sumaPagos = db.pagos.monto.sum();
    final totalPagado =
        (await (db.selectOnly(db.pagos)
                  ..addColumns([sumaPagos])
                  ..where(db.pagos.proveedorId.equals(proveedorId)))
                .getSingle())
            .read(sumaPagos) ??
        0.0;

    final pagosDelProveedor = db.selectOnly(db.pagos)
      ..addColumns([db.pagos.id])
      ..where(db.pagos.proveedorId.equals(proveedorId));
    final sumaImputado = db.imputacionesPago.montoImputado.sum();
    final totalImputado =
        (await (db.selectOnly(db.imputacionesPago)
                  ..addColumns([sumaImputado])
                  ..where(
                    db.imputacionesPago.pagoId.isInQuery(pagosDelProveedor),
                  ))
                .getSingle())
            .read(sumaImputado) ??
        0.0;

    return Dinero.redondear(totalPagado - totalImputado);
  }
}
