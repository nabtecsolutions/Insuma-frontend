import 'package:flutter/material.dart';

import '../../../services/servicio_pagos.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/fecha_recepcion.dart';

/// Situación de cuenta del proveedor en la ficha (HU-009).
///
/// **Decisión del PO (2026-08-13):** este panel va SIEMPRE VISIBLE, fuera del
/// desplegable de contacto. El saldo es el dato por el que se entra a la ficha:
/// esconderlo detrás de un toque anula la señal cuando hay algo vencido.
///
/// Es SÓLO presentación. La regla de "cuándo alarmar" ya viene resuelta en
/// [ResumenFinancieroProveedor.destacarSaldo]; acá NO se mira
/// `vencimientos.hayVencidas` para elegir el color, porque tener la decisión en
/// dos lugares es la forma más rápida de que se contradigan.
class PanelFinancieroProveedor extends StatelessWidget {
  /// `null` mientras el resumen se está cargando.
  final ResumenFinancieroProveedor? resumen;

  final bool puedeVerFinanzas;

  const PanelFinancieroProveedor({
    super.key,
    required this.resumen,
    required this.puedeVerFinanzas,
  });

  /// Tolerancia de centavo, igual que en `cuenta_corriente_screen.dart`. Sin
  /// esto, un residuo de coma flotante pinta un "A favor tuyo $0.00" en verde
  /// que no le pasó a nadie: se mantiene el mismo criterio en toda la app.
  static const double _epsilon = 0.001;

  /// Alto mínimo del contenido, compartido por los tres estados (cargando, con
  /// saldo y vacío). Es lo que evita que el panel PEGUE UN SALTO cuando llega
  /// el dato: el placeholder ya reserva el lugar que va a ocupar el saldo.
  static const double _altoMinimo = 58;

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    // Defensa en profundidad (HU-060): la ficha ya no debería montar el panel
    // sin permiso, pero un widget que muestra plata tiene que saber callarse
    // solo. Si alguien lo reusa sin el guard, igual no filtra nada.
    if (!puedeVerFinanzas) return const SizedBox.shrink();

    final r = resumen;
    final destacado = r?.destacarSaldo ?? false;

    return Container(
      // El placeholder de carga tiene barras de ancho FIJO: sin esto el panel
      // se encoge a lo que miden las barras y después salta a lo ancho cuando
      // llega el dato. El salto horizontal se ve tanto o más que el vertical.
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        // Destacado = TODO el bloque en rojo, con el mismo idioma que la franja
        // amarilla de `tarjeta_pedido.dart`: fondo tenue + texto oscuro.
        color: destacado ? InsumaColors.alertRed : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          // Un borde gris alrededor del bloque rosa parece un error de render.
          color: destacado ? Colors.red.shade200 : InsumaColors.cardBorderLight,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: _altoMinimo),
        child: r == null
            ? _cargando()
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // "Sin movimientos" NO es lo mismo que saldo cero con todo
                  // saldado; por eso existe el flag y por eso no se muestra
                  // "$ 0.00" en los dos casos.
                  if (r.sinMovimientos) _sinFacturas() else _bloqueSaldo(r),

                  // El anticipo va FUERA de ese if/else a propósito: un pago
                  // sin imputar deja anticipo con CERO facturas, y si colgara
                  // del estado vacío esa plata "desaparecería" de la ficha
                  // (decisión del PO #4).
                  if (r.anticipo > _epsilon) ...[
                    const SizedBox(height: 10),
                    _lineaAnticipo(r.anticipo, destacado),
                  ],

                  // Ídem: puede haber facturas vencidas Y otras todavía en
                  // término, así que el próximo vencimiento también se muestra
                  // cuando el bloque está destacado.
                  if (r.vencimientos.proximo != null) ...[
                    const SizedBox(height: 8),
                    _lineaProximo(r.vencimientos.proximo!, destacado),
                  ],
                ],
              ),
      ),
    );
  }

  // ─── Estados ───────────────────────────────────────────────────────────────

  /// Placeholder de carga: dos barras grises con la forma del saldo real.
  ///
  /// A propósito NO es un spinner centrado: ocupa el mismo alto que el dato que
  /// viene, así el panel no colapsa ni empuja el resto de la ficha al resolver.
  Widget _cargando() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _barra(ancho: 90, alto: 12),
        const SizedBox(height: 8),
        _barra(ancho: 150, alto: 26),
      ],
    );
  }

  Widget _barra({required double ancho, required double alto}) => Container(
    width: ancho,
    height: alto,
    decoration: BoxDecoration(
      // grey[200] y no grey[100]: este último es el mismo valor que
      // cardBorderLight y la barra se volvía invisible sobre el fondo
      // blanco, o sea un panel en blanco en vez de un "cargando".
      color: Colors.grey[200],
      borderRadius: BorderRadius.circular(6),
    ),
  );

  /// Nunca le facturaron nada a este proveedor.
  ///
  /// El ícono va chico (28) y en línea: el estado vacío de 48 centrado es para
  /// una pantalla entera; acá el panel es un encabezado siempre visible y no
  /// puede quedar más alto que el dato al que reemplaza.
  Widget _sinFacturas() {
    return Row(
      children: [
        Icon(Icons.receipt_long_outlined, size: 28, color: Colors.grey[300]),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Todavía no le facturaste nada a este proveedor',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
        ),
      ],
    );
  }

  /// Saldo total y —si está destacado— por qué.
  Widget _bloqueSaldo(ResumenFinancieroProveedor r) {
    // Mismo idioma que la cabecera de `cuenta_corriente_screen.dart`: es el
    // mismo número del mismo proveedor, y un rótulo distinto acá confundiría
    // más que la duplicación. De paso evita mostrar un "$-300.00" ilegible.
    final debe = r.saldo > _epsilon;
    final aFavor = r.saldo < -_epsilon;
    final etiqueta = debe ? 'Debe' : (aFavor ? 'Saldo a favor' : 'Sin saldo');
    final valor = debe ? r.saldo : (aFavor ? -r.saldo : 0.0);

    final colorTexto = r.destacarSaldo
        ? Colors.red.shade900
        : (debe ? Colors.redAccent : (aFavor ? Colors.green : Colors.grey));
    final colorEtiqueta = r.destacarSaldo ? Colors.red.shade900 : Colors.grey;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(etiqueta, style: TextStyle(fontSize: 13, color: colorEtiqueta)),
        const SizedBox(height: 4),
        Text(
          _money(valor),
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: colorTexto,
          ),
        ),
        if (r.destacarSaldo) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: Colors.red.shade900,
              ),
              const SizedBox(width: 6),
              // Expanded para que el texto envuelva en 360px en vez de desbordar.
              Expanded(
                child: Text(
                  'Tiene facturas vencidas',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade900,
                  ),
                ),
              ),
            ],
          ),
          if (r.vencimientos.masVieja != null) ...[
            const SizedBox(height: 2),
            Padding(
              // Alineado con el texto de arriba (ícono 14 + gap 6).
              padding: const EdgeInsets.only(left: 20),
              child: Text(
                '${r.vencimientos.cantidadVencidas} '
                '${r.vencimientos.cantidadVencidas == 1 ? "factura" : "facturas"}, '
                'la más vieja del '
                '${FechaRecepcion.formatear(r.vencimientos.masVieja)}',
                style: TextStyle(fontSize: 11, color: Colors.red.shade900),
              ),
            ),
          ],
        ],
      ],
    );
  }

  /// Saldo a favor por pagos que todavía no se imputaron a ninguna factura.
  ///
  /// Puede convivir con el "Saldo a favor" del bloque de arriba (mismo signo
  /// del saldo) y no molesta, porque este texto se autoexplica: aclara que son
  /// pagos SIN IMPUTAR, que es justo lo que hay que ir a resolver.
  Widget _lineaAnticipo(double anticipo, bool destacado) {
    // Sobre el fondo rosa del destacado el verde claro no se lee: se usa un
    // teal más oscuro para mantener el contraste sin cambiar el significado.
    final color = destacado ? Colors.teal.shade800 : Colors.teal;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.savings_outlined, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'A favor tuyo ${_money(anticipo)} · '
            'Le pagaste de más, o el pago todavía no se aplicó a ninguna factura',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _lineaProximo(DateTime proximo, bool destacado) {
    final color = destacado ? Colors.red.shade900 : Colors.grey;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.event_outlined, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Próximo vencimiento: ${FechaRecepcion.formatear(proximo)}',
            style: TextStyle(fontSize: 11, color: color),
          ),
        ),
      ],
    );
  }
}
