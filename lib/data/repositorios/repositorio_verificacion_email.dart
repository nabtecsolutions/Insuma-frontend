import 'package:supabase_flutter/supabase_flutter.dart';

/// Tipo de verificación por código enviado al email (HU-076 Fase 2).
///
/// REUTILIZABLE A PROPÓSITO: hoy sólo existe [recuperacionPassword], pero todo el
/// mecanismo de envío + verificación de código está parametrizado por este tipo para
/// que un flujo futuro (p. ej. CONFIRMACIÓN DE ALTA de cuenta) lo reaproveche entero.
/// Para sumar un tipo nuevo: agregá el valor acá, su `OtpType` en `_otpType`, y su
/// forma de envío en `enviarCodigo`. El resto (verificación, sesión efímera) no cambia.
enum TipoVerificacionEmail {
  /// "Olvidé mi contraseña": el código habilita a fijar una contraseña nueva.
  recuperacionPassword,
}

/// Falla de la verificación por email, con un código estable para que el service
/// traduzca a un mensaje. No lleva el texto crudo del backend (podría filtrar datos).
class ErrorVerificacionEmail implements Exception {
  /// `codigo_invalido` | `demasiados_intentos` | `sin_conexion` | `error`.
  final String codigo;
  const ErrorVerificacionEmail(this.codigo);

  @override
  String toString() => 'ErrorVerificacionEmail($codigo)';
}

/// Contrato del envío + verificación de códigos por email, usando el email
/// INTEGRADO de Supabase Auth (plantillas + envío propios de Supabase). Es
/// online-only por naturaleza: cada paso va y vuelve contra Supabase.
///
/// Se aísla detrás de esta interfaz para que la lógica de negocio
/// ([ServicioRecuperacionPassword]) sea testeable con un fake, sin tocar el
/// singleton `Supabase.instance`. Contrato SEPARADO de `RepositorioIdentidadRemota`
/// (responsabilidad única): esto no sabe de negocios, roles ni tenants.
abstract class RepositorioVerificacionEmail {
  /// Envía un código de verificación al [email] (email integrado de Supabase Auth).
  /// Por anti-enumeración, para [TipoVerificacionEmail.recuperacionPassword] NO revela
  /// si el correo existe: completa igual. Lanza [ErrorVerificacionEmail] sólo ante
  /// falla de RED o rate-limit (nunca "no existe").
  Future<void> enviarCodigo({
    required String email,
    required TipoVerificacionEmail tipo,
  });

  /// Verifica el [codigo] recibido. Si es válido, deja una SESIÓN de verificación
  /// activa en el cliente (efímera). Lanza [ErrorVerificacionEmail] si el código es
  /// inválido/expirado, hubo demasiados intentos, o no hay conexión.
  Future<void> verificarCodigo({
    required String email,
    required String codigo,
    required TipoVerificacionEmail tipo,
  });

  /// Cambia la contraseña del usuario de la sesión de verificación activa (requiere
  /// haber verificado un código primero). Lanza [ErrorVerificacionEmail] ante fallo.
  Future<void> actualizarPasswordSesionVerificada(String nuevaPassword);

  /// Cierra la sesión de verificación efímera (scope LOCAL: sólo esta, no todas las
  /// del usuario). Best-effort e idempotente: nunca debe hacer fallar el flujo.
  Future<void> cerrarSesionVerificacion();
}

class RepositorioVerificacionEmailSupabase
    implements RepositorioVerificacionEmail {
  final SupabaseClient _cliente;

  RepositorioVerificacionEmailSupabase(this._cliente);

  OtpType _otpType(TipoVerificacionEmail tipo) {
    switch (tipo) {
      case TipoVerificacionEmail.recuperacionPassword:
        return OtpType.recovery;
    }
  }

  @override
  Future<void> enviarCodigo({
    required String email,
    required TipoVerificacionEmail tipo,
  }) async {
    try {
      switch (tipo) {
        case TipoVerificacionEmail.recuperacionPassword:
          // Dispara el email de tipo "recovery". Para que traiga un CÓDIGO (y no sólo
          // un link) la plantilla de Supabase debe exponer `{{ .Token }}`.
          await _cliente.auth.resetPasswordForEmail(email);
      }
    } on AuthException catch (e) {
      throw ErrorVerificacionEmail(_clasificar(e));
    } catch (_) {
      throw const ErrorVerificacionEmail('sin_conexion');
    }
  }

  @override
  Future<void> verificarCodigo({
    required String email,
    required String codigo,
    required TipoVerificacionEmail tipo,
  }) async {
    try {
      await _cliente.auth.verifyOTP(
        email: email,
        token: codigo,
        type: _otpType(tipo),
      );
    } on AuthException catch (e) {
      throw ErrorVerificacionEmail(_clasificar(e));
    } catch (_) {
      throw const ErrorVerificacionEmail('sin_conexion');
    }
  }

  @override
  Future<void> actualizarPasswordSesionVerificada(String nuevaPassword) async {
    try {
      await _cliente.auth.updateUser(UserAttributes(password: nuevaPassword));
    } on AuthException catch (e) {
      throw ErrorVerificacionEmail(_clasificar(e));
    } catch (_) {
      throw const ErrorVerificacionEmail('sin_conexion');
    }
  }

  @override
  Future<void> cerrarSesionVerificacion() async {
    // Best-effort: si falla, el flujo ya cumplió; a lo sumo la sesión efímera expira
    // sola. Nunca propagar un error de acá (no es parte del resultado para el usuario).
    try {
      await _cliente.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
  }

  /// Clasifica una [AuthException] en un código estable. Mismo criterio que
  /// `RepositorioIdentidadRemota.autenticar`: red vs. rechazo vs. rate-limit.
  String _clasificar(AuthException e) {
    if (e is AuthRetryableFetchException) return 'sin_conexion';
    if (e.statusCode == '429') return 'demasiados_intentos';
    // 400/401/403: el código es inválido o expiró. (En el envío este caso casi no
    // ocurre; en la verificación es el error típico de "código equivocado".)
    if (e.statusCode == '400' ||
        e.statusCode == '401' ||
        e.statusCode == '403') {
      return 'codigo_invalido';
    }
    return 'error';
  }
}
