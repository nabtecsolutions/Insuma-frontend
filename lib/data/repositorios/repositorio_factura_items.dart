import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../database/database.dart';
import '../../utils/dinero.dart';
import '../../utils/iva.dart';
import 'repositorio_base.dart';

/// Contrato del repositorio del detalle de factura (#229): un renglón por insumo.
///
/// Habla en [LineaCosto] —el value object del módulo puro `utils/iva.dart`— y no
/// en parámetros sueltos. Así el precio, la cantidad y la alícuota viajan juntos
/// desde la pantalla hasta la base sin que nadie pueda mezclar el orden de tres
/// `double` en el camino.
abstract class RepositorioFacturaItems {
  /// Los renglones de una factura, en el orden en que se cargaron.
  Future<List<FacturaItem>> listarPorFactura(String facturaId);

  /// Último ingreso REAL de cada insumo para UN proveedor (#242): el precio y
  /// la alícuota del renglón más reciente entre las facturas NO anuladas de
  /// ese proveedor. "Más reciente" por fecha de FACTURA — que al procesar es
  /// la fecha de la recepción — y no por fecha de carga: procesar recepciones
  /// atrasadas en desorden no debe elegir mal.
  ///
  /// La clave AUSENTE significa que ese proveedor nunca facturó el insumo con
  /// el flujo real de Procesar (#229): la UI muestra '—' y NO inventa. Las
  /// compras pre-#229 no tienen renglones, a propósito (decisión del PO).
  Future<Map<String, ({double precio, double alicuota})>>
  ultimosIngresosPorInsumo({
    required String proveedorId,
    required Set<String> insumosIds,
  });

  /// Espejo para el otro eje del editor de vínculos: proveedorId → último
  /// ingreso de [insumoId].
  Future<Map<String, ({double precio, double alicuota})>>
  ultimosIngresosPorProveedor({
    required String insumoId,
    required Set<String> proveedoresIds,
  });

  /// Costo REAL por insumo de las facturas de UN pedido (#242): lo que el
  /// detalle muestra en lugar de la estimación de al crear el pedido. Con
  /// varias entregas procesadas gana la más reciente por fecha de factura.
  Future<Map<String, double>> costosRealesPorPedido(String pedidoId);

  /// Persiste el detalle COMPLETO de una factura.
  ///
  /// Es un lote y no un renglón por llamada a propósito: una factura con la
  /// mitad de sus renglones no es un estado intermedio válido, es un total que
  /// no cierra contra el papel del proveedor. El llamador lo envuelve en la
  /// transacción que ya abre para la factura.
  Future<void> crearLote({
    required String negocioId,
    required String facturaId,
    required List<LineaCosto> lineas,
  });
}

class RepositorioFacturaItemsDrift extends RepositorioSincronizable
    implements RepositorioFacturaItems {
  RepositorioFacturaItemsDrift(super.db, super.sync);

  static const String _tabla = 'factura_items';

  @override
  Future<List<FacturaItem>> listarPorFactura(String facturaId) {
    return (db.select(db.facturaItems)
          ..where((r) => r.facturaId.equals(facturaId))
          ..orderBy([(r) => OrderingTerm(expression: r.fechaCreacion)]))
        .get();
  }

  @override
  Future<Map<String, ({double precio, double alicuota})>>
  ultimosIngresosPorInsumo({
    required String proveedorId,
    required Set<String> insumosIds,
  }) => _ultimosIngresos(
    donde:
        db.facturas.proveedorId.equals(proveedorId) &
        db.facturaItems.insumoId.isIn(insumosIds),
    clave: (item, _) => item.insumoId,
  );

  @override
  Future<Map<String, ({double precio, double alicuota})>>
  ultimosIngresosPorProveedor({
    required String insumoId,
    required Set<String> proveedoresIds,
  }) => _ultimosIngresos(
    donde:
        db.facturaItems.insumoId.equals(insumoId) &
        db.facturas.proveedorId.isIn(proveedoresIds),
    // El isIn de arriba ya descarta proveedor NULL: el `!` es seguro.
    clave: (_, factura) => factura.proveedorId!,
  );

  @override
  Future<Map<String, double>> costosRealesPorPedido(String pedidoId) async {
    final ingresos = await _ultimosIngresos(
      donde: db.facturas.pedidoId.equals(pedidoId),
      clave: (item, _) => item.insumoId,
    );
    return ingresos.map((id, ingreso) => MapEntry(id, ingreso.precio));
  }

  /// La consulta compartida de los dos ejes (patrón de
  /// `ServicioPrecios._ultimoCostoIngreso`, #233): filas que cumplen [donde]
  /// de la más nueva a la más vieja, y por cada clave gana la primera. Una
  /// factura ANULADA no cuenta como compra.
  Future<Map<String, ({double precio, double alicuota})>> _ultimosIngresos({
    required Expression<bool> donde,
    required String Function(FacturaItem item, Factura factura) clave,
  }) async {
    final query =
        db.select(db.facturaItems).join([
            innerJoin(
              db.facturas,
              db.facturas.id.equalsExp(db.facturaItems.facturaId),
            ),
          ])
          ..where(db.facturas.estado.equals('anulada').not() & donde)
          ..orderBy([
            OrderingTerm.desc(db.facturas.fechaFactura),
            OrderingTerm.desc(db.facturaItems.fechaCreacion),
          ]);
    final filas = await query.get();
    final ultimos = <String, ({double precio, double alicuota})>{};
    for (final fila in filas) {
      final item = fila.readTable(db.facturaItems);
      final factura = fila.readTable(db.facturas);
      ultimos.putIfAbsent(
        clave(item, factura),
        () => (precio: item.netoUnitario, alicuota: item.alicuota),
      );
    }
    return ultimos;
  }

  @override
  Future<void> crearLote({
    required String negocioId,
    required String facturaId,
    required List<LineaCosto> lineas,
  }) async {
    for (final l in lineas) {
      final id = const Uuid().v4();
      // HU-081 (C3): el dinero se redondea a 2 decimales ANTES de persistir, que
      // es la escala de `numeric(14,2)` del servidor. La cantidad y la alícuota
      // no son dinero y no se tocan.
      final neto = Dinero.redondear(l.netoUnitario);

      await db
          .into(db.facturaItems)
          .insert(
            FacturaItemsCompanion.insert(
              id: id,
              negocioId: negocioId,
              facturaId: facturaId,
              insumoId: l.insumoId,
              cantidad: l.cantidad,
              netoUnitario: neto,
              alicuota: Value(l.alicuota),
            ),
          );

      // Mapa de claves EXPLÍCITO, como el resto de los repositorios: es lo que
      // hace que un cliente nuevo contra un servidor sin la tabla mande estas
      // filas a dead-letter en vez de subir a medias. Por eso el `.sql` va
      // siempre primero.
      //
      // No se envían `estado_sync` (no existe en Supabase) ni `fecha_creacion`
      // (lo pone el DEFAULT now() del servidor, como en las demás tablas hijas).
      await encolarInsert(_tabla, id, {
        'id': id,
        'negocio_id': negocioId,
        'factura_id': facturaId,
        'insumo_id': l.insumoId,
        'cantidad': l.cantidad,
        'neto_unitario': neto,
        // FRACCIÓN, igual que la columna. La escala está alineada de las dos
        // puntas desde la migración de #229; mandar 21 acá sería 2100%.
        'alicuota': l.alicuota,
      });
    }
  }
}
