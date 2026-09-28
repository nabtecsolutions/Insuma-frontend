import 'dart:convert';

import 'package:drift/drift.dart';

import '../database/database.dart';
import '../data/repositorios/repositorio_recepciones.dart';
import '../data/repositorios/repositorio_adjuntos.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import '../data/repositorios/repositorio_facturas.dart';
import '../models/recepcion_facturable.dart';
import '../utils/adjuntos/tipo_adjunto.dart';
import '../utils/desenlace_recepcion.dart';
import '../utils/estados_pedido.dart';
import '../utils/dinero.dart';
import 'servicio_sincronizacion_supabase.dart';

/// Servicio de negocio de la vista admin de recepciones/pagos (HU-067).
///
/// Compone, por negocio, las recepciones con su pedido, proveedor, remito y estado
/// de facturación, y decide cuáles quedan "por facturar". Es el único lugar donde
/// vive esa lógica: el controlador sólo orquesta y la vista sólo muestra.
/// Desde HU-143 también edita el total recibido manual (con auditoría).
class ServicioRecepcionesAdmin {
  final BaseDatosApp _db;
  final RepositorioRecepciones _recepciones;
  final RepositorioAdjuntos _adjuntos;
  final RepositorioFacturas _facturas;
  final RepositorioAuditoria? _auditoria;
  final ServicioSincronizacionSupabase? _sync;

  ServicioRecepcionesAdmin(
    this._db,
    this._recepciones,
    this._adjuntos,
    this._facturas, [
    this._auditoria,
    this._sync,
  ]);

  /// HU-147: deja constancia de que se cargó la FACTURA del proveedor sobre una
  /// recepción ya cerrada.
  ///
  /// El adjunto en sí lo persiste el controlador de adjuntos (misma
  /// infraestructura que el remito y el comprobante); lo que vive acá es la
  /// regla de negocio: el "quién lo cargó y cuándo" va a `registros_auditoria`
  /// (HU-030) y NO a columnas nuevas de `adjuntos`. Duplicarlo como columnas
  /// crearía un segundo registro que se desincroniza del primero.
  ///
  /// Cargar una factura NO pisa la anterior: los adjuntos son filas, así que el
  /// rastro de los reemplazos queda entero y el visor muestra la más reciente.
  Future<void> auditarFacturaAdjunta({
    required String negocioId,
    required String recepcionId,
    required String? usuarioId,
  }) async {
    await _auditoria?.registrar(
      negocioId: negocioId,
      usuarioId: usuarioId,
      tablaAfectada: 'adjuntos',
      registroId: recepcionId,
      accion: 'INSERT',
      datosAntes: null,
      datosDespues: {'tipo': TipoAdjunto.factura, 'recepcion_id': recepcionId},
    );
  }

  /// HU-143: escribe (o borra, con [nuevoTotal] null) el total recibido manual
  /// de una recepción ya cerrada. Valida ≥ 0, delega la persistencia + Outbox en
  /// el repositorio y deja auditoría con antes/después. Devuelve la recepción
  /// actualizada. El total editado alimenta facturación, cuenta corriente y
  /// pagos vía [listarPendientesDeFacturar] (montoRecibido).
  Future<Recepcion> editarTotalRecibido({
    required Recepcion recepcion,
    double? nuevoTotal,
    String? usuarioId,
    String? usuarioNombre,
  }) async {
    if (nuevoTotal != null && nuevoTotal < 0) {
      throw ArgumentError.value(
        nuevoTotal,
        'nuevoTotal',
        'El total recibido no puede ser negativo',
      );
    }
    // Revisión HU-143: una recepción YA FACTURADA no se edita — la factura
    // conservaría el monto viejo y la edición quedaría huérfana e invisible
    // (la lista de facturables la excluye). Puede pasar con la lista desfasada
    // (otro dispositivo facturó y el pull todavía no lo trajo).
    final yaFacturada = await (_db.select(
      _db.facturas,
    )..where((f) => f.recepcionId.equals(recepcion.id))).get();
    if (yaFacturada.isNotEmpty) {
      throw StateError(
        'Esta recepción ya está facturada: el total a corregir es el de la factura.',
      );
    }

    final actualizada = await _recepciones.actualizarTotalRecibido(
      recepcion: recepcion,
      nuevoTotal: nuevoTotal,
      usuarioId: usuarioId,
      usuarioNombre: usuarioNombre,
    );
    await _auditoria?.registrar(
      negocioId: recepcion.negocioId,
      usuarioId: usuarioId,
      tablaAfectada: 'recepciones',
      registroId: recepcion.id,
      accion: 'UPDATE',
      datosAntes: {'total_recibido': recepcion.totalRecibido},
      datosDespues: {'total_recibido': nuevoTotal, 'motivo': 'total_manual'},
    );

    // Revisión HU-143: `registrar()` deja pedidos.total = total del ÚLTIMO
    // evento (manual ?? derivado). Si se edita justamente el último, el pedido
    // debe reflejar el mismo criterio o quedan dos totales distintos en pantalla.
    await _sincronizarTotalDelPedido(actualizada);

    return actualizada;
  }

  /// Si [recepcion] es la última de su pedido (mayor número), alinea
  /// `pedidos.total` con su total facturable y encola el UPDATE (payload
  /// mínimo + versionBase, HU-028).
  Future<void> _sincronizarTotalDelPedido(Recepcion recepcion) async {
    final delPedido = await _recepciones.listarPorPedido(recepcion.pedidoId);
    if (delPedido.isEmpty || delPedido.last.id != recepcion.id) return;

    final total = Dinero.redondear(
      totalFacturable(
        totalManual: recepcion.totalRecibido,
        lineas: _lineas(recepcion.items),
      ),
    );
    final pedido = await (_db.select(
      _db.pedidos,
    )..where((p) => p.id.equals(recepcion.pedidoId))).getSingleOrNull();
    if (pedido == null || pedido.total == total) return;

    await (_db.update(_db.pedidos)..where((p) => p.id.equals(pedido.id))).write(
      PedidosCompanion(
        total: Value(total),
        version: Value(pedido.version + 1),
        estadoSync: const Value('pendiente'),
        fechaActualizacion: Value(DateTime.now()),
      ),
    );
    await _sync?.encolarMutacion(
      nombreTabla: 'pedidos',
      registroId: pedido.id,
      accion: 'UPDATE',
      datos: {'id': pedido.id, 'total': total},
      versionBase: pedido.version,
    );
  }

  /// Recepciones del negocio pendientes de facturar (más recientes primero). Se
  /// factura "contra remito" (por lo recibido), así que se EXCLUYEN:
  ///  • las ya facturadas (existe una factura ligada a su `recepcionId`),
  ///  • las de pedidos en efectivo HISTÓRICOS (#229): los que el flujo viejo
  ///    cerró en 'facturado'/'pagado' al recibir, sin factura ni pago reales.
  ///    Los pedidos en efectivo NUEVOS ya no saltan de estado al recibir, así
  ///    que SÍ aparecen acá — procesarlos es justamente lo que les asienta la
  ///    plata.
  /// Las de monto 0 (todo rechazado o precio no capturado) SÍ se listan (HU-128):
  /// deben poder verse y facturarse contra su remito igual que el resto.
  Future<List<RecepcionFacturable>> listarPendientesDeFacturar(
    String negocioId,
  ) async {
    final recepciones = await _recepciones.listarPorNegocio(negocioId);
    if (recepciones.isEmpty) return const [];

    // recepcionId ya facturados (una factura por remito).
    final facturas = await _facturas.listarPorNegocio(negocioId);
    final yaFacturadas = facturas
        .map((f) => f.recepcionId)
        .whereType<String>()
        .toSet();

    // Pedidos y proveedores del negocio, indexados por id.
    final pedidos = {
      for (final p in await (_db.select(
        _db.pedidos,
      )..where((p) => p.negocioId.equals(negocioId))).get())
        p.id: p,
    };
    final proveedores = {
      for (final pr in await (_db.select(
        _db.proveedores,
      )..where((pr) => pr.negocioId.equals(negocioId))).get())
        pr.id: pr,
    };

    // Índice por nombre normalizado para RE-VINCULAR la factura cuando el pedido no
    // trae `proveedorId` (o trae uno inexistente): pedidos legacy/sincronizados. Sin
    // esto la factura queda huérfana y no aparece en la cuenta corriente del proveedor.
    // Se prefiere el proveedor ACTIVO ante nombres repetidos.
    final proveedorIdPorNombre = <String, String>{};
    for (final pr in proveedores.values) {
      final clave = pr.nombre.trim().toLowerCase();
      final actualId = proveedorIdPorNombre[clave];
      if (actualId == null || (!proveedores[actualId]!.activo && pr.activo)) {
        proveedorIdPorNombre[clave] = pr.id;
      }
    }

    // Cuántas recepciones tiene cada pedido (para marcar las parciales).
    final conteoPorPedido = <String, int>{};
    for (final r in recepciones) {
      conteoPorPedido[r.pedidoId] = (conteoPorPedido[r.pedidoId] ?? 0) + 1;
    }

    final resultado = <RecepcionFacturable>[];
    for (final r in recepciones) {
      if (yaFacturadas.contains(r.id)) continue;

      final pedido = pedidos[r.pedidoId];
      if (pedido == null) continue; // recepción huérfana: la salteamos
      // #229: sólo se excluye el efectivo HISTÓRICO — cerrado por el flujo
      // viejo, que forzaba 'facturado' al recibir sin dejar rastro financiero.
      // El PO decidió darlo por procesado: sus costos ya se cargaron al recibir
      // y regularizar meses de compras a mano no aporta. Un efectivo NUEVO
      // queda en recibido_completo/parcial_cerrado y entra a la lista; al
      // procesarse lo excluye `yaFacturadas`, como a todos.
      if (pedido.tieneEfectivo &&
          (pedido.estado == EstadosPedido.facturado ||
              pedido.estado == EstadosPedido.pagado)) {
        continue;
      }

      final lineas = _lineas(r.items);
      // HU-143: si hay total manual, manda sobre el derivado de las líneas.
      final monto = totalFacturable(
        totalManual: r.totalRecibido,
        lineas: lineas,
      );

      // Proveedor efectivo para facturar/cuenta corriente: el del pedido si apunta a un
      // proveedor ACTIVO; si no (null, inexistente o inactivo), el resuelto por nombre
      // (que prefiere activos). La cuenta corriente sólo lista proveedores activos, así
      // que ligar a uno inactivo dejaría la factura invisible igual.
      final idPedido = pedido.proveedorId;
      final ligadoActivo =
          idPedido != null && (proveedores[idPedido]?.activo ?? false);
      final proveedorIdEfectivo = ligadoActivo
          ? idPedido
          : (proveedorIdPorNombre[pedido.proveedorNombre
                    .trim()
                    .toLowerCase()] ??
                idPedido);

      final adjuntos = await _adjuntos.listarPorRecepcion(r.id);
      resultado.add(
        RecepcionFacturable(
          recepcion: r,
          pedido: pedido,
          proveedorNombre: pedido.proveedorNombre.isNotEmpty
              ? pedido.proveedorNombre
              : (proveedores[proveedorIdEfectivo]?.nombre ?? 'Proveedor'),
          proveedorId: proveedorIdEfectivo,
          desenlace: desenlaceAgregado(lineas),
          montoRecibido: monto,
          tieneRemito: adjuntos.isNotEmpty,
          esParcial: (conteoPorPedido[r.pedidoId] ?? 1) > 1,
        ),
      );
    }
    return resultado;
  }

  List<Map<String, dynamic>> _lineas(String itemsJson) {
    try {
      return (jsonDecode(itemsJson) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return const [];
    }
  }
}
