import 'package:drift/drift.dart';
import '../database/database.dart';
import '../data/repositorios/repositorio_facturas.dart';
import '../data/repositorios/repositorio_cuenta_corriente.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import 'servicio_sincronizacion_supabase.dart';
import 'guarda_primer_pull.dart';
import '../utils/transiciones_pedido.dart';
import '../data/transaccionador.dart';
import 'servicio_transiciones_pedido.dart' show TransicionInvalidaException;

/// Servicio de facturación (RN-014 / HU-023): la deuda NACE con la factura.
/// Al registrar una factura se genera el débito en la cuenta corriente del
/// proveedor y, si proviene de un pedido, se marca el pedido como 'facturado'.
class ServicioFacturacion {
  final BaseDatosApp _db;

  /// #269: la regla de atomicidad vive en UN solo lugar. Ver
  /// `Transaccionador`: el ternario que estaba acá se repetia en seis
  /// services, y escribirlo al revés no tiene sintoma.
  late final Transaccionador _tx = Transaccionador(_db, _sync);
  final RepositorioFacturas _facturas;
  final RepositorioCuentaCorriente _cuenta;
  final RepositorioAuditoria _auditoria;
  final ServicioSincronizacionSupabase? _sync;

  /// Guarda del primer pull (HU-090): bloquea registrar movimientos hasta que el
  /// negocio esté hidratado en este dispositivo. Null en tests → sin bloqueo.
  final GuardaPrimerPull? _guarda;

  ServicioFacturacion(
    this._db,
    this._facturas,
    this._cuenta,
    this._auditoria, [
    this._sync,
    this._guarda,
  ]);

  /// Registra una factura. Con [recepcionId] se factura "contra remito" (HU-067):
  /// la factura queda ligada a la recepción concreta. [marcarPedidoFacturado] indica
  /// si, además, el pedido debe pasar a 'facturado' — el llamador lo pone en `true`
  /// sólo cuando ya no quedan más recepciones del pedido por facturar (evita marcar
  /// facturado un pedido con recepciones parciales aún pendientes).
  Future<Factura> registrarFactura({
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
    String? usuarioId,
    String? justificacion,
    bool marcarPedidoFacturado = true,
  }) async {
    verificarPrimerPull(_guarda, negocioId);
    // HU-079 (C2): factura + débito de cuenta corriente + pedido + auditoría en UNA
    // transacción. Con el Outbox suspendido la cola participa; un fallo revierte todo.
    Future<Factura> cuerpo() async {
      final factura = await _facturas.crear(
        negocioId: negocioId,
        proveedorId: proveedorId,
        pedidoId: pedidoId,
        recepcionId: recepcionId,
        numeroFactura: numeroFactura,
        fechaVencimiento: fechaVencimiento,
        fechaFactura: fechaFactura,
        totalNeto: totalNeto,
        ivaTotal: ivaTotal,
        totalBruto: totalBruto,
        comprobanteUrl: comprobanteUrl,
        comentario: comentario,
        creadoPor: usuarioId,
      );

      // La deuda nace con la factura: débito (+) en la cuenta corriente.
      if (proveedorId != null) {
        await _cuenta.registrarMovimiento(
          negocioId: negocioId,
          proveedorId: proveedorId,
          tipoMovimiento: 'factura',
          monto: totalBruto,
          referenciaId: factura.id,
          descripcion: 'Factura $numeroFactura',
        );
      }

      // Marcar el pedido como facturado (RN-012). Con facturación contra remito sólo
      // se marca cuando ya no quedan recepciones del pedido por facturar (HU-067).
      if (pedidoId != null && marcarPedidoFacturado) {
        // HU-141: validar contra la matriz antes de escribir (la identidad
        // facturado → facturado es válida: p. ej. pedido ya facturado por efectivo).
        final previo = await (_db.select(
          _db.pedidos,
        )..where((p) => p.id.equals(pedidoId))).getSingleOrNull();
        if (previo != null &&
            previo.estado != 'facturado' &&
            !TransicionesPedido.puede(previo.estado, 'facturado')) {
          throw TransicionInvalidaException(
            'No se puede facturar un pedido en estado "${previo.estado}".',
          );
        }
        await (_db.update(
          _db.pedidos,
        )..where((p) => p.id.equals(pedidoId))).write(
          PedidosCompanion(
            estado: const Value('facturado'),
            estadoSync: const Value('pendiente'),
            fechaActualizacion: Value(DateTime.now()),
          ),
        );
        await _sync?.encolarMutacion(
          nombreTabla: 'pedidos',
          registroId: pedidoId,
          accion: 'UPDATE',
          datos: {'id': pedidoId, 'estado': 'facturado'},
        );
      }

      await _auditoria.registrar(
        negocioId: negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'facturas',
        registroId: factura.id,
        accion: 'INSERT',
        datosDespues: {
          'numero_factura': numeroFactura,
          'total_bruto': totalBruto,
          // Trazabilidad cuando el total facturado difiere del total del pedido (HU-023).
          if (justificacion != null && justificacion.trim().isNotEmpty)
            'justificacion': justificacion.trim(),
        },
      );

      return factura;
    }

    return _tx.correr(cuerpo);
  }
}
