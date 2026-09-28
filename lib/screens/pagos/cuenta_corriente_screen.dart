import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../database/database.dart';
import '../../controllers/controlador_pagos.dart';
import '../../services/servicio_pagos.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../widgets/guardia_permiso.dart';
import 'widgets/formulario_pago_proveedor.dart';
import 'widgets/visor_remito.dart';

/// Detalle de cuenta corriente de un proveedor (HU-025): saldo y vencimientos.
///
/// Muestra el saldo actual y el anticipo a favor, las facturas (resaltando las
/// vencidas), y la cronología de movimientos acotada a un período con saldo
/// inicial → final. Se llega tocando un proveedor en [PantallaPagos].
class PantallaCuentaCorriente extends StatefulWidget {
  final Proveedore proveedor;
  const PantallaCuentaCorriente({super.key, required this.proveedor});

  @override
  State<PantallaCuentaCorriente> createState() =>
      _PantallaCuentaCorrienteState();
}

class _PantallaCuentaCorrienteState extends State<PantallaCuentaCorriente> {
  late DateTime _desde;
  late DateTime _hasta;
  late Future<_DatosCuenta> _futuro;

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    // Período por defecto: mes actual (del 1° a hoy).
    _desde = DateTime(ahora.year, ahora.month, 1);
    _hasta = DateTime(ahora.year, ahora.month, ahora.day, 23, 59, 59);
    _futuro = _cargar();
  }

  Future<_DatosCuenta> _cargar() async {
    final ctrl = context.read<ControladorPagos>();
    final resumen = await ctrl.resumenCuenta(
      widget.proveedor.id,
      desde: _desde,
      hasta: _hasta,
    );
    final anticipo = await ctrl.anticipoDe(widget.proveedor.id);
    return _DatosCuenta(resumen, anticipo);
  }

  Future<void> _elegirPeriodo() async {
    final rango = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
    );
    if (rango == null) return;
    setState(() {
      _desde = DateTime(rango.start.year, rango.start.month, rango.start.day);
      _hasta = DateTime(
        rango.end.year,
        rango.end.month,
        rango.end.day,
        23,
        59,
        59,
      );
      _futuro = _cargar();
    });
  }

  /// #264: abre el formulario de pago del proveedor. Reusa el MISMO punto de
  /// entrada que la lista de Pagos (`abrirFormularioPagoProveedor`), que ya
  /// puentea los providers y avisa; acá no hay lógica de pago nueva. Al
  /// registrarse recarga el Future de la cuenta, porque el FutureBuilder no
  /// escucha al ControladorPagos.
  void _abrirPago() {
    abrirFormularioPagoProveedor(
      context,
      proveedorId: widget.proveedor.id,
      proveedorNombre: widget.proveedor.nombre,
      alRegistrar: () => setState(() => _futuro = _cargar()),
    );
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';
  String _fecha(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: Text('Cuenta corriente — ${widget.proveedor.nombre}'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
        // #264: registrar un pago sin volver a la lista de Pagos. El body ya
        // está bajo GuardiaPermiso, pero el AppBar queda fuera: se gatea igual
        // (mismo criterio que GuardiaPermiso, respeta la elevación por PIN).
        actions: [
          if (Permisos.puede(
            context.watch<ServicioSesion>().usuarioRol,
            Permiso.verFinanzas,
          ))
            IconButton(
              icon: const Icon(Icons.payments_outlined),
              tooltip: 'Registrar pago',
              onPressed: _abrirPago,
            ),
        ],
      ),
      body: GuardiaPermiso(
        permiso: Permiso.verFinanzas,
        mensaje: 'La cuenta corriente es información de administrador.',
        child: FutureBuilder<_DatosCuenta>(
          future: _futuro,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError || !snap.hasData) {
              return Center(
                child: Text(
                  'No se pudo cargar la cuenta corriente.\n${snap.error ?? ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              );
            }
            return _contenido(snap.data!);
          },
        ),
      ),
    );
  }

  Widget _contenido(_DatosCuenta datos) {
    final ctrl = context.read<ControladorPagos>();
    final saldoActual = ctrl.saldo(widget.proveedor.id);
    final facturas = ctrl.facturasDe(widget.proveedor.id);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      children: [
        _cabeceraSaldo(saldoActual, datos.anticipo),
        const SizedBox(height: 20),
        _selectorPeriodo(),
        const SizedBox(height: 8),
        _resumenPeriodo(datos.resumen),
        const SizedBox(height: 20),
        _tituloSeccion('Facturas'),
        const SizedBox(height: 8),
        if (facturas.isEmpty)
          _vacio('Este proveedor no tiene facturas registradas.')
        else
          ...facturas.map((f) => _cardFactura(ctrl, f)),
        const SizedBox(height: 20),
        _tituloSeccion('Movimientos del período'),
        const SizedBox(height: 8),
        if (datos.resumen.sinMovimientos)
          _vacio('No hubo movimientos en el período seleccionado.')
        else
          ...datos.resumen.movimientos.reversed.map(_cardMovimiento),
      ],
    );
  }

  // ─── Cabecera: saldo actual + anticipo ─────────────────────────────────────
  Widget _cabeceraSaldo(double saldo, double anticipo) {
    final debe = saldo > 0.001;
    final aFavor = saldo < -0.001;
    final colorSaldo = debe
        ? Colors.redAccent
        : (aFavor ? Colors.green : Colors.grey);
    final etiqueta = debe ? 'Debe' : (aFavor ? 'Saldo a favor' : 'Sin saldo');
    final valor = debe ? saldo : (aFavor ? -saldo : 0.0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            etiqueta,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Text(
            _money(valor),
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: colorSaldo,
            ),
          ),
          if (anticipo > 0.001) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(
                  Icons.savings_outlined,
                  size: 16,
                  color: Colors.green,
                ),
                const SizedBox(width: 6),
                Text(
                  'Anticipo disponible: ${_money(anticipo)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ─── Selector de período + resumen inicial/final ───────────────────────────
  Widget _selectorPeriodo() {
    return InkWell(
      onTap: _elegirPeriodo,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: InsumaColors.cardBorderLight),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.date_range,
              size: 18,
              color: InsumaColors.primaryBlue,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Del ${_fecha(_desde)} al ${_fecha(_hasta)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Text(
              'Cambiar',
              style: TextStyle(fontSize: 12, color: InsumaColors.primaryBlue),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resumenPeriodo(ResumenCuentaCorriente r) {
    return Row(
      children: [
        Expanded(child: _chipSaldo('Saldo inicial', r.saldoInicial)),
        const SizedBox(width: 8),
        Expanded(child: _chipSaldo('Saldo final', r.saldoFinal)),
      ],
    );
  }

  Widget _chipSaldo(String label, double valor) {
    final color = valor > 0.001
        ? Colors.redAccent
        : (valor < -0.001 ? Colors.green : Colors.grey);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 2),
          Text(
            _money(valor),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Facturas (resalta vencidas) ───────────────────────────────────────────
  Widget _cardFactura(ControladorPagos ctrl, Factura f) {
    final vencida = ctrl.facturaVencida(f);
    final saldo = ctrl.saldoFactura(f);
    final saldada = f.estado == 'pagada';
    final comentario = (f.comentario ?? '').trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: vencida ? const Color(0xFFFDECEA) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: vencida ? Colors.redAccent : InsumaColors.cardBorderLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Factura ${f.numeroFactura}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                            fontSize: 14,
                          ),
                        ),
                        if (vencida) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.redAccent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'VENCIDA',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Vence ${_fecha(f.fechaVencimiento)} · Total ${_money(f.totalBruto)}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    saldada ? 'Pagada' : 'Saldo ${_money(saldo)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: saldada
                          ? Colors.green
                          : (vencida ? Colors.redAccent : Colors.black87),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    f.estado,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
          if (comentario.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              comentario,
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
          // #238: la factura del proveedor y los comprobantes de esa
          // recepción, bajo UN botón. Antes decía 'Ver comprobante' y abría
          // solo tipo 'comprobante' (HU-069) — que era donde el wizard viejo
          // guardaba todo; las filas nuevas de transferencia van como
          // 'factura' y con el botón viejo se habrían vuelto invisibles acá.
          if (f.recepcionId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _verRespaldo(f),
                icon: const Icon(
                  Icons.attach_file,
                  size: 16,
                  color: InsumaColors.primaryBlue,
                ),
                label: const Text(
                  'Ver factura / comprobante',
                  style: TextStyle(color: InsumaColors.primaryBlue),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _verRespaldo(Factura f) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PantallaVisorRemito.deRespaldoFactura(
          respaldoDeRecepcionId: f.recepcionId!,
          titulo: 'Factura ${f.numeroFactura}',
        ),
      ),
    );
  }

  // ─── Movimientos del período (con saldo corriente) ─────────────────────────
  Widget _cardMovimiento(MovimientoConSaldo ms) {
    final m = ms.movimiento;
    final esCredito = m.monto < 0; // pago/anticipo a favor
    final colorMonto = esCredito ? Colors.green : Colors.redAccent;
    final signo = esCredito ? '−' : '+';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: Row(
        children: [
          Icon(_iconoMovimiento(m.tipoMovimiento), size: 20, color: colorMonto),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.descripcion ?? _etiquetaTipo(m.tipoMovimiento),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _fecha(m.fechaMovimiento),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          // #238: el comprobante de la transferencia, junto al movimiento del
          // pago — que es donde se lo va a buscar. `referenciaId` de un
          // movimiento 'pago' ES el id del pago (ServicioPagos lo escribe así).
          if (m.tipoMovimiento == 'pago' && m.referenciaId != null)
            IconButton(
              tooltip: 'Ver comprobante del pago',
              icon: const Icon(
                Icons.attach_file,
                size: 18,
                color: InsumaColors.primaryBlue,
              ),
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PantallaVisorRemito.deComprobanteDePago(
                    comprobantesDePagoId: m.referenciaId!,
                    titulo: 'Comprobante del pago',
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$signo${_money(m.monto.abs())}',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: colorMonto,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Saldo ${_money(ms.saldoAcumulado)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _iconoMovimiento(String tipo) {
    switch (tipo) {
      case 'pago':
        return Icons.payments_outlined;
      case 'factura':
        return Icons.receipt_long_outlined;
      case 'anticipo':
        return Icons.savings_outlined;
      case 'nota_credito':
        return Icons.undo_outlined;
      default:
        return Icons.swap_horiz;
    }
  }

  String _etiquetaTipo(String tipo) {
    switch (tipo) {
      case 'pago':
        return 'Pago';
      case 'factura':
        return 'Factura';
      case 'anticipo':
        return 'Anticipo';
      case 'nota_credito':
        return 'Nota de crédito';
      default:
        return 'Ajuste';
    }
  }

  Widget _tituloSeccion(String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.bold,
      color: Colors.black87,
    ),
  );

  Widget _vacio(String t) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(t, style: const TextStyle(color: Colors.grey, fontSize: 13)),
  );
}

/// Agrupa lo que la pantalla necesita resolver de forma asíncrona.
class _DatosCuenta {
  final ResumenCuentaCorriente resumen;
  final double anticipo;
  const _DatosCuenta(this.resumen, this.anticipo);
}
