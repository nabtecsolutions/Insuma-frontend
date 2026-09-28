import 'package:flutter/material.dart';
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_motivos_recepcion.dart';

/// Controlador (MVC) de la pantalla de administración de motivos de recepción
/// (HU-065). NO contiene lógica de negocio: delega en [ServicioMotivosRecepcion]
/// y solo gestiona el estado de la vista (lista, carga, alternar inactivos).
class ControladorMotivosRecepcion extends ChangeNotifier {
  final ServicioSesion sesion;
  final ServicioMotivosRecepcion _servicio;

  ControladorMotivosRecepcion(this.sesion, this._servicio);

  List<MotivosRecepcionData> _motivos = [];
  bool _cargando = true;
  bool _verInactivos = false;

  List<MotivosRecepcionData> get motivos => _motivos;
  bool get cargando => _cargando;
  bool get verInactivos => _verInactivos;

  /// Carga los motivos del negocio en sesión (incluye inactivos si está el toggle).
  Future<void> cargar() async {
    final negocioId = sesion.negocioId;
    if (negocioId.isEmpty) {
      _motivos = [];
      _cargando = false;
      notifyListeners();
      return;
    }
    _cargando = true;
    notifyListeners();
    _motivos = await _servicio.listar(
      negocioId,
      incluirInactivos: _verInactivos,
    );
    _cargando = false;
    notifyListeners();
  }

  /// Alterna entre ver solo activos y ver también los desactivados (para reactivar).
  void alternarVerInactivos() {
    _verInactivos = !_verInactivos;
    cargar();
  }

  /// Crea un motivo. Devuelve `null` si fue OK, o el mensaje de error para la UI.
  Future<String?> crear(String nombre) async {
    final r = await _servicio.crear(sesion.negocioId, nombre);
    if (r.esOk) {
      await cargar();
      return null;
    }
    return r.error;
  }

  /// Renombra un motivo. Devuelve `null` si fue OK, o el mensaje de error.
  Future<String?> renombrar(String id, String nombre) async {
    final r = await _servicio.renombrar(sesion.negocioId, id, nombre);
    if (r.esOk) {
      await cargar();
      return null;
    }
    return r.error;
  }

  /// Activa o desactiva (soft-delete) un motivo y refresca la lista.
  Future<void> cambiarEstado(String id, bool activo) async {
    await _servicio.cambiarEstado(id, activo);
    await cargar();
  }
}
