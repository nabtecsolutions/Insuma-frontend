import 'package:insuma/constants/politica_password.dart';
import '../data/repositorios/repositorio_verificacion_email.dart';
import '../utils/validador_datos.dart';

/// Servicio de RECUPERACIÓN de contraseña por el propio usuario (HU-076 Fase 2):
/// el autoservicio "olvidé mi contraseña" con un código numérico por email (ver
/// [ServicioRecuperacionPassword.digitosCodigo]).
///
/// Toda la entrega/verificación del código la hace el email integrado de Supabase
/// Auth (ver [RepositorioVerificacionEmail]); acá vive la lógica de negocio:
/// validaciones, política de contraseña, anti-enumeración y la ORQUESTACIÓN del
/// cambio (verificar → cambiar → cerrar la sesión efímera).
///
/// Online-only, como cualquier manejo de cuentas: sin backend configurado o sin
/// conexión, se avisa y no se hace nada a medias. No hay camino offline: la
/// contraseña vive en la nube.
///
/// Nota: NO invalida ni reescribe el hash local acá. Cuando el usuario vuelva a
/// entrar con la contraseña nueva, el login (ServicioAcceso) lo resuelve solo: el
/// check offline con la vieja falla, cae al backend que acepta la nueva, y ahí se
/// reescribe el hash. Por eso el PRIMER login tras recuperar es necesariamente online.
class ServicioRecuperacionPassword {
  final RepositorioVerificacionEmail? _verificacion;

  /// [verificacion] es null cuando no hay backend configurado (modo 100% offline):
  /// entonces la recuperación no está disponible y se avisa.
  ServicioRecuperacionPassword(this._verificacion);

  /// Misma política que el alta y el reset por admin (crear-miembro / HU-076 Fase 1).
  static const int minPassword = PoliticaPassword.longitudMinima;

  /// Cantidad de dígitos del código que llega por email (#97).
  ///
  /// El largo REAL lo define la plantilla de Supabase Auth, no este código: acá
  /// sólo se refleja para poder decírselo al usuario. Vive en una constante
  /// porque antes el número estaba escrito a mano en cinco lugares y decía 6
  /// cuando el código ya era de 8 — cinco textos mintiendo a la vez. Si la
  /// plantilla cambia, se toca ACÁ y nada más.
  static const int digitosCodigo = 8;

  static const String mensajeSinConexion =
      'Necesitás conexión para recuperar tu contraseña: la cuenta vive en la nube. '
      'Verificá tu internet y volvé a intentar.';

  /// Mensaje NEUTRO a propósito (anti-enumeración): se muestra siempre que el envío
  /// no falle por red, exista o no el correo. Así no se puede usar esta pantalla para
  /// averiguar qué emails tienen cuenta.
  static const String mensajeCodigoEnviado =
      'Si el correo corresponde a una cuenta, te enviamos un código de '
      '$digitosCodigo dígitos. Revisá tu bandeja de entrada (y la carpeta de spam).';

  /// Paso 1: pide el envío del código al [email]. Devuelve `null` si el envío salió
  /// bien (el llamador muestra [mensajeCodigoEnviado] y avanza al paso 2), o un
  /// mensaje de error listo para mostrar.
  Future<String?> solicitarCodigo(String email) async {
    final emailNormalizado = email.trim().toLowerCase();
    if (!ValidadorDatos.validarEmail(emailNormalizado)) {
      return 'Ingresá un correo electrónico con formato válido.';
    }

    final verificacion = _verificacion;
    if (verificacion == null) return mensajeSinConexion;

    try {
      await verificacion.enviarCodigo(
        email: emailNormalizado,
        tipo: TipoVerificacionEmail.recuperacionPassword,
      );
      return null;
    } on ErrorVerificacionEmail catch (e) {
      return _mensajeDeError(e.codigo);
    }
  }

  /// Paso 2: verifica el [codigo] y fija la [nuevaPassword]. Devuelve `null` si el
  /// cambio salió bien, o un mensaje de error listo para mostrar.
  Future<String?> confirmarCodigo({
    required String email,
    required String codigo,
    required String nuevaPassword,
    required String repetirPassword,
  }) async {
    final emailNormalizado = email.trim().toLowerCase();
    final codigoLimpio = codigo.trim();

    if (codigoLimpio.isEmpty) {
      return 'Ingresá el código que te enviamos por correo.';
    }
    if (nuevaPassword.length < minPassword) {
      return 'La contraseña debe tener al menos $minPassword caracteres.';
    }
    if (nuevaPassword != repetirPassword) {
      return 'Las contraseñas no coinciden.';
    }

    final verificacion = _verificacion;
    if (verificacion == null) return mensajeSinConexion;

    try {
      await verificacion.verificarCodigo(
        email: emailNormalizado,
        codigo: codigoLimpio,
        tipo: TipoVerificacionEmail.recuperacionPassword,
      );
      // El código validó y hay una sesión de verificación viva. El try/finally
      // garantiza que esa sesión efímera se cierre SIEMPRE, aunque el cambio de
      // contraseña falle a mitad (un corte de red no debe dejarla colgada).
      try {
        await verificacion.actualizarPasswordSesionVerificada(nuevaPassword);
      } finally {
        await verificacion.cerrarSesionVerificacion();
      }
      return null;
    } on ErrorVerificacionEmail catch (e) {
      return _mensajeDeError(e.codigo);
    }
  }

  String _mensajeDeError(String codigo) {
    switch (codigo) {
      case 'codigo_invalido':
        return 'El código es incorrecto o expiró. Pedí uno nuevo e intentá de nuevo.';
      case 'demasiados_intentos':
        return 'Demasiados intentos seguidos. Esperá un momento y volvé a probar.';
      case 'sin_conexion':
        return mensajeSinConexion;
      default:
        return 'No pudimos completar la operación. Intentá de nuevo en un momento.';
    }
  }
}
