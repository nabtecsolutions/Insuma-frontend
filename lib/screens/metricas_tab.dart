import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../database/database.dart';
import '../controllers/controlador_metricas.dart';
import '../services/servicio_permisos.dart';
import '../theme/insuma_colors.dart';
import 'widgets/guardia_permiso.dart';

/// Pestaña de Métricas y Alertas Financieras.
/// Oculta costos e información económica a los usuarios operadores ("cocinero")
/// y provee un panel de control detallado para administradores ("admin").
class PestanaMetricas extends StatefulWidget {
  const PestanaMetricas({super.key});

  @override
  State<PestanaMetricas> createState() => _PestanaMetricasState();
}

class _PestanaMetricasState extends State<PestanaMetricas> {
  @override
  void initState() {
    super.initState();
    // Ejecutar la carga de métricas después del renderizado inicial
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ControladorMetricas>().cargarDatos();
    });
  }

  /// Gatilla el refresco de las métricas desde la base de datos local
  Future<void> _refrescarDatos() async {
    await context.read<ControladorMetricas>().cargarDatos();
  }

  @override
  Widget build(BuildContext context) {
    // Defensa en profundidad: la pantalla se protege sola. Aunque el menú la
    // esconda a los cocineros, un acceso directo igual queda bloqueado.
    return GuardiaPermiso(
      permiso: Permiso.verFinanzas,
      mensaje:
          'Se requieren credenciales de Administrador para visualizar métricas, costos y alertas financieras de desviación de precios.',
      child: _buildContenido(context),
    );
  }

  Widget _buildContenido(BuildContext context) {
    final db = Provider.of<BaseDatosApp>(context, listen: false);
    final controlador = context.watch<ControladorMetricas>();

    // Spinner de carga mientras recupera datos.
    if (controlador.cargando) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      body: RefreshIndicator(
        onRefresh: _refrescarDatos,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Tarjetas con resumen rápido de alertas y recetas activas
            _buildTarjetasResumen(controlador),
            const SizedBox(height: 20),

            // Listado de alertas por subas de costo superiores al 5%
            _buildSeccionAlertas(controlador, db),
            const SizedBox(height: 20),

            // Auditoría interna de margen y recetas por debajo de la rentabilidad esperada
            _buildSeccionAuditoriaRentabilidad(controlador),
          ],
        ),
      ),
    );
  }

  /// Tarjetas estadísticas rápidas de la cocina.
  Widget _buildTarjetasResumen(ControladorMetricas controlador) {
    return Row(
      children: [
        Expanded(
          child: _buildTarjetaEstadistica(
            'Alertas Activas',
            '${controlador.alertasActivas.length}',
            controlador.alertasActivas.isNotEmpty
                ? Colors.redAccent
                : Colors.green,
            Icons.warning_amber_rounded,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildTarjetaEstadistica(
            'Recetas Activas',
            '${controlador.recetas.length}',
            InsumaColors.primaryBlue,
            Icons.restaurant_menu_rounded,
          ),
        ),
      ],
    );
  }

  Widget _buildTarjetaEstadistica(
    String titulo,
    String valor,
    Color color,
    IconData icono,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: InsumaColors.cardBorderLight),
      ),
      child: Row(
        children: [
          Icon(icono, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  valor,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Lista de alertas activas registradas en caliente tras subas superiores al 5%.
  Widget _buildSeccionAlertas(
    ControladorMetricas controlador,
    BaseDatosApp db,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Desviaciones detectadas (Aumento >= 5%)',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 8),
        if (controlador.alertasActivas.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: InsumaColors.cardBorderLight),
            ),
            child: const Center(
              child: Text(
                'No hay alertas de desviación de precios activas.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: controlador.alertasActivas.length,
            itemBuilder: (context, index) {
              final fila = controlador.alertasActivas[index];
              final alerta = fila.readTable(db.alertasDesviacion);
              final insumo = fila.readTable(db.insumos);

              final porcentaje = (alerta.porcentajeDesviacion * 100)
                  .toStringAsFixed(1);
              final precioAnterior = alerta.precioAnteriorNeto.toStringAsFixed(
                2,
              );
              final precioNuevo = alerta.precioNuevoNeto.toStringAsFixed(2);

              return Card(
                color: Colors.white,
                elevation: 0,
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: InsumaColors.cardBorderLight),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: InsumaColors.alertRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.trending_up,
                          color: Colors.red,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              insumo.nombre,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            Text(
                              'Aumentó: +$porcentaje% (De \$$precioAnterior a \$$precioNuevo)',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.check,
                          color: Colors.green,
                          size: 20,
                        ),
                        tooltip: 'Marcar como resuelta',
                        onPressed: () => controlador.resolverAlerta(alerta.id),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  /// Alerta e identifica recetas cuyo margen real está por debajo del margen deseado.
  Widget _buildSeccionAuditoriaRentabilidad(ControladorMetricas controlador) {
    final lista = controlador.recetasBajoMargen;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Auditoría de rentabilidad y bajo margen',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 8),
        if (lista.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: InsumaColors.cardBorderLight),
            ),
            child: const Center(
              child: Text(
                'Todas las recetas cumplen con el margen deseado.',
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: lista.length,
            itemBuilder: (context, index) {
              final item = lista[index];
              final receta = item['receta'] as Receta;
              final costoPorPorcion = item['costoPorPorcion'] as double;
              final margenReal = item['margenReal'] as double;
              final margenDeseado = item['margenDeseado'] as double;

              return Card(
                color: Colors.white,
                elevation: 0,
                margin: const EdgeInsets.symmetric(vertical: 4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: InsumaColors.cardBorderLight),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: const BoxDecoration(
                          color: InsumaColors.alertYellow,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.warning_amber_outlined,
                          color: Colors.orange,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              receta.nombre,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Colors.black87,
                              ),
                            ),
                            Text(
                              'Margen: ${(margenReal * 100).toStringAsFixed(1)}% (Deseado: ${(margenDeseado * 100).toStringAsFixed(0)}%)',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.redAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Costo/P: \$${costoPorPorcion.toStringAsFixed(2)} · Precio Carta: \$${(receta.precioVentaCarta ?? 0.0).toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
