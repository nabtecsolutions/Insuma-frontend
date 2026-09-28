import '../database/database.dart';
import '../data/repositorios/repositorio_cuenta_corriente.dart';
import '../data/repositorios/repositorio_facturas.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import 'servicio_sincronizacion_supabase.dart';
import 'guarda_primer_pull.dart';
import '../utils/vencimientos_proveedor.dart';
import '../data/transaccionador.dart';

/// Una imputación solicitada: cuánto del pago se aplica a una factura.
class SolicitudImputacion {
  final String facturaId;
  final double monto;
  const SolicitudImputacion(this.facturaId, this.monto);
}

/// Un movimiento de cuenta corriente con su saldo corriente recomputado
/// cronológicamente (no se confía en el `saldo` guardado, que pudo calcularse
/// con otro orden si un movimiento se cargó con fecha retroactiva).
class MovimientoConSaldo {
  final MovimientoCuentaCorriente movimiento;
  final double saldoAcumulado;
  const MovimientoConSaldo(this.movimiento, this.saldoAcumulado);
}

/// Resumen de cuenta corriente de un proveedor acotado a un período (HU-025):
/// saldo inicial (arrastre previo a [desde]), movimientos del período y saldo
/// final. Por convención del negocio, saldo positivo = deuda, negativo = crédito.
class ResumenCuentaCorriente {
  final DateTime desde;
  final DateTime hasta;
  final double saldoInicial;
  final double saldoFinal;
  final List<MovimientoConSaldo> movimientos;
  const ResumenCuentaCorriente({
    required this.desde,
    required this.hasta,
    required this.saldoInicial,
    required this.saldoFinal,
    required this.movimientos,
  });
  bool get sinMovimientos => movimientos.isEmpty;
}

/// Servicio de pagos y cuenta corriente (HU-024 / HU-025).
/// Registra pagos idempotentes, los imputa a facturas (actualizando su estado),
/// trata el excedente como anticipo y deja la cronología en la cuenta corriente.
/// Lo que la ficha del proveedor necesita saber de su cuenta (HU-009).
class ResumenFinancieroProveedor {
  /// Deuda en positivo; un valor negativo es crédito a favor del negocio.
  final double saldo;

  /// Saldo a favor acumulado (pagos sin imputar), como valor positivo.
  final double anticipo;

  final VencimientosProveedor vencimientos;

  /// Para poder distinguir "sin movimientos" de "todo saldado" en el estado
  /// vacío: las dos cosas dan saldo cero y no significan lo mismo.
  final int cantidadFacturas;

  const ResumenFinancieroProveedor({
    required this.saldo,
    required this.anticipo,
    required this.vencimientos,
    required this.cantidadFacturas,
  });

  /// Sin una sola factura: la ficha muestra el estado vacío en vez de un cero.
  bool get sinMovimientos => cantidadFacturas == 0;

  /// Decisión del PO: alcanza con UNA factura vencida para destacar el saldo
  /// COMPLETO. Se expone acá para que la pantalla no vuelva a decidirlo.
  bool get destacarSaldo => vencimientos.hayVencidas;
}

class ServicioPagos {
  /// #269: este service ya NO guarda la base. Su UNICO uso de Drift era el
  /// ternario de la transaccion, que ahora vive en [Transaccionador] —una sola
  /// copia de la regla de atomicidad, en vez de las seis que habia—. La firma
  /// del constructor no cambia, para no tocar sus 21 sitios de construccion.
  final Transaccionador _tx;
  final RepositorioCuentaCorriente _cuenta;
  final RepositorioFacturas _facturas;
  final RepositorioAuditoria _auditoria;

  /// Guarda del primer pull (HU-090): bloquea registrar movimientos hasta que el
  /// negocio esté hidratado en este dispositivo. Null en tests → sin bloqueo.
  final GuardaPrimerPull? _guarda;

  ServicioPagos(
    BaseDatosApp db,
    this._cuenta,
    this._facturas,
    this._auditoria, [
    ServicioSincronizacionSupabase? sync,
    this._guarda,
  ]) : _tx = Transaccionador(db, sync);

  /// Registra un pago. Si [referenciaExterna] ya existe, devuelve el pago previo
  /// (idempotencia, evita duplicados por reintentos — RN-015).
  ///
  /// [adjuntarEnTransaccion] (#238): hook para escribir el comprobante de la
  /// transferencia DENTRO de la misma transacción, ligado al pago recién
  /// creado (molde de #227/#229). Si lanza, se revierten pago, movimiento e
  /// imputaciones — un pago sin su comprobante o un comprobante suelto sin
  /// pago serían mentiras a medias. En la rama idempotente también se invoca,
  /// con el pago EXISTENTE: reintentar con un archivo re-staged no lo pierde
  /// en silencio (ahí corre como alta suelta, sin transacción — mismo trato
  /// que `adjuntarFactura` de HU-147; a lo sumo queda un segundo comprobante,
  /// que el visor muestra: peor sería perderlo).
  Future<Pago> registrarPago({
    required String negocioId,
    required String proveedorId,
    required double monto,
    required String metodo, // efectivo, transferencia, cheque
    String? referenciaExterna,
    DateTime? fechaPago,
    String? nota,
    String? usuarioId,
    List<SolicitudImputacion> imputaciones = const [],
    Future<void> Function(String pagoId)? adjuntarEnTransaccion,
  }) async {
    verificarPrimerPull(_guarda, negocioId); // HU-090
    if (monto <= 0) {
      throw ArgumentError('El monto del pago debe ser mayor a cero (RN-004).');
    }

    if (referenciaExterna != null && referenciaExterna.isNotEmpty) {
      final existente = await _cuenta.buscarPagoPorReferencia(
        negocioId,
        referenciaExterna,
      );
      if (existente != null) {
        await adjuntarEnTransaccion?.call(existente.id);
        return existente;
      }
    }

    // HU-079 (C2): pago + movimiento + imputaciones + estado de facturas + anticipo +
    // auditoría en UNA transacción. Un fallo a mitad de camino revierte todo.
    Future<Pago> cuerpo() async {
      final pago = await _cuenta.crearPago(
        negocioId: negocioId,
        proveedorId: proveedorId,
        monto: monto,
        metodo: metodo,
        referenciaExterna: referenciaExterna,
        fechaPago: fechaPago,
        nota: nota,
        creadoPor: usuarioId,
      );

      // Crédito (-) en la cuenta corriente del proveedor.
      await _cuenta.registrarMovimiento(
        negocioId: negocioId,
        proveedorId: proveedorId,
        tipoMovimiento: 'pago',
        monto: -monto,
        referenciaId: pago.id,
        descripcion: 'Pago $metodo',
      );

      // Imputar a facturas y actualizar su estado.
      double restante = monto;
      for (final imp in imputaciones) {
        if (restante <= 0) break;
        final factura = await _facturas.obtener(imp.facturaId);
        if (factura == null) continue;
        final aImputar = imp.monto <= restante ? imp.monto : restante;
        if (aImputar <= 0) continue;

        await _cuenta.imputar(
          pagoId: pago.id,
          facturaId: factura.id,
          monto: aImputar,
        );
        restante -= aImputar;

        final imputadoTotal = await _cuenta.totalImputadoFactura(factura.id);
        final nuevoEstado = imputadoTotal >= factura.totalBruto - 0.001
            ? 'pagada'
            : 'parcial';
        await _facturas.actualizarEstado(factura.id, nuevoEstado);
        // COSTURA (#229): cuando una factura queda 'pagada' y tiene `pedidoId`,
        // acá iría la promoción del PEDIDO a 'pagado' para el camino no-efectivo
        // (hoy esos pedidos mueren en 'facturado'). No se hizo a propósito: #229
        // sólo alcanza al efectivo, cuyo pedido lo promueve
        // ServicioProcesarRecepcion en su misma transacción. Si algún día se
        // pide, la matriz ya lo permite (facturado → pagado).
      }

      // HU-092: el excedente NO se guarda en un acumulador (anticipos) — el anticipo
      // a favor es un valor DERIVADO (pagos − imputaciones). Ver anticipoProveedor.

      await _auditoria.registrar(
        negocioId: negocioId,
        usuarioId: usuarioId,
        tablaAfectada: 'pagos',
        registroId: pago.id,
        accion: 'INSERT',
        datosDespues: {'monto': monto, 'metodo': metodo},
      );

      // #238: el comprobante, ÚLTIMO y adentro — si su escritura falla, el
      // rollback se lleva el pago entero (patrón de #227 en las recepciones).
      await adjuntarEnTransaccion?.call(pago.id);

      return pago;
    }

    return _tx.correr(cuerpo);
  }

  /// Saldo actual del proveedor (deuda positiva, crédito negativo).
  Future<double> saldoProveedor(String proveedorId) =>
      _cuenta.saldoProveedor(proveedorId);

  /// Saldo a favor (anticipo) acumulado del proveedor, como valor positivo.
  Future<double> anticipoProveedor(String proveedorId) =>
      _cuenta.anticipoProveedor(proveedorId);

  /// Cronología completa de movimientos del proveedor (orden cronológico).
  Future<List<MovimientoCuentaCorriente>> cuentaCorriente(String proveedorId) =>
      _cuenta.movimientos(proveedorId);

  /// Foto financiera del proveedor para su ficha (HU-009).
  ///
  /// Junta en UNA pasada lo que la pantalla necesita: cuánto se le debe, cuánto
  /// hay a favor y si tiene algo vencido. Se resuelve acá y no en la vista
  /// porque son tres consultas que si no la ficha dispararía sueltas —y una por
  /// proveedor sería un N+1 apenas alguien quiera listarlas.
  ///
  /// La regla de qué está vencido vive en el módulo puro
  /// `utils/vencimientos_proveedor.dart`, no acá: este método sólo trae los
  /// datos y se la delega.
  Future<ResumenFinancieroProveedor> resumenFinancieroProveedor(
    String proveedorId, {
    DateTime? hoy,
  }) async {
    final facturas = await _facturas.listarPorProveedor(proveedorId);
    return ResumenFinancieroProveedor(
      saldo: await _cuenta.saldoProveedor(proveedorId),
      anticipo: await _cuenta.anticipoProveedor(proveedorId),
      vencimientos: resumirVencimientos(facturas, hoy: hoy ?? DateTime.now()),
      cantidadFacturas: facturas.length,
    );
  }

  /// Resumen de cuenta corriente acotado al período [desde, hasta] (HU-025).
  ///
  /// Recorre los movimientos en orden cronológico acumulando el saldo:
  /// - lo previo a [desde] forma el **saldo inicial** (arrastre);
  /// - lo que cae dentro del rango se devuelve con su saldo corriente;
  /// - el **saldo final** es el saldo tras el último movimiento del período
  ///   (o el inicial si el período no tuvo movimientos).
  Future<ResumenCuentaCorriente> resumenPeriodo(
    String proveedorId, {
    required DateTime desde,
    required DateTime hasta,
  }) async {
    final todos = await _cuenta.movimientos(proveedorId);
    double acumulado = 0.0;
    double saldoInicial = 0.0;
    final delPeriodo = <MovimientoConSaldo>[];
    for (final m in todos) {
      acumulado += m.monto;
      if (m.fechaMovimiento.isBefore(desde)) {
        saldoInicial = acumulado;
      } else if (!m.fechaMovimiento.isAfter(hasta)) {
        delPeriodo.add(MovimientoConSaldo(m, acumulado));
      }
    }
    final saldoFinal = delPeriodo.isNotEmpty
        ? delPeriodo.last.saldoAcumulado
        : saldoInicial;
    return ResumenCuentaCorriente(
      desde: desde,
      hasta: hasta,
      saldoInicial: saldoInicial,
      saldoFinal: saldoFinal,
      movimientos: delPeriodo,
    );
  }
}
