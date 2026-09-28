import 'package:flutter/material.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_categorias.dart';

/// Controlador (MVC) de la pantalla de administración de CATEGORÍAS de insumo
/// (rediseño insumos-por-categoría). NO contiene lógica de negocio: delega en
/// [ServicioCategorias] y solo gestiona el estado de la vista (lista, carga,
/// alternar inactivas). Espeja 1:1 a [ControladorMotivosRecepcion] (HU-065).
class ControladorCategorias extends ChangeNotifier {
  final ServicioSesion sesion;
  final ServicioCategorias _servicio;

  ControladorCategorias(this.sesion, this._servicio);

  List<Categoria> _categorias = [];
  bool _cargando = true;
  bool _verInactivas = false;

  List<Categoria> get categorias => _categorias;
  bool get cargando => _cargando;
  bool get verInactivas => _verInactivas;

  /// Carga las categorías del negocio en sesión (incluye inactivas si el toggle).
  Future<void> cargar() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) {
      _categorias = [];
      _cargando = false;
      notifyListeners();
      return;
    }
    _cargando = true;
    notifyListeners();
    _categorias = await _servicio.listar(
      negocioId,
      incluirInactivos: _verInactivas,
    );
    _cargando = false;
    notifyListeners();
  }

  /// Alterna entre ver solo activas y ver también las desactivadas (para reactivar).
  void alternarVerInactivas() {
    _verInactivas = !_verInactivas;
    cargar();
  }

  /// Crea una categoría. Devuelve `null` si fue OK, o el mensaje de error para la UI.
  Future<String?> crear(String nombre) async {
    final r = await _servicio.crear(sesion.negocioId, nombre);
    if (r.esOk) {
      await cargar();
      return null;
    }
    return r.error;
  }

  /// Renombra una categoría. Devuelve `null` si fue OK, o el mensaje de error.
  Future<String?> renombrar(String id, String nombre) async {
    final r = await _servicio.renombrar(sesion.negocioId, id, nombre);
    if (r.esOk) {
      await cargar();
      return null;
    }
    return r.error;
  }

  /// Activa o desactiva (soft-delete) una categoría y refresca la lista.
  Future<void> cambiarEstado(String id, bool activo) async {
    await _servicio.cambiarEstado(id, activo);
    await cargar();
  }
}
