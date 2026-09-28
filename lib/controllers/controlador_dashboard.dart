import 'dart:async';
import 'package:flutter/material.dart';
import 'package:drift/drift.dart' hide Column;
import '../database/database.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_gestion_equipo.dart';

/// Controlador encargado de gestionar el estado y la lógica de sesión
/// activa dentro del panel principal (Dashboard) de INSUMA (Patrón MVC).
class ControladorDashboard extends ChangeNotifier {
  final ServicioSesion sesion;
  final BaseDatosApp _db;
  final ServicioGestionEquipo? _gestionEquipo;

  ControladorDashboard(this.sesion, this._db, [this._gestionEquipo]);

  int _indiceSeleccionado = 0;
  String _nombreNegocio = 'Cargando...';
  String _nombreUsuarioActivo = 'Usuario';
  String _rolUsuarioActivo = 'cocinero';
  String _negocioId = '';
  List<Usuario> _usuariosNegocio = [];
  StreamSubscription<List<Usuario>>? _subEquipo; // HU-089: equipo reactivo
  bool _cargandoUsuarios = true;

  // Getters para exponer a la Vista
  int get indiceSeleccionado => _indiceSeleccionado;
  String get nombreNegocio => _nombreNegocio;
  String get nombreUsuarioActivo => _nombreUsuarioActivo;
  String get rolUsuarioActivo => _rolUsuarioActivo;
  String get negocioId => _negocioId;
  List<Usuario> get usuariosNegocio => _usuariosNegocio;
  bool get cargandoUsuarios => _cargandoUsuarios;

  void actualizarIndice(int indice) {
    _indiceSeleccionado = indice;
    notifyListeners();
  }

  /// Carga la información de la sesión activa desde la sesión y base de datos local.
  Future<void> cargarInfoNegocioYUsuario() async {
    final negocioId = sesion.negocioId;
    final usuarioActivoId = sesion.usuarioId;

    if (negocioId.isEmpty) return;

    // Buscar negocio
    final consultaNegocio = await (_db.select(
      _db.negocios,
    )..where((n) => n.id.equals(negocioId))).getSingleOrNull();

    // Buscar usuario activo
    final consultaUsuario = await (_db.select(
      _db.usuarios,
    )..where((u) => u.id.equals(usuarioActivoId))).getSingleOrNull();

    _negocioId = negocioId;
    _nombreNegocio = consultaNegocio?.nombre ?? 'Mi Cocina';
    if (sesion.esSuperAdmin) {
      // El SuperAdmin (HU-037) no está en la tabla usuarios local: al entrar a un
      // negocio actúa como admin EFECTIVO con acceso completo.
      _nombreUsuarioActivo = sesion.usuarioNombre.isNotEmpty
          ? sesion.usuarioNombre
          : 'SuperAdmin';
      _rolUsuarioActivo = 'admin';
    } else {
      _nombreUsuarioActivo = consultaUsuario?.nombre ?? 'Operador';
      _rolUsuarioActivo = consultaUsuario?.rol ?? 'cocinero';
    }
    // Foto inicial del equipo (datos ya locales al abrir): evita un frame en blanco. El
    // stream de abajo la mantiene al día cuando el pull deposita más filas.
    _usuariosNegocio =
        await (_db.select(_db.usuarios)..where(
              (u) => u.negocioId.equals(negocioId) & u.activo.equals(true),
            ))
            .get();
    _cargandoUsuarios = false;
    notifyListeners();

    // HU-089: el listado de equipo pasa a un STREAM reactivo, así se puebla SOLO cuando
    // el pull deposita las filas de los otros usuarios (aunque llegue después del primer
    // frame), sin necesidad de una mutación previa. Se re-suscribe con el negocio actual.
    final subAnterior = _subEquipo;
    _subEquipo =
        (_db.select(_db.usuarios)..where(
              (u) => u.negocioId.equals(negocioId) & u.activo.equals(true),
            ))
            .watch()
            .listen((usuarios) {
              _usuariosNegocio = usuarios;
              _cargandoUsuarios = false;
              notifyListeners();
            });
    await subAnterior?.cancel();
  }

  @override
  void dispose() {
    _subEquipo?.cancel();
    super.dispose();
  }

  /// Registra un nuevo miembro de equipo. Devuelve `null` si se creó, o un mensaje
  /// de error listo para mostrar.
  ///
  /// HU-077: ya NO se pide un PIN. HU-087: el alta dejó de ser local; ahora crea
  /// una cuenta Supabase Auth REAL (vía [ServicioGestionEquipo] → Edge Function),
  /// para que el miembro pueda iniciar sesión desde su propio teléfono. Requiere
  /// conexión y sesión activa; la seguridad (rol/negocio) se valida server-side.
  Future<String?> crearUsuario({
    required String nombre,
    required String rol,
    required String email,
    required String password,
  }) async {
    final gestion = _gestionEquipo;
    if (gestion == null) return 'La gestión de equipo no está disponible.';
    final error = await gestion.crearMiembro(
      DatosNuevoMiembro(
        nombre: nombre,
        email: email,
        password: password,
        rol: rol,
      ),
    );
    // HU-089: no se recarga a mano — crearMiembro espeja la fila localmente y el stream
    // del equipo la refleja al instante.
    return error;
  }

  /// Resetea la contraseña de un miembro del equipo (HU-076). Delega TODA la lógica
  /// en [ServicioGestionEquipo]: acá no se valida ni se autoriza nada (la autorización
  /// real es server-side, en la Edge Function).
  ///
  /// [passwordAdmin] es la contraseña del PROPIO admin, que reconfirma su identidad.
  /// Devuelve `null` si salió bien, o un mensaje de error listo para mostrar.
  Future<String?> resetearPassword({
    required String usuarioId,
    required String nuevaPassword,
    required String passwordAdmin,
  }) async {
    final gestion = _gestionEquipo;
    if (gestion == null) return 'La gestión de equipo no está disponible.';
    final error = await gestion.resetearPassword(
      usuarioId: usuarioId,
      nuevaPassword: nuevaPassword,
      passwordAdmin: passwordAdmin,
    );
    if (error == null) await cargarInfoNegocioYUsuario();
    return error;
  }

  /// Da de baja a un miembro del negocio (HU-076 Fase 3). Delega TODA la lógica al
  /// [ServicioGestionEquipo]: banear la cuenta Auth, revocar sesiones y marcar
  /// `activo=false` es negocio, no del controlador. Acá sólo se dispara y se refresca
  /// la lista. [passwordAdmin] reconfirma la identidad del admin (se verifica server-side).
  ///
  /// Devuelve `null` si salió bien, o un mensaje de error listo para mostrar.
  Future<String?> eliminarUsuario({
    required String usuarioId,
    required String passwordAdmin,
  }) async {
    final gestion = _gestionEquipo;
    if (gestion == null) {
      return ServicioGestionEquipo.mensajeSinConexionBaja;
    }
    final error = await gestion.darDeBajaMiembro(
      usuarioId: usuarioId,
      passwordAdmin: passwordAdmin,
    );
    if (error == null) await cargarInfoNegocioYUsuario();
    return error;
  }
}
