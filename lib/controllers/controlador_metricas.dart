import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_permisos.dart';
import '../services/servicio_costos_receta.dart';

/// Controlador encargado de gestionar el estado y la lógica de negocio
/// del panel de Métricas y Rentabilidad de INSUMA (Patrón MVC).
class ControladorMetricas extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;

  /// HU-152: el margen se audita sobre el costo CON mano de obra. Sin esto, un
  /// plato de elaboración larga figuraba dentro de su margen deseado mientras
  /// las horas de cocina no las pagaba nadie.
  final ServicioCostosReceta _costos;

  ControladorMetricas(this.sesion, this._db, this._costos) {
    // Si cambia el rol efectivo (p. ej. una elevación por PIN de HU-043 o su
    // posterior re-bloqueo), recargamos para mostrar u ocultar la información
    // financiera según corresponda.
    sesion.addListener(_reaccionarAElevacion);
  }

  void _reaccionarAElevacion() {
    if (sesion.usuarioRol != _rolUsuario) cargarDatos();
  }

  @override
  void dispose() {
    sesion.removeListener(_reaccionarAElevacion);
    super.dispose();
  }

  bool _cargando = true;
  String _rolUsuario = 'cocinero';
  List<TypedResult> _alertasActivas = [];
  List<Receta> _recetas = [];

  // Almacena los costos calculados para las recetas vigentes
  final Map<String, CostoRecetaDesglosado> _costosRecetas = {};

  // Getters para exponer a la Vista
  bool get cargando => _cargando;
  String get rolUsuario => _rolUsuario;
  List<TypedResult> get alertasActivas => _alertasActivas;
  List<Receta> get recetas => _recetas;
  Map<String, CostoRecetaDesglosado> get costosRecetas => _costosRecetas;

  /// Retorna la lista de recetas que se encuentran por debajo de su margen deseado.
  List<Map<String, dynamic>> get recetasBajoMargen {
    final List<Map<String, dynamic>> bajoMargen = [];
    for (final r in _recetas) {
      final costoObj = _costosRecetas[r.id];
      if (costoObj == null) continue;
      final costoP = costoObj.costoPorPorcion;
      final precioCarta = r.precioVentaCarta ?? 0.0;
      final margenDeseado = r.margenDeseadoPorcentaje ?? 0.30;

      double margenReal = 0.0;
      if (precioCarta > 0) {
        margenReal = (precioCarta - costoP) / precioCarta;
      }

      if (precioCarta > 0 && margenReal < margenDeseado) {
        bajoMargen.add({
          'receta': r,
          'costoPorPorcion': costoP,
          'margenReal': margenReal,
          'margenDeseado': margenDeseado,
        });
      }
    }
    return bajoMargen;
  }

  /// Carga la sesión del usuario, consulta alertas activas de desviación
  /// y calcula el costo actual de cada receta para auditar márgenes.
  Future<void> cargarDatos() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) return;

    final rolUsuario = sesion.usuarioRol;

    // No cargar datos económicos si el rol no tiene permiso (defensa en la capa de datos).
    if (!Permisos.puede(rolUsuario, Permiso.verFinanzas)) {
      _rolUsuario = rolUsuario;
      _cargando = false;
      notifyListeners();
      return;
    }

    // 1. Obtener alertas no resueltas haciendo JOIN con Insumos
    final consultaAlertas =
        await (_db.select(_db.alertasDesviacion).join([
              innerJoin(
                _db.insumos,
                _db.insumos.id.equalsExp(_db.alertasDesviacion.insumoId),
              ),
            ])..where(
              _db.alertasDesviacion.resuelta.equals(false) &
                  _db.insumos.negocioId.equals(negocioId),
            ))
            .get();

    // 2. Obtener recetas activas (no archivadas) para auditar márgenes
    final listaRecetas =
        await (_db.select(_db.recetas)..where(
              (r) => r.negocioId.equals(negocioId) & r.archivada.equals(false),
            ))
            .get();

    _costosRecetas.clear();
    final hoy = DateTime.now();
    for (final receta in listaRecetas) {
      final costoObj = await _costos.desglosar(receta, fecha: hoy);
      _costosRecetas[receta.id] = costoObj;
    }

    _rolUsuario = rolUsuario;
    _alertasActivas = consultaAlertas;
    _recetas = listaRecetas;
    _cargando = false;
    notifyListeners();
  }

  /// Resuelve una alerta de desviación de precio.
  Future<void> resolverAlerta(String alertaId) async {
    await (_db.update(_db.alertasDesviacion)
          ..where((a) => a.id.equals(alertaId)))
        .write(const AlertasDesviacionCompanion(resuelta: Value(true)));
    await cargarDatos();
  }
}
