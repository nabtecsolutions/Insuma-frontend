import 'package:flutter/material.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_proveedor_categorias.dart';

/// Controlador (MVC) de la sección "Categorías que suministra" de la ficha del
/// proveedor (#262). NO contiene lógica de negocio: delega en
/// [ServicioProveedorCategorias] y sólo gestiona el estado de la vista (las
/// categorías suministradas, las disponibles para agregar, la carga).
///
/// Se instancia por proveedor: [cargar] fija el proveedor en foco y refresca.
class ControladorProveedorCategorias extends ChangeNotifier {
  final ServicioSesion sesion;
  final ServicioProveedorCategorias _servicio;

  ControladorProveedorCategorias(this.sesion, this._servicio);

  String? _proveedorId;
  List<Categoria> _suministradas = [];
  List<Categoria> _disponibles = [];
  bool _cargando = true;

  /// Categorías que hoy suministra el proveedor en foco (activas, por nombre).
  List<Categoria> get suministradas => _suministradas;

  /// Categorías del negocio que el proveedor todavía no suministra (candidatas).
  List<Categoria> get disponibles => _disponibles;

  bool get cargando => _cargando;

  /// Fija el proveedor en foco y carga sus categorías suministradas + las
  /// disponibles para agregar.
  Future<void> cargar(String proveedorId) async {
    _proveedorId = proveedorId;
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) {
      _suministradas = [];
      _disponibles = [];
      _cargando = false;
      notifyListeners();
      return;
    }
    _cargando = true;
    notifyListeners();
    _suministradas = await _servicio.categoriasDe(negocioId, proveedorId);
    _disponibles = await _servicio.disponiblesPara(negocioId, proveedorId);
    _cargando = false;
    notifyListeners();
  }

  /// Asigna una categoría al proveedor en foco y refresca.
  Future<void> asignar(String categoriaId) async {
    final proveedorId = _proveedorId;
    if (proveedorId == null) return;
    await _servicio.asignar(
      negocioId: sesion.negocioId,
      proveedorId: proveedorId,
      categoriaId: categoriaId,
    );
    await cargar(proveedorId);
  }

  /// Da de baja (lógica) una categoría del proveedor en foco y refresca.
  Future<void> desasignar(String categoriaId) async {
    final proveedorId = _proveedorId;
    if (proveedorId == null) return;
    await _servicio.desasignar(
      proveedorId: proveedorId,
      categoriaId: categoriaId,
    );
    await cargar(proveedorId);
  }
}
