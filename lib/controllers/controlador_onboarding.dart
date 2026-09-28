import 'package:flutter/material.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_acceso.dart';
import '../services/servicio_activacion.dart';
import '../services/servicio_registro_negocio.dart';

/// Controlador de Onboarding e Inicio de Sesión de INSUMA (Patrón MVC).
///
/// No contiene lógica de negocio: sólo estado de los formularios y delegación.
/// El LOGIN vive en [ServicioAcceso] (HU-072); el ALTA DE NEGOCIO y la validación
/// del código de activación viven en [ServicioRegistroNegocio] y
/// [ServicioActivacion] (HU-075).
class ControladorOnboarding extends ChangeNotifier {
  final ServicioSesion sesion;
  final ServicioAcceso _acceso;
  final ServicioRegistroNegocio _registro;

  /// Null si no hay backend configurado: sin él no se puede validar el código y,
  /// por lo tanto, no se puede crear un negocio (HU-075).
  final ServicioActivacion? _activacion;

  ControladorOnboarding(
    this.sesion,
    this._acceso,
    this._registro, [
    this._activacion,
  ]);

  int _pasoActual = 1;
  final int totalPasos = 6;

  // Estado del flujo de creación de negocio (Onboarding)
  String _nombreNegocio = '';
  String _tipoNegocio = ''; // restaurante, local, delivery, otro
  String _codigoInvitacion = '';
  String _email = '';
  String _password = '';
  String _confirmarPassword = '';
  String _nombreAdmin = ''; // Nombre del administrador principal
  String _planSeleccionado = 'gratuito'; // gratuito, profesional
  final List<Map<String, dynamic>> _usuariosEquipo =
      []; // {nombre, rol, email, password}

  // Estado del flujo de Iniciar Sesión (Login).
  // HU-127: login-first — la vista inicial sin sesión es INICIAR SESIÓN (el caso
  // mayoritario, usuario existente que vuelve); crear cuenta/negocio es la
  // segunda opción, accesible desde el CTA del login.
  bool _mostrarLogin = true;
  String _loginEmail = '';
  String _loginPassword = '';
  bool _loginCargando = false;
  String? _loginError;

  // Estado de la validación del código de activación (paso 3, HU-075)
  bool _validandoCodigo = false;
  String? _codigoError;

  // Controles de estados de carga
  bool _cargando = false;
  String? _errorActual;

  // Miembros que el backend rechazó durante el alta (HU-088). El negocio SÍ se creó:
  // es un aviso, no un error, y el admin puede darlos de alta desde Gestionar Equipo.
  List<String> _avisoMiembrosNoCreados = const [];

  // Getters para exponer el estado a la Vista (View)
  int get pasoActual => _pasoActual;
  String get nombreNegocio => _nombreNegocio;
  String get tipoNegocio => _tipoNegocio;
  String get codigoInvitacion => _codigoInvitacion;
  String get email => _email;
  String get password => _password;
  String get confirmarPassword => _confirmarPassword;
  String get nombreAdmin => _nombreAdmin;
  String get planSeleccionado => _planSeleccionado;
  List<Map<String, dynamic>> get usuariosEquipo => _usuariosEquipo;

  /// Miembros que no se pudieron crear en la nube durante el alta (HU-088). Vacío
  /// si salieron todos. La vista lo muestra como aviso, no como error.
  List<String> get avisoMiembrosNoCreados => _avisoMiembrosNoCreados;

  bool get mostrarLogin => _mostrarLogin;
  String get loginEmail => _loginEmail;
  String get loginPassword => _loginPassword;
  bool get loginCargando => _loginCargando;
  String? get loginError => _loginError;

  /// Validación del código de activación en curso (paso 3, HU-075).
  bool get validandoCodigo => _validandoCodigo;

  /// Mensaje de error del código de activación (inválido, vencido, sin conexión…).
  String? get codigoError => _codigoError;

  bool get cargando => _cargando;
  String? get errorActual => _errorActual;

  // ─── MÉTODOS DE ACTUALIZACIÓN DE ESTADO ─────────────────────────────────────

  void actualizarPaso(int paso) {
    if (paso >= 1 && paso <= totalPasos) {
      _pasoActual = paso;
      _errorActual = null;
      notifyListeners();
    }
  }

  void actualizarNombreNegocio(String valor) {
    _nombreNegocio = valor;
    notifyListeners();
  }

  void actualizarTipoNegocio(String valor) {
    _tipoNegocio = valor;
    notifyListeners();
  }

  void actualizarCodigoInvitacion(String valor) {
    _codigoInvitacion = valor;
    _codigoError =
        null; // al tipear se limpia el error de la validación anterior
    notifyListeners();
  }

  void actualizarEmail(String valor) {
    _email = valor;
    notifyListeners();
  }

  void actualizarPassword(String valor) {
    _password = valor;
    notifyListeners();
  }

  void actualizarConfirmarPassword(String valor) {
    _confirmarPassword = valor;
    notifyListeners();
  }

  void actualizarNombreAdmin(String valor) {
    _nombreAdmin = valor;
    notifyListeners();
  }

  void actualizarPlanSeleccionado(String valor) {
    _planSeleccionado = valor;
    notifyListeners();
  }

  void actualizarLoginEmail(String valor) {
    _loginEmail = valor;
    notifyListeners();
  }

  void actualizarLoginPassword(String valor) {
    _loginPassword = valor;
    notifyListeners();
  }

  void conmutarMostrarLogin() {
    _mostrarLogin = !_mostrarLogin;
    _loginError = null;
    _errorActual = null;
    notifyListeners();
  }

  void agregarUsuarioEquipo(
    String nombre,
    String rol,
    String email,
    String password,
  ) {
    _usuariosEquipo.add({
      'nombre': nombre,
      'rol': rol,
      'email': email,
      'password': password,
    });
    _errorActual = null;
    notifyListeners();
  }

  void eliminarUsuarioEquipo(int indice) {
    if (indice >= 0 && indice < _usuariosEquipo.length) {
      _usuariosEquipo.removeAt(indice);
      notifyListeners();
    }
  }

  // ─── DELEGACIÓN EN LA CAPA DE SERVICIOS ─────────────────────────────────────

  /// Valida contra el backend el código de activación del paso 3 (HU-075).
  ///
  /// Devuelve true si el código sirve. Sin backend o sin conexión NO se puede
  /// validar y, por lo tanto, no se puede crear un negocio: se muestra el error
  /// de conectividad. El consumo real del código es atómico y ocurre en el alta.
  Future<bool> validarCodigoActivacion() async {
    final activacion = _activacion;
    _validandoCodigo = true;
    _codigoError = null;
    notifyListeners();

    final error = activacion == null
        ? ServicioActivacion.mensajeSinConexion
        : await activacion.validar(_codigoInvitacion);

    _validandoCodigo = false;
    _codigoError = error;
    notifyListeners();
    return error == null;
  }

  /// Da de alta el negocio delegando TODA la lógica en [ServicioRegistroNegocio].
  /// Acá sólo se maneja el estado de la vista (cargando / error) y la navegación.
  Future<bool> finalizarOnboarding(VoidCallback alCompletar) async {
    _cargando = true;
    _errorActual = null;
    notifyListeners();

    final resultado = await _registro.registrar(
      DatosRegistroNegocio(
        nombreNegocio: _nombreNegocio,
        tipoNegocio: _tipoNegocio,
        email: _email,
        password: _password,
        nombreAdmin: _nombreAdmin,
        codigoActivacion: _codigoInvitacion,
        usuariosEquipo: _usuariosEquipo,
      ),
    );

    _cargando = false;
    _errorActual = resultado.error;
    // El negocio se creó, pero algún miembro no (HU-088): NO es un error de alta —
    // se entra a la app igual y se avisa, porque la cuenta del admin ya existe y
    // dejarlo trabado en el onboarding sería peor.
    _avisoMiembrosNoCreados = resultado.miembrosNoCreados;
    notifyListeners();

    if (!resultado.exitoso) return false;
    alCompletar();
    return true;
  }

  /// Procesa el inicio de sesión delegando TODA la lógica en [ServicioAcceso]
  /// (HU-072). Acá sólo se maneja el estado de la vista (cargando / error) y el
  /// callback de navegación.
  Future<bool> procesarLogin(VoidCallback alCompletar) async {
    _loginCargando = true;
    _loginError = null;
    notifyListeners();

    final error = await _acceso.iniciarSesion(
      email: _loginEmail,
      password: _loginPassword,
    );

    _loginCargando = false;
    _loginError = error;
    notifyListeners();

    if (error != null) return false;
    alCompletar();
    return true;
  }
}
