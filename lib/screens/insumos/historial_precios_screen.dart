import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../models/cambio_precio.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_precios.dart';
import '../../theme/insuma_colors.dart';
import '../widgets/guardia_permiso.dart';

/// Historial de precios de un insumo (HU-017): lista de cambios más recientes
/// primero, con precio anterior/nuevo, variación % y origen, filtrable por
/// período. Solo LECTURA (el historial es append-only/inmutable) y solo para
/// quien ve finanzas (el costo es información de administrador — HU-045/HU-060).
class PantallaHistorialPrecios extends StatefulWidget {
  final Insumo insumo;

  const PantallaHistorialPrecios({super.key, required this.insumo});

  @override
  State<PantallaHistorialPrecios> createState() =>
      _PantallaHistorialPreciosState();
}

class _PantallaHistorialPreciosState extends State<PantallaHistorialPrecios> {
  /// Días hacia atrás del período consultado. Null = toda la historia.
  int? _periodoDias;

  late Future<List<CambioPrecio>> _cambios;

  @override
  void initState() {
    super.initState();
    _cambios = _consultar();
  }

  Future<List<CambioPrecio>> _consultar() {
    final desde = _periodoDias == null
        ? null
        : DateTime.now().subtract(Duration(days: _periodoDias!));
    return context.read<ServicioPrecios>().listarCambios(
      insumoId: widget.insumo.id,
      desde: desde,
    );
  }

  void _cambiarPeriodo(int? dias) {
    setState(() {
      _periodoDias = dias;
      _cambios = _consultar();
    });
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  String _fecha(DateTime f) {
    final l = f.toLocal();
    return '${l.day.toString().padLeft(2, '0')}/${l.month.toString().padLeft(2, '0')}/${l.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        title: Text(
          'Historial de precios — ${widget.insumo.nombre}',
          style: const TextStyle(fontSize: 16),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 1,
      ),
      body: GuardiaPermiso(
        permiso: Permiso.verFinanzas,
        mensaje: 'El historial de precios es información de administrador.',
        child: Column(
          children: [
            _buildFiltroPeriodo(),
            Expanded(child: _buildLista()),
          ],
        ),
      ),
    );
  }

  Widget _buildFiltroPeriodo() {
    Widget chip(String etiqueta, int? dias) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(etiqueta, style: const TextStyle(fontSize: 12)),
        selected: _periodoDias == dias,
        onSelected: (_) => _cambiarPeriodo(dias),
        selectedColor: InsumaColors.primaryBlue.withValues(alpha: 0.15),
        backgroundColor: Colors.grey[100],
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      // #215: `Wrap` y no `Row` — medido, desbordaba 27 px a 360 dp y el chip
      // "Todo" quedaba cortado contra el borde. Son tres filtros EQUIVALENTES,
      // así que bajar uno de renglón no rompe nada: es el patrón de #180/#204.
      child: Wrap(
        spacing: 0,
        runSpacing: 4,
        children: [
          chip('30 días', 30),
          chip('90 días', 90),
          chip('Todo', null),
        ],
      ),
    );
  }

  Widget _buildLista() {
    return FutureBuilder<List<CambioPrecio>>(
      future: _cambios,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final cambios = snapshot.data ?? const <CambioPrecio>[];
        if (cambios.isEmpty) {
          return _vacio(
            _periodoDias == null
                ? 'Sin historial de cambios: solo existe el precio inicial del insumo.'
                : 'Sin cambios de precio en el período seleccionado.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: cambios.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _buildCard(cambios[i]),
        );
      },
    );
  }

  Widget _vacio(String mensaje) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        mensaje,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: Colors.grey),
      ),
    ),
  );

  Widget _buildCard(CambioPrecio c) {
    final variacion = c.variacionPorcentaje;
    final (icono, color) = c.esAumento
        ? (Icons.arrow_upward, Colors.redAccent)
        : c.esBaja
        ? (Icons.arrow_downward, Colors.green)
        : (Icons.horizontal_rule, Colors.grey);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.12),
          child: Icon(icono, color: color, size: 20),
        ),
        // #215: `Wrap` — desbordaba 125 px a 360 dp. El `trailing` ("antes
        // $...") se lleva su parte del ancho y al título le queda poco, así que
        // el precio y su variación no entran en una línea.
        //
        // No se usa elipsis (el otro patrón de la casa, #209): los dos textos
        // son NÚMEROS, y un precio recortado con "…" pierde exactamente el dato
        // que la pantalla existe para mostrar. Que la variación baje de renglón
        // no pierde nada.
        title: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _money(c.precioNuevo),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.black87,
                fontSize: 14,
              ),
            ),
            if (variacion != null)
              Text(
                '${variacion > 0 ? '+' : ''}${(variacion * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              )
            else
              const Text(
                'Inicial',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        subtitle: Text(
          '${_fecha(c.fecha)} · ${c.origenEtiqueta}',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: c.precioAnterior == null
            ? null
            : Text(
                'antes ${_money(c.precioAnterior!)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
      ),
    );
  }
}
