import 'package:drift/drift.dart';

import '../data/repositorios/repositorio_factura_items.dart';
import '../database/database.dart';
import '../models/cambio_precio.dart';
import '../utils/dinero.dart';
import 'servicio_sincronizacion_supabase.dart';

/// Servicio de precios de insumos. Registra el historial (fuente de verdad),
/// actualiza la caché local y genera alertas de desviación según el umbral
/// configurable (HU-018). Encola ÚNICAMENTE el INSERT de historial_precios:
/// en Supabase, el trigger reproduce la alerta y la caché, evitando duplicación.
class ServicioPrecios {
  final BaseDatosApp _db;
  final ServicioSincronizacionSupabase? _sync;

  /// #242: la autoridad del "Últ. compra" real. Inyectable para tests; con
  /// null se construye perezoso sobre la misma base (los 12 call-sites del
  /// constructor no cambian). Acá solo se LEE: el sync del repo no se usa.
  RepositorioFacturaItems? _facturaItems;

  ServicioPrecios(this._db, this._sync, {this._facturaItems});

  RepositorioFacturaItems get _itemsReales =>
      _facturaItems ??= RepositorioFacturaItemsDrift(_db, _sync);

  Future<String> registrar({
    required String insumoId,
    required double nuevoPrecio,
    required String origen, // compra_manual, compra_ocr, ajuste_manual
    String? proveedorId,
    String? referenciaId,
    String? usuarioId,
    double ivaPorcentaje = 0.21,
    double umbralAlerta = 0.10,
  }) async {
    nuevoPrecio = Dinero.redondear(nuevoPrecio); // HU-081 (C3)
    final idHistorial = await _db.registrarPrecioInsumo(
      insumoId: insumoId,
      nuevoPrecio: nuevoPrecio,
      origen: origen,
      proveedorId: proveedorId,
      referenciaId: referenciaId,
      usuarioId: usuarioId,
      ivaPorcentaje: ivaPorcentaje,
      umbralAlerta: umbralAlerta,
    );

    await _sync?.encolarMutacion(
      nombreTabla: 'historial_precios',
      registroId: idHistorial,
      accion: 'INSERT',
      datos: {
        'id': idHistorial,
        'insumo_id': insumoId,
        'proveedor_id': proveedorId,
        'usuario_id': usuarioId,
        'precio_unitario_neto': nuevoPrecio,
        'iva_porcentaje': ivaPorcentaje,
        'origen': origen,
        'referencia_id': referenciaId,
        'fecha_registro': DateTime.now().toUtc().toIso8601String(),
      },
    );

    return idHistorial;
  }

  /// #233/#242 — "Últ. compra" de la ficha: último costo REAL de ingreso por
  /// insumo, para UN proveedor dado.
  ///
  /// Desde #242 la autoridad es `factura_items` (los renglones cargados al
  /// PROCESAR la recepción, #229) y NO `historial_precios`: el historial
  /// mezcla las filas del flujo viejo —que guardaban la estimación del
  /// pedido—, ajustes manuales de catálogo y ordena por cuándo se CARGÓ en
  /// vez de cuándo se COMPRÓ. Este dato sigue siendo de referencia y de SOLO
  /// LECTURA — no toca ni precarga el precio pactado (HU-138, "cotizar no es
  /// comprar").
  ///
  /// Devuelve insumoId → precio. La clave AUSENTE significa que ese proveedor
  /// no tiene compra PROCESADA del insumo (incluye todo lo anterior a #229,
  /// decisión del PO): la UI muestra "—" y NO el costo de otro proveedor.
  Future<Map<String, double>> ultimoCostoIngresoPorInsumo({
    required String proveedorId,
    required Set<String> insumosIds,
  }) async => (await _itemsReales.ultimosIngresosPorInsumo(
    proveedorId: proveedorId,
    insumosIds: insumosIds,
  )).map((id, ingreso) => MapEntry(id, ingreso.precio));

  /// Espejo de [ultimoCostoIngresoPorInsumo] para el otro eje del editor de
  /// vínculos: proveedorId → último precio al que entregó [insumoId].
  Future<Map<String, double>> ultimoCostoIngresoPorProveedor({
    required String insumoId,
    required Set<String> proveedoresIds,
  }) async => (await _itemsReales.ultimosIngresosPorProveedor(
    insumoId: insumoId,
    proveedoresIds: proveedoresIds,
  )).map((id, ingreso) => MapEntry(id, ingreso.precio));

  /// Costo REAL por insumo de las facturas de UN pedido (#242): lo que el
  /// detalle del pedido muestra donde antes iba la estimación. Clave ausente =
  /// ese insumo no tiene renglón procesado (pedido pendiente o pre-#229): la
  /// UI cae al estimado, ROTULADO como tal (decisión del PO).
  Future<Map<String, double>> costosRealesDelPedido(String pedidoId) =>
      _itemsReales.costosRealesPorPedido(pedidoId);

  /// El último ingreso COMPLETO (precio + alícuota) por insumo (#243): lo que
  /// el wizard de Procesar siembra al abrir. Misma autoridad y mismas reglas
  /// que [ultimoCostoIngresoPorInsumo] — una sola fuente para la ficha y para
  /// la precarga, sin dos verdades.
  Future<Map<String, ({double precio, double alicuota})>>
  ultimoIngresoPorInsumo({
    required String proveedorId,
    required Set<String> insumosIds,
  }) => _itemsReales.ultimosIngresosPorInsumo(
    proveedorId: proveedorId,
    insumosIds: insumosIds,
  );

  /// Historial de cambios de precio de un insumo (HU-017), MÁS RECIENTE primero.
  ///
  /// El precio anterior y la variación se derivan encadenando cada registro con
  /// el cronológicamente anterior del MISMO insumo. El encadenado se hace sobre
  /// la historia completa y el período se filtra DESPUÉS: así el primer cambio
  /// dentro del período conserva su precio anterior real (que puede estar fuera
  /// del rango consultado).
  Future<List<CambioPrecio>> listarCambios({
    required String insumoId,
    DateTime? desde,
    DateTime? hasta,
  }) async {
    final filas =
        await (_db.select(_db.historialPrecios)
              ..where((h) => h.insumoId.equals(insumoId))
              ..orderBy([
                (h) => OrderingTerm.asc(h.fechaRegistro),
                (h) => OrderingTerm.asc(h.fechaCreacion), // desempate estable
              ]))
            .get();
    return encadenarCambios(filas, desde: desde, hasta: hasta);
  }

  /// Lógica PURA del encadenado (testeable sin BBDD): recibe las filas en orden
  /// cronológico ascendente y devuelve los [CambioPrecio] del período, en orden
  /// descendente (más reciente primero).
  static List<CambioPrecio> encadenarCambios(
    List<HistorialPrecio> filasAscendentes, {
    DateTime? desde,
    DateTime? hasta,
  }) {
    final cambios = <CambioPrecio>[];
    double? anterior;
    for (final f in filasAscendentes) {
      final cambio = CambioPrecio(
        fecha: f.fechaRegistro,
        precioNuevo: f.precioUnitarioNeto,
        precioAnterior: anterior,
        origen: f.origen,
        proveedorId: f.proveedorId,
      );
      anterior = f.precioUnitarioNeto;
      final dentroDelPeriodo =
          (desde == null || !f.fechaRegistro.isBefore(desde)) &&
          (hasta == null || !f.fechaRegistro.isAfter(hasta));
      if (dentroDelPeriodo) cambios.add(cambio);
    }
    return cambios.reversed.toList();
  }
}
