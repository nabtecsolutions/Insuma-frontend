import 'package:supabase_flutter/supabase_flutter.dart';
import '../../services/servicio_permisos.dart';

/// Motivo por el que falló `autenticar` (HU-076).
///
/// Deja que la lógica de acceso distinga un RECHAZO real de credenciales —la
/// contraseña ya no sirve, p. ej. fue reseteada— de una falla de RED. Es la base de
/// la invalidación post-reset: si el hash local valida pero el backend rechaza esa
/// misma contraseña ESTANDO ONLINE, es señal de que la credencial cambió.
enum MotivoFallaAuth {
  /// El backend rechazó las credenciales (HTTP 400). La contraseña es incorrecta.
  credencialRechazada,

  /// La cuenta fue DADA DE BAJA (baneada en Auth, HU-076 Fase 3). Se detecta por el
  /// `code == 'user_banned'`, no por el status HTTP (que puede variar). Se trata igual
  /// que un rechazo de credenciales para efectos del login: se niega el acceso y se
  /// invalida el hash local, de modo que tampoco pueda entrar offline en su dispositivo.
  cuentaDeshabilitada,

  /// No se pudo determinar (red caída, timeout, rate-limit 429, 5xx). Ante la duda
  /// NO se invalida nada: la app sigue siendo usable offline.
  red,
}

/// Falla de `autenticar` con su motivo ya clasificado (HU-076).
class ErrorAutenticacion implements Exception {
  final MotivoFallaAuth motivo;
  const ErrorAutenticacion(this.motivo);
  @override
  String toString() => 'ErrorAutenticacion($motivo)';
}

/// Identidad devuelta por el backend de autenticación (Supabase Auth).
class SesionRemota {
  final String usuarioId;
  final String? email;

  /// Rol GLOBAL que viaja en `app_metadata` (p. ej. 'superadmin'). No es editable
  /// por el usuario, a diferencia del rol de la tabla `usuarios`.
  final String? rolGlobal;

  const SesionRemota({required this.usuarioId, this.email, this.rolGlobal});
}

/// Identidad AUTORITATIVA de un usuario según la tabla remota `usuarios`.
class UsuarioRemoto {
  final String usuarioId;
  final String negocioId;
  final String rol;

  /// Estado autoritativo de la cuenta en la tabla `usuarios` (HU-071). Si el backend
  /// la deshabilitó (`activo = false`), el login se rechaza aunque la copia LOCAL siga
  /// activa. Default `true` para no bloquear ante un valor ausente.
  final bool activo;

  /// Cuenta de Supabase Auth del usuario (HU-087). Null en los miembros HEREDADOS:
  /// los dados de alta antes de HU-087, que sólo tienen hash local y no pueden
  /// loguear en otro dispositivo. HU-088 los provisiona a demanda (backfill lazy).
  final String? authUserId;

  const UsuarioRemoto({
    required this.usuarioId,
    required this.negocioId,
    required this.rol,
    this.activo = true,
    this.authUserId,
  });
}

/// Datos de un negocio remoto, para espejarlo en la base local.
class NegocioRemoto {
  final String nombre;
  final String tipo;
  final String? email;
  const NegocioRemoto({required this.nombre, required this.tipo, this.email});
}

/// Miembro provisionado en la nube por la Edge Function `crear-miembro` (HU-087).
/// El `id`/`negocioId`/`rol` son los AUTORITATIVOS que devolvió el backend (el
/// negocio y el rol se fuerzan/validan server-side).
class MiembroNube {
  final String id;
  final String negocioId;
  final String nombre;
  final String rol;
  final String email;
  final String authUserId;
  const MiembroNube({
    required this.id,
    required this.negocioId,
    required this.nombre,
    required this.rol,
    required this.email,
    required this.authUserId,
  });
}

/// Falla del alta de miembro en la nube. [codigo] es el identificador estable que
/// devuelve la Edge Function (p. ej. `email_en_uso`, `no_autorizado`) o
/// `sin_conexion` si ni siquiera se pudo llegar al backend; el Service lo traduce.
class ErrorCrearMiembro implements Exception {
  final String codigo;
  const ErrorCrearMiembro(this.codigo);
  @override
  String toString() => 'ErrorCrearMiembro($codigo)';
}

/// Falla del reset de contraseña (HU-076). Tipo propio y no reutilización de
/// [ErrorCrearMiembro] porque los modos de falla son OTROS: la contraseña del admin
/// puede ser incorrecta, el objetivo puede no pertenecer al negocio, puede haber
/// demasiados intentos. [codigo] es el identificador estable de la Edge Function
/// `resetear-password` (o `sin_conexion` si no se llegó al backend).
class ErrorResetPassword implements Exception {
  final String codigo;
  const ErrorResetPassword(this.codigo);
  @override
  String toString() => 'ErrorResetPassword($codigo)';
}

/// Falla de la baja/reactivación de un miembro (HU-076 Fase 3). [codigo] es el
/// identificador estable de la Edge Function `dar-de-baja-usuario` (p. ej.
/// `no_puede_a_si_mismo`, `ultimo_admin`, `password_admin_incorrecta`) o
/// `sin_conexion` si no se llegó al backend; el Service lo traduce a un mensaje.
class ErrorBajaMiembro implements Exception {
  final String codigo;
  const ErrorBajaMiembro(this.codigo);
  @override
  String toString() => 'ErrorBajaMiembro($codigo)';
}

/// Resultado de la baja/reactivación (HU-076 Fase 3).
class BajaMiembroNube {
  /// Estado en el que quedó el miembro (`false` = dado de baja, `true` = reactivado).
  final bool activo;

  /// Filas de sesión revocadas al banear. `null` = no se pudo revocar (o no aplica,
  /// p. ej. en la reactivación). Ver la nota de la Fase 1 sobre 0 vs null.
  final int? sesionesRevocadas;

  const BajaMiembroNube({required this.activo, this.sesionesRevocadas});
}

/// Resultado del reset (HU-076): si se pudieron matar las sesiones vigentes del
/// miembro. La invalidación del hash local NO se transporta desde acá: la dispara el
/// propio login del miembro cuando el backend rechaza su contraseña vieja.
class ResetPasswordNube {
  /// Cantidad de filas (refresh tokens + sesiones) que el backend borró de verdad.
  /// `null` = **no se pudo revocar**, que NO es lo mismo que `0` ("no tenía sesiones
  /// abiertas"). Antes esto era un `bool` calculado como "no hubo error", y eso
  /// producía falsos verdes: la app decía "listo" con la sesión del miembro intacta.
  final int? sesionesRevocadas;

  /// Mensaje crudo del backend si la revocación falló. `null` si salió bien.
  final String? errorRevocacion;

  const ResetPasswordNube({
    required this.sesionesRevocadas,
    this.errorRevocacion,
  });

  /// Construye el resultado desde el objeto `usuario` que devuelve la Edge Function.
  /// Parseo tolerante A PROPÓSITO: si llegó este objeto es porque la EF respondió 200 y
  /// el reset YA se aplicó server-side; entonces un campo `sesiones_revocadas` con un
  /// tipo inesperado NUNCA debe hacer reventar el parseo (un `as int` duro lanzaría, y
  /// el `catch` de arriba lo degradaría a un falso "sin conexión", mintiéndole al admin
  /// que no pasó nada cuando la contraseña sí cambió).
  ///
  /// Reglas:
  /// - `num` (incluye el `double` 2.0 que puede venir del JSON) ⇒ su valor entero.
  /// - `bool` (contrato viejo, por deploy skew EF-vieja + app-nueva): `true` ⇒ 1
  ///   (se revocó), cualquier otro ⇒ `null` (fallida). Interpretación conservadora.
  /// - ausente / `null` / cualquier otro tipo ⇒ `null` = revocación fallida.
  factory ResetPasswordNube.desdeUsuario(Map<dynamic, dynamic> usuario) {
    final crudo = usuario['sesiones_revocadas'];
    final int? sesiones = crudo is num
        ? crudo.toInt()
        : (crudo == true ? 1 : null);
    return ResetPasswordNube(
      sesionesRevocadas: sesiones,
      errorRevocacion: usuario['error_revocacion'] as String?,
    );
  }

  /// La contraseña cambió, pero el miembro CONSERVA sus sesiones vigentes: sigue
  /// pudiendo operar hasta que expire su token. El admin tiene que enterarse.
  bool get revocacionFallida => sesionesRevocadas == null;
}

/// Contrato del backend de identidad (Supabase Auth + tablas remotas), HU-072.
///
/// Aísla el singleton `Supabase.instance` detrás de una interfaz para que la
/// lógica de acceso ([ServicioAcceso]) sea testeable con una implementación falsa.
/// Cuando no hay backend configurado, simplemente no se construye (es nullable
/// en el servicio) y la app opera 100% offline.
abstract class RepositorioIdentidadRemota {
  /// Hay una sesión de Supabase Auth activa en este dispositivo.
  bool get haySesion;

  /// `auth.uid()` de la sesión de Supabase Auth activa, o null si no hay sesión.
  ///
  /// Es la identidad GLOBAL y ÚNICA del usuario (a diferencia del email, que es
  /// único sólo POR NEGOCIO). La lógica de acceso la usa para resolver al usuario
  /// remoto por [usuarioPorAuthId] en vez de por email (HU-095).
  String? get authUserIdActual;

  /// Email de la sesión de Supabase Auth activa, o null si no hay sesión.
  ///
  /// HU-095: la lógica de acceso lo usa para no reutilizar una sesión RESIDUAL de
  /// OTRO usuario (p. ej. un logout interrumpido) al entrar por hash local: si la
  /// sesión no es de quien está iniciando, resolver la identidad remota traería la
  /// fila del dueño de la sesión, no la del que entra.
  String? get emailSesionActual;

  /// Autentica contra el backend. Devuelve la identidad, o `null` si no autenticó.
  Future<SesionRemota?> autenticar({
    required String email,
    required String password,
  });

  /// Da de alta la cuenta en el backend (HU-075). [metadata] viaja como
  /// `raw_user_meta_data`: el trigger `handle_new_user` provisiona negocio +
  /// usuario admin + configuración, y `enforce_codigo_activacion` consume el
  /// código de activación en la MISMA transacción. Si el código no es válido, el
  /// alta completa se aborta y este método lanza.
  Future<void> registrarCuenta({
    required String email,
    required String password,
    required Map<String, dynamic> metadata,
  });

  /// Cierra la sesión de Supabase Auth (invalida el JWT). HU-071: se usa al rechazar
  /// a un usuario deshabilitado en el backend, para no dejar una sesión válida.
  Future<void> cerrarSesion();

  /// Identidad autoritativa del usuario en la tabla remota `usuarios`, resuelta
  /// por su cuenta de Supabase Auth (`auth.uid()` → `usuarios.auth_user_id`).
  ///
  /// HU-095: reemplaza a `usuarioPorEmail`. El email NO es único entre negocios
  /// (`UNIQUE(negocio_id, email)`), así que resolver por email con `.maybeSingle()`
  /// LANZABA cuando el mismo email vivía en dos negocios, y esa excepción se
  /// degradaba a "offline" → se salteaba el chequeo de `activo` (fail-open, HU-071).
  /// `auth_user_id` es único (índice parcial, HU-087), así que devuelve a lo sumo
  /// UNA fila: determinista y sin ambigüedad. Espeja la identidad server-side de
  /// HU-109 (RLS por `auth_user_id`).
  Future<UsuarioRemoto?> usuarioPorAuthId(String authUserId);

  /// Datos del negocio remoto, para espejarlo localmente.
  Future<NegocioRemoto?> negocioPorId(String id);

  /// Da de alta un MIEMBRO de equipo con cuenta Supabase Auth real (HU-087),
  /// vía la Edge Function `crear-miembro` (service_role). El backend deriva el
  /// admin del JWT, fuerza el `negocio_id` y valida el `rol`; acá sólo se pasa el
  /// payload. Requiere una sesión de Supabase activa (el JWT viaja en la llamada).
  /// Lanza [ErrorCrearMiembro] con un código estable ante cualquier rechazo.
  /// [negocioId] es el negocio activo (de [ServicioSesion]). El backend lo usa
  /// SÓLO si el caller es superadmin (#257), validándolo contra `negocios`; para
  /// un admin lo ignora y fuerza su propio negocio (no se reabre C1/HU-078).
  Future<MiembroNube> crearMiembroEnNube({
    required String email,
    required String password,
    required String nombre,
    required String rol,
    required String negocioId,
  });

  /// Resetea la contraseña de un miembro (HU-076), vía la Edge Function
  /// `resetear-password` (service_role).
  ///
  /// El payload es MÍNIMO a propósito: cada dato autoritativo (que el caller sea
  /// admin, el negocio del objetivo, su rol) lo re-deriva el servidor desde el JWT y
  /// la base. [passwordAdmin] es la contraseña del PROPIO admin: la reconfirmación se
  /// verifica server-side, porque hacerla en el cliente sería evitable con un `curl`.
  ///
  /// Si el miembro es HEREDADO (sin cuenta Auth), el backend se la crea en el mismo
  /// acto. Lanza [ErrorResetPassword] con un código estable ante cualquier rechazo.
  /// [negocioId] (negocio activo): igual que en [crearMiembroEnNube], el backend
  /// lo usa sólo para el superadmin (#257).
  Future<ResetPasswordNube> resetearPasswordEnNube({
    required String usuarioId,
    required String password,
    required String passwordAdmin,
    required String negocioId,
  });

  /// Da de baja ([activar] = false) o reactiva ([activar] = true) a un miembro
  /// (HU-076 Fase 3), vía la Edge Function `dar-de-baja-usuario` (service_role).
  ///
  /// La baja BANEA la cuenta Auth y revoca sus sesiones; la reactivación levanta el
  /// ban. Todo lo autoritativo (que el caller sea admin, el negocio del objetivo, que
  /// no se auto-baje ni deje al negocio sin admin) lo resuelve el servidor. El
  /// parámetro [activar] es la costura de reúso para la futura UI de reactivación.
  /// Lanza [ErrorBajaMiembro] con un código estable ante cualquier rechazo.
  /// [negocioId] (negocio activo): igual que en [crearMiembroEnNube], el backend
  /// lo usa sólo para el superadmin (#257).
  Future<BajaMiembroNube> cambiarEstadoMiembroEnNube({
    required String usuarioId,
    required bool activar,
    required String passwordAdmin,
    required String negocioId,
  });
}

class RepositorioIdentidadRemotaSupabase implements RepositorioIdentidadRemota {
  final SupabaseClient _cliente;

  RepositorioIdentidadRemotaSupabase(this._cliente);

  @override
  bool get haySesion => _cliente.auth.currentSession != null;

  @override
  String? get authUserIdActual => _cliente.auth.currentUser?.id;

  @override
  String? get emailSesionActual => _cliente.auth.currentUser?.email;

  @override
  Future<SesionRemota?> autenticar({
    required String email,
    required String password,
  }) async {
    try {
      final respuesta = await _cliente.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final usuario = respuesta.user;
      if (usuario == null) return null;
      return SesionRemota(
        usuarioId: usuario.id,
        email: usuario.email,
        rolGlobal: usuario.appMetadata['role']?.toString(),
      );
    } on AuthException catch (e) {
      // Clasifica la falla para que la lógica de acceso pueda distinguir "contraseña
      // ya no sirve" de "no hay red". Un rechazo de credenciales es HTTP 400; una
      // falla de red es AuthRetryableFetchException. Todo lo demás (429, 5xx,
      // desconocido) se trata como red: ante la duda, NO se invalida la credencial.
      if (e is AuthRetryableFetchException) {
        throw const ErrorAutenticacion(MotivoFallaAuth.red);
      }
      // Cuenta baneada (dada de baja, HU-076 Fase 3): se detecta por el `code` estable,
      // NO por el status HTTP (que GoTrue puede devolver como 400/403). La expulsión de
      // un usuario dado de baja depende de clasificar esto bien: si cayera en `red`, el
      // login offline-first lo dejaría entrar con su hash local viejo.
      if (e.code == 'user_banned') {
        throw const ErrorAutenticacion(MotivoFallaAuth.cuentaDeshabilitada);
      }
      if (e.statusCode == '400') {
        throw const ErrorAutenticacion(MotivoFallaAuth.credencialRechazada);
      }
      throw const ErrorAutenticacion(MotivoFallaAuth.red);
    }
  }

  @override
  Future<void> registrarCuenta({
    required String email,
    required String password,
    required Map<String, dynamic> metadata,
  }) async {
    await _cliente.auth.signUp(
      email: email,
      password: password,
      data: metadata,
    );
  }

  @override
  Future<void> cerrarSesion() => _cliente.auth.signOut();

  @override
  Future<UsuarioRemoto?> usuarioPorAuthId(String authUserId) async {
    // `auth_user_id` es único (índice parcial, HU-087): `.maybeSingle()` nunca
    // lanza por multiplicidad, a diferencia del viejo `.eq('email')`. Un null
    // significa inequívocamente "esta cuenta Auth no tiene fila en usuarios"
    // (no pertenece a ningún negocio), no "había ambigüedad de email".
    final fila = await _cliente
        .from('usuarios')
        .select('id, negocio_id, rol, auth_user_id, activo')
        .eq('auth_user_id', authUserId)
        .maybeSingle();
    if (fila == null) return null;
    final negocioId = fila['negocio_id'] as String?;
    final usuarioId = fila['id'] as String?;
    if (negocioId == null || usuarioId == null) return null;
    return UsuarioRemoto(
      usuarioId: usuarioId,
      negocioId: negocioId,
      // HU-108: fail-CLOSED. Un rol ausente/no reconocido cae en el rol de MENOR
      // privilegio (parsearRol → 'cocinero'), no en 'admin'. El parseo vive en un
      // único punto (Permisos.parsearRol).
      rol: Permisos.parsearRol(fila['rol']),
      // HU-071: null → true (no bloquear ante un valor ausente); un false explícito
      // del backend (usuario deshabilitado) sí rechaza el login.
      activo: (fila['activo'] as bool?) ?? true,
      authUserId: fila['auth_user_id'] as String?,
    );
  }

  @override
  Future<NegocioRemoto?> negocioPorId(String id) async {
    final fila = await _cliente
        .from('negocios')
        .select('nombre, tipo, email')
        .eq('id', id)
        .maybeSingle();
    if (fila == null) return null;
    return NegocioRemoto(
      nombre: (fila['nombre'] as String?) ?? 'Mi Negocio',
      tipo: (fila['tipo'] as String?) ?? 'restaurante',
      email: fila['email'] as String?,
    );
  }

  @override
  Future<MiembroNube> crearMiembroEnNube({
    required String email,
    required String password,
    required String nombre,
    required String rol,
    required String negocioId,
  }) async {
    try {
      final res = await _cliente.functions.invoke(
        'crear-miembro',
        body: {
          'email': email,
          'password': password,
          'nombre': nombre,
          'rol': rol,
          // #257: el negocio activo. La EF lo usa sólo si el caller es superadmin.
          'negocio_id': negocioId,
        },
      );
      final data = res.data;
      final usuario = (data is Map ? data['usuario'] : null);
      if (usuario is! Map) throw const ErrorCrearMiembro('respuesta_invalida');
      return MiembroNube(
        id: usuario['id'] as String,
        negocioId: usuario['negocio_id'] as String,
        nombre: usuario['nombre'] as String,
        rol: usuario['rol'] as String,
        email: usuario['email'] as String,
        authUserId: usuario['auth_user_id'] as String,
      );
    } on ErrorCrearMiembro {
      rethrow;
    } on FunctionException catch (e) {
      // La EF devolvió un status de error: el cuerpo trae `{ error: '<codigo>' }`.
      final detalles = e.details;
      final codigo = (detalles is Map ? detalles['error'] : null) as String?;
      throw ErrorCrearMiembro(codigo ?? 'error_backend');
    } catch (_) {
      // No se pudo ni llegar al backend (red caída, timeout, etc.).
      throw const ErrorCrearMiembro('sin_conexion');
    }
  }

  @override
  Future<ResetPasswordNube> resetearPasswordEnNube({
    required String usuarioId,
    required String password,
    required String passwordAdmin,
    required String negocioId,
  }) async {
    try {
      final res = await _cliente.functions.invoke(
        'resetear-password',
        body: {
          'usuario_id': usuarioId,
          'password': password,
          'password_admin': passwordAdmin,
          // #257: el negocio activo. La EF lo usa sólo si el caller es superadmin.
          'negocio_id': negocioId,
        },
      );
      final data = res.data;
      final usuario = (data is Map ? data['usuario'] : null);
      if (usuario is! Map) throw const ErrorResetPassword('respuesta_invalida');
      // Parseo tolerante en el factory: llegó `usuario` ⇒ el reset se aplicó, así que un
      // tipo raro en `sesiones_revocadas` no debe reventar y degradarse a "sin conexión".
      return ResetPasswordNube.desdeUsuario(usuario);
    } on ErrorResetPassword {
      rethrow;
    } on FunctionException catch (e) {
      final detalles = e.details;
      final codigo = (detalles is Map ? detalles['error'] : null) as String?;
      throw ErrorResetPassword(codigo ?? 'error_backend');
    } catch (_) {
      throw const ErrorResetPassword('sin_conexion');
    }
  }

  @override
  Future<BajaMiembroNube> cambiarEstadoMiembroEnNube({
    required String usuarioId,
    required bool activar,
    required String passwordAdmin,
    required String negocioId,
  }) async {
    try {
      final res = await _cliente.functions.invoke(
        'dar-de-baja-usuario',
        body: {
          'usuario_id': usuarioId,
          'activar': activar,
          'password_admin': passwordAdmin,
          // #257: el negocio activo. La EF lo usa sólo si el caller es superadmin.
          'negocio_id': negocioId,
        },
      );
      final data = res.data;
      final usuario = (data is Map ? data['usuario'] : null);
      if (usuario is! Map) throw const ErrorBajaMiembro('respuesta_invalida');
      return BajaMiembroNube(
        activo: (usuario['activo'] as bool?) ?? activar,
        // `num?` por si el JSON tipa el entero como double; null = no aplica/falló.
        sesionesRevocadas: (usuario['sesiones_revocadas'] as num?)?.toInt(),
      );
    } on ErrorBajaMiembro {
      rethrow;
    } on FunctionException catch (e) {
      final detalles = e.details;
      final codigo = (detalles is Map ? detalles['error'] : null) as String?;
      throw ErrorBajaMiembro(codigo ?? 'error_backend');
    } catch (_) {
      throw const ErrorBajaMiembro('sin_conexion');
    }
  }
}
