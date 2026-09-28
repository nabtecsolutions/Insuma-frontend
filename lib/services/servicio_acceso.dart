import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../data/repositorios/repositorio_usuarios.dart';
import '../data/repositorios/repositorio_negocios.dart';
import '../data/repositorios/repositorio_identidad_remota.dart';
import '../utils/validador_datos.dart';
import '../utils/ofuscar_pii.dart';
import 'servicio_autenticacion.dart';
import 'servicio_sesion.dart';
import 'contrato_sincronizacion.dart';
import 'servicio_descarga_negocio.dart';

/// Falla de negocio del login con un mensaje ya listo para el usuario (HU-088).
///
/// Existe para que una causa CONOCIDA (no se pudo resolver la identidad remota, la
/// cuenta no pertenece a ningún negocio) no se degrade al genérico "credenciales
/// incorrectas", que mandaba al usuario a revisar una contraseña que estaba bien.
class ErrorAcceso implements Exception {
  final String mensaje;
  const ErrorAcceso(this.mensaje);

  @override
  String toString() => mensaje;
}

/// Servicio de ACCESO / inicio de sesión (HU-001 / HU-072).
///
/// Concentra toda la lógica de negocio del login, antes embebida en
/// `ControladorOnboarding.procesarLogin`: validaciones, verificación de
/// credenciales offline-first, reconciliación de tenant y el camino online.
///
/// Es offline-first: primero valida contra el hash local (la app funciona sin
/// conexión) y sólo cae al backend si no hay credenciales locales válidas.
/// [_identidad] es null cuando no hay backend configurado; [_sync] es null cuando
/// la sincronización está desactivada.
class ServicioAcceso {
  final ServicioSesion _sesion;
  final RepositorioUsuarios _usuarios;
  final RepositorioNegocios _negocios;
  final RepositorioIdentidadRemota? _identidad;
  final SincronizadorOutbox? _sync;
  final ServicioDescargaNegocio? _descarga;

  /// Limpiador de la cola local independiente del sincronizador (HU-132): la
  /// reconciliación de tenant debe descartar la cola AUNQUE `_sync == null`
  /// (modo APP_PERSISTENCIA=local). Null solo en tests que no lo ejercitan;
  /// como red de seguridad se cae a `_sync`.
  final DescartadorCola? _limpiadorCola;

  /// [identidad] es null si no hay backend configurado; [sync] es null si la
  /// sincronización está desactivada; [descarga] es null sin backend.
  ServicioAcceso(
    this._sesion,
    this._usuarios,
    this._negocios, [
    this._identidad,
    this._sync,
    this._descarga,
    this._limpiadorCola,
  ]);

  /// Inicia sesión con [email] y [password]. Devuelve `null` si la sesión quedó
  /// abierta, o un mensaje de error listo para mostrar al usuario.
  /// Mensaje cuando el backend deshabilitó la cuenta (HU-071). Sólo aparece TRAS una
  /// autenticación exitosa (hash local o Supabase Auth), así que no filtra la existencia
  /// de la cuenta a quien no tiene las credenciales.
  static const String mensajeCuentaDeshabilitada =
      'Tu cuenta fue deshabilitada. Contactá al administrador del negocio.';

  Future<String?> iniciarSesion({
    required String email,
    required String password,
  }) async {
    if (!ValidadorDatos.validarEmail(email)) {
      return 'Por favor, ingrese un correo electrónico con formato correcto.';
    }
    // HU-112: el LOGIN mantiene un piso lenient (6) a propósito, NO la longitud
    // mínima de CREACIÓN (PoliticaPassword.longitudMinima = 10). Subirlo acá
    // rechazaría contraseñas legacy más cortas que ya existen en la base (creadas
    // cuando el onboarding permitía 6) → lockout. La fuerza se exige al crear la
    // contraseña; al entrar, el gate real es el hash, no la longitud.
    if (password.length < 6) {
      return 'La contraseña debe tener al menos 6 caracteres.';
    }

    try {
      final emailNormalizado = email.trim().toLowerCase();

      final accesoLocal = await _accederConCredencialesLocales(
        emailNormalizado,
        password,
      );
      if (accesoLocal) return null;

      final accesoRemoto = await _accederConBackend(
        email,
        emailNormalizado,
        password,
      );
      if (accesoRemoto) return null;

      return 'Credenciales incorrectas o usuario no encontrado.';
    } on ErrorAcceso catch (e) {
      // Falla de negocio con mensaje propio (HU-088): no se degrada al genérico.
      return e.mensaje;
    } catch (e) {
      return 'Error de inicio de sesión: $e';
    }
  }

  // --- Camino 1: credenciales locales (offline-first) ----------------------

  /// Orden determinístico de las candidatas de login local (HU-135): primero las
  /// del negocio de la ÚLTIMA sesión de este dispositivo (si la contraseña vale
  /// en dos negocios, se retoma donde el usuario estaba), después el orden del
  /// repositorio (más reciente primero).
  List<Usuario> _priorizarPorUltimaSesion(List<Usuario> candidatas) {
    final ultimoNegocio = _sesion.negocioId;
    if (ultimoNegocio.isEmpty || candidatas.length < 2) return candidatas;
    return [
      ...candidatas.where((c) => c.negocioId == ultimoNegocio),
      ...candidatas.where((c) => c.negocioId != ultimoNegocio),
    ];
  }

  /// Valida el hash local. Si coincide, resuelve el tenant AUTORITATIVO contra el
  /// backend (si hay sesión), guarda la sesión y dispara sync + descarga.
  Future<bool> _accederConCredencialesLocales(
    String emailNormalizado,
    String password,
  ) async {
    // HU-135: puede haber MÁS de una fila activa con este email (email compartido
    // entre negocios). El singular lanzaba `Too many elements` y brickeaba el
    // login. Se valida el hash contra cada candidata (HU-133: en isolate aparte)
    // en orden determinístico —el negocio de la última sesión primero, después la
    // más reciente— y gana la primera que valida; si ninguna, cae al camino
    // online, que resuelve la identidad por auth_user_id (HU-095).
    final candidatas = _priorizarPorUltimaSesion(
      await _usuarios.listarActivosPorEmail(emailNormalizado),
    );
    Usuario? local;
    for (final candidata in candidatas) {
      // HU-136: sin hash local el resultado es constante `false` — no se paga
      // una pasada de KDF (acota el multiplicador por-candidata de HU-135).
      final hash = candidata.passwordHash;
      if (hash == null || hash.isEmpty) continue;
      if (await ServicioAutenticacion.verificarPasswordAsync(
        password,
        hash,
        salt: emailNormalizado,
      )) {
        local = candidata;
        break;
      }
    }
    if (local == null) return false;

    // La validación fue local (offline-first), pero sin sesión de Supabase la RLS
    // rechazaría las mutaciones encoladas: aseguramos identidad remota.
    final estadoSesion = await _asegurarSesionRemota(
      emailNormalizado,
      password,
    );

    // INVALIDACIÓN POST-RESET (HU-076). El hash local validó, pero el backend rechazó
    // ESA MISMA contraseña estando ONLINE: es la señal inequívoca de que la contraseña
    // cambió (un reset). El hash local quedó viejo; se ANULA y se niega el acceso
    // offline. El miembro cae al camino online, que también rechazará la vieja, y
    // recibe "credenciales incorrectas": debe usar la nueva.
    //
    // Es la única señal que NO depende del pull (que necesitaría una sesión que sólo
    // se obtiene con la contraseña nueva — la que este dispositivo no tiene todavía).
    // Ante una falla de RED no se toca nada: la app sigue siendo usable offline.
    if (estadoSesion == _EstadoSesionRemota.credencialRechazada) {
      await _usuarios.actualizarPasswordHash(id: local.id, passwordHash: null);
      return false;
    }

    // HU-112: rehash-on-login. Si el hash local está en el esquema viejo (SHA-256 de
    // 1 ronda) y la contraseña ya validó y NO fue rechazada online, se re-hashea a
    // PBKDF2 con la contraseña en claro que tenemos ahora. Así el esquema legacy se
    // extingue solo a medida que la gente entra, sin pedirle nada al usuario.
    if (ServicioAutenticacion.esLegacy(local.passwordHash)) {
      await _usuarios.actualizarPasswordHash(
        id: local.id,
        passwordHash: await ServicioAutenticacion.hashearPasswordAsync(
          password,
          salt: emailNormalizado,
        ),
      );
    }

    var negocioId = local.negocioId;
    var usuarioId = local.id;
    var rol = local.rol;

    // Reconciliación de tenant (RN-001 / HU-029): el negocio_id AUTORITATIVO es el
    // del usuario autenticado en Supabase. Si el local difiere, toda mutación se
    // sellaría con un tenant ajeno y la RLS la rechazaría (42501).
    final remoto = await _resolverUsuarioRemoto();
    // HU-071: con conexión, el `activo` AUTORITATIVO es el del backend. Si lo
    // deshabilitó, se rechaza aunque la copia LOCAL siga activa: se reconcilia el local
    // a false (para que el próximo login offline también lo rechace) y se cierra la
    // sesión de Supabase Auth para no dejar un JWT válido. OFFLINE (remoto == null) se
    // acepta el estado local: degradación documentada, se aplica en la próxima sync.
    if (remoto != null && !remoto.activo) {
      await _usuarios.reconciliarActivo(usuarioId: local.id, activo: false);
      await _identidad?.cerrarSesion();
      throw const ErrorAcceso(mensajeCuentaDeshabilitada);
    }
    if (remoto != null && remoto.negocioId != local.negocioId) {
      await _reconciliarTenantLocal(local, remoto);
      negocioId = remoto.negocioId;
      usuarioId = remoto.usuarioId;
      rol = remoto.rol;
    }

    await _sesion.guardarSesion(
      negocioId: negocioId,
      usuarioId: usuarioId,
      nombre: local.nombre,
      rol: rol,
    );

    // Ya con el tenant correcto, reintentar el drenaje de la cola...
    await _sync?.sincronizarPendientes();
    // ...y descargar lo que haya cargado el negocio desde otros dispositivos.
    // HU-134: en SEGUNDO PLANO — los datos ya están locales (Drift, offline-first)
    // y las pantallas se actualizan solas vía watch() cuando el pull deposita
    // novedades (HU-089/HU-128). Esperar el pull completo (~15 tablas paginadas,
    // sin timeouts) solo alargaba el spinner sin valor para el usuario. La guarda
    // del primer pull (HU-090) sigue bloqueando movimientos hasta hidratar.
    unawaited(_descargarNegocioSiOnline(negocioId));
    return true;
  }

  // --- Camino 2: autenticación contra el backend ---------------------------

  /// [emailCrudo] se envía al backend sólo con `trim()` (sin bajar a minúsculas),
  /// tal como lo hacía el flujo original; [emailNormalizado] se usa para todo lo local.
  Future<bool> _accederConBackend(
    String emailCrudo,
    String emailNormalizado,
    String password,
  ) async {
    final identidad = _identidad;
    if (identidad == null) return false;

    try {
      final sesionRemota = await identidad.autenticar(
        email: emailCrudo.trim(),
        password: password,
      );
      if (sesionRemota == null) return false;

      // SuperAdmin global (HU-037): el rol viaja en app_metadata (no editable por el
      // usuario). Si lo es, NO se le asigna un negocio: va a su panel de control.
      if (sesionRemota.rolGlobal == 'superadmin') {
        await _sesion.guardarSesionSuperAdmin(
          usuarioId: sesionRemota.usuarioId,
          nombre: 'SuperAdmin',
        );
        return true;
      }

      final identidadLocal = await _resolverIdentidadTrasLogin(
        identidad: identidad,
        sesionRemota: sesionRemota,
        emailNormalizado: emailNormalizado,
        password: password,
      );

      await _sesion.guardarSesion(
        negocioId: identidadLocal.negocioId,
        usuarioId: identidadLocal.usuarioId,
        nombre: identidadLocal.nombre,
        rol: identidadLocal.rol,
      );

      // Descargar los datos del negocio para reflejar lo cargado por otros
      // dispositivos. HU-134: en SEGUNDO PLANO (ver camino 1); se preserva el
      // orden pull → drenaje dentro de la cadena, y los errores no burbujean a
      // un contexto ya retornado.
      final negocioId = identidadLocal.negocioId;
      unawaited(() async {
        try {
          await _descargarNegocioSiOnline(negocioId);
          await _sync?.sincronizarPendientes();
        } catch (e) {
          debugPrint('[LOGIN] Refresco post-login en segundo plano falló: $e');
        }
      }());
      return true;
    } on ErrorAcceso {
      // Falla de negocio con mensaje propio (HU-088): sube tal cual, no se degrada
      // a "credenciales incorrectas", que ocultaría la causa real.
      rethrow;
    } catch (e) {
      // Surface the real cause (antes se tragaba y se mostraba el genérico). B03: el
      // email se OFUSCA para no filtrar PII en logs.
      debugPrint(
        '[LOGIN] Falla en login online (${ofuscarEmail(emailNormalizado)}): $e',
      );
      return false;
    }
  }

  /// Resuelve el negocio/usuario del email autenticado (RN-001 / HU-029): nunca
  /// tomar un negocio arbitrario en un dispositivo compartido.
  ///
  /// HU-088: la identidad remota es la ÚNICA fuente de verdad del tenant. Si no se
  /// puede resolver, se ABORTA con un error claro. Antes se creaba acá un negocio
  /// local nuevo, lo que partía el tenant: el usuario quedaba trabajando en un
  /// negocio fantasma que la RLS después rechazaba.
  Future<_IdentidadLocal> _resolverIdentidadTrasLogin({
    required RepositorioIdentidadRemota identidad,
    required SesionRemota sesionRemota,
    required String emailNormalizado,
    required String password,
  }) async {
    // HU-071: recién autenticó contra Supabase Auth → estamos ONLINE. La identidad y el
    // `activo` AUTORITATIVOS son los del backend, y se consultan SIEMPRE — también cuando
    // el usuario ya existe localmente, para no dejar entrar a uno deshabilitado en el
    // backend que conserve una copia local activa. La consulta puede fallar (red caída a
    // mitad del login) o no encontrar fila: son casos DISTINTOS y ninguno habilita a
    // inventar un negocio.
    // HU-095: se resuelve por auth_user_id (la cuenta que ACABA de autenticar),
    // no por email. El email no es único entre negocios y `.maybeSingle()` por
    // email LANZABA con email compartido; esa excepción se degradaba acá a
    // "Necesitás conexión" (camino 2) o a "offline" (camino 1), rompiendo el
    // login o salteando el chequeo de `activo`. Con auth_user_id (único) el
    // catch sólo se dispara ante una falla de RED real, así el mensaje es veraz.
    final UsuarioRemoto? remoto;
    try {
      remoto = await identidad.usuarioPorAuthId(sesionRemota.usuarioId);
    } catch (e) {
      debugPrint(
        '[LOGIN] No se pudo resolver la identidad (${ofuscarEmail(emailNormalizado)}): $e',
      );
      throw const ErrorAcceso(
        'No pudimos verificar tu cuenta. Necesitás conexión para iniciar sesión por '
        'primera vez en este dispositivo. Verificá tu internet e intentá de nuevo.',
      );
    }

    if (remoto == null) {
      // Autenticó en Supabase Auth pero no tiene fila en `usuarios`: no pertenece a
      // ningún negocio. Un alta legítima SIEMPRE crea la fila (el trigger del alta de
      // negocio, o la Edge Function `crear-miembro` para los miembros).
      throw const ErrorAcceso(
        'Tu cuenta no está asociada a ningún negocio. Pedile al administrador que te '
        'dé de alta en el equipo.',
      );
    }

    // HU-071: deshabilitado en el backend → rechazar y cerrar la sesión de Supabase Auth
    // (no dejar un JWT válido). Reconcilia el local a false si existiera.
    if (!remoto.activo) {
      await _usuarios.reconciliarActivo(
        usuarioId: remoto.usuarioId,
        activo: false,
      );
      await identidad.cerrarSesion();
      throw const ErrorAcceso(mensajeCuentaDeshabilitada);
    }

    // Usuario ya presente localmente: adopta su identidad, reactivando el `activo` local
    // si el backend lo re-habilitó (reconciliación en sentido inverso).
    // HU-135: con email compartido puede haber varias filas locales; el singular
    // lanzaba `Too many elements` (degradado a "credenciales incorrectas" por el
    // catch genérico). Se prefiere la fila del negocio AUTORITATIVO (remoto,
    // resuelto por auth_user_id); si no hay, la más reciente.
    final locales = await _usuarios.listarPorEmail(emailNormalizado);
    final negocioAutoritativo = remoto.negocioId;
    final usuarioLocal = locales.isEmpty
        ? null
        : locales.firstWhere(
            (u) => u.negocioId == negocioAutoritativo,
            orElse: () => locales.first,
          );
    if (usuarioLocal != null) {
      // HU-117: la fila local puede ser de OTRO tenant (dispositivo espejado, email
      // compartido entre negocios). El remoto —resuelto por auth_user_id— es la
      // identidad AUTORITATIVA. Si el negocio difiere, NO se adopta la fila local
      // (identidad local de un tenant + JWT de otro → toda mutación 42501, tenant
      // partido en silencio); se reconcilia al tenant remoto, igual que en camino 1.
      if (usuarioLocal.negocioId != remoto.negocioId) {
        await _reconciliarTenantLocal(usuarioLocal, remoto);
        // HU-071 inverso: el backend ya validó `activo=true` (arriba). Si la fila
        // local estaba inactiva, se reactiva la fila reconciliada — si no, el hash
        // que reescribimos abajo sería inútil (`buscarPorEmailActivo` no la vería y
        // el login offline posterior fallaría).
        await _usuarios.reconciliarActivo(
          usuarioId: remoto.usuarioId,
          activo: true,
        );
        // El hash se reescribe para la identidad reconciliada: se llegó por el camino
        // online (el hash local no validó), así que hay que dejar el de la contraseña
        // recién tipeada para habilitar el login offline posterior.
        await _usuarios.actualizarPasswordHash(
          id: remoto.usuarioId,
          passwordHash: await ServicioAutenticacion.hashearPasswordAsync(
            password,
            salt: emailNormalizado,
          ),
        );
        return _IdentidadLocal(
          negocioId: remoto.negocioId,
          usuarioId: remoto.usuarioId,
          nombre: usuarioLocal.nombre,
          rol: remoto.rol,
        );
      }
      if (!usuarioLocal.activo) {
        await _usuarios.reconciliarActivo(
          usuarioId: usuarioLocal.id,
          activo: true,
        );
      }
      // HU-076: llegar acá por el camino online significa que el hash local NO validó
      // (si hubiera validado, el offline habría cortado antes) pero el backend SÍ aceptó
      // la contraseña. O sea: la contraseña cambió (p. ej. un reset) y la de este
      // dispositivo quedó vieja. Se reescribe el hash con la AUTORITATIVA que el usuario
      // acaba de tipear; sin esto, el reset nunca se completaría en su dispositivo y
      // perdería el login offline para siempre.
      await _usuarios.actualizarPasswordHash(
        id: usuarioLocal.id,
        passwordHash: await ServicioAutenticacion.hashearPasswordAsync(
          password,
          salt: emailNormalizado,
        ),
      );
      return _IdentidadLocal(
        negocioId: usuarioLocal.negocioId,
        usuarioId: usuarioLocal.id,
        nombre: usuarioLocal.nombre,
        rol: usuarioLocal.rol,
      );
    }

    // El negocio YA existe en Supabase pero puede faltar en esta base local
    // (dispositivo nuevo): lo espejamos y adoptamos el id de usuario remoto. NO se encola.
    final negocioId = remoto.negocioId;
    final usuarioId = remoto.usuarioId;
    final nombreUsuario = sesionRemota.email!.split('@')[0];
    final rolUsuario = remoto.rol;
    // El hash local habilita el login OFFLINE posterior en ESTE dispositivo: el primer
    // login exige conexión, los siguientes no.
    final passwordHash = await ServicioAutenticacion.hashearPasswordAsync(
      password,
      salt: emailNormalizado,
    );

    await _asegurarNegocioLocal(identidad, negocioId, emailNormalizado);
    await _usuarios.espejarLocal(
      id: usuarioId,
      negocioId: negocioId,
      nombre: nombreUsuario,
      rol: rolUsuario,
      email: emailNormalizado,
      passwordHash: passwordHash,
    );
    return _IdentidadLocal(
      negocioId: negocioId,
      usuarioId: usuarioId,
      nombre: nombreUsuario,
      rol: rolUsuario,
    );
  }

  // --- Helpers de identidad / tenant ---------------------------------------

  /// Garantiza (best-effort, online) una sesión de Supabase Auth para que el sync
  /// tenga identidad y la RLS acepte las mutaciones encoladas.
  ///
  /// Devuelve el desenlace (HU-076) porque el llamador lo necesita para la invalidación
  /// post-reset: un rechazo EXPLÍCITO de credenciales estando online no es lo mismo que
  /// una falla de red, y sólo el primero invalida el hash local.
  ///
  /// HU-071: acá NO se drena la cola. El drenaje se hace DESPUÉS de revalidar el `activo`
  /// remoto (más abajo en `_accederConCredencialesLocales`), así las mutaciones encoladas
  /// de un usuario deshabilitado NO viajan con un JWT válido antes del rechazo + signOut.
  Future<_EstadoSesionRemota> _asegurarSesionRemota(
    String email,
    String password,
  ) async {
    final identidad = _identidad;
    // HU-118: la sesión remota (base de la revalidación de `activo`) depende SÓLO de
    // que haya backend de identidad, NO de que la sincronización esté activa. Antes,
    // con `_sync == null` se devolvía `sinBackend` y no se establecía sesión → el
    // chequeo de `activo` (HU-071) se salteaba → un usuario deshabilitado con la sync
    // apagada conservaba acceso. Una decisión de seguridad no debe depender de una
    // feature operativa. (Sin backend de identidad sí sigue siendo 100% local.)
    if (identidad == null) return _EstadoSesionRemota.sinBackend;
    if (identidad.haySesion) {
      // HU-095: reutilizar la sesión SÓLO si es de este mismo usuario. Una sesión
      // residual de OTRO (p. ej. un logout interrumpido) haría que la resolución
      // por auth_user_id devuelva la fila del dueño de la sesión y contamine el
      // login (reasignaría el tenant/rol local o rechazaría por su `activo`). En
      // producción `emailSesionActual` nunca es null con sesión activa (Supabase
      // Auth es por email), así que la guarda es efectiva; un null (identidad sin
      // email, no aplica hoy) preserva el comportamiento previo.
      final emailSesion = identidad.emailSesionActual;
      if (emailSesion == null ||
          emailSesion.toLowerCase() == email.toLowerCase()) {
        return _EstadoSesionRemota.establecida;
      }
      // Sesión de otro usuario: cerrarla y re-autenticar como el que entra.
      await identidad.cerrarSesion();
    }
    try {
      await identidad.autenticar(email: email, password: password);
      // HU-071: NO se drena la cola acá (va después de revalidar el `activo` remoto).
      return _EstadoSesionRemota.establecida;
    } on ErrorAutenticacion catch (e) {
      // credencialRechazada = la contraseña ya no sirve (online); red = sin conexión.
      // cuentaDeshabilitada (baja, HU-076 Fase 3) se trata IGUAL que un rechazo: se anula
      // el hash local para que el usuario baneado tampoco pueda entrar offline acá.
      return (e.motivo == MotivoFallaAuth.credencialRechazada ||
              e.motivo == MotivoFallaAuth.cuentaDeshabilitada)
          ? _EstadoSesionRemota.credencialRechazada
          : _EstadoSesionRemota.fallaRed;
    } catch (_) {
      // Cualquier otra falla se trata como red: NO se invalida la credencial.
      return _EstadoSesionRemota.fallaRed;
    }
  }

  /// Identidad autoritativa de la CUENTA autenticada (por `auth_user_id`), o null
  /// si no hay backend/sesión.
  ///
  /// HU-095: resuelve por `auth_user_id`, no por email. Antes, con email
  /// compartido entre negocios, `usuarioPorEmail` LANZABA y el `catch` de abajo
  /// devolvía null → el llamador lo leía como "offline" y salteaba el chequeo de
  /// `activo` (HU-071): un usuario DESHABILITADO con email compartido conservaba
  /// acceso (fail-open permanente). Con `auth_user_id` (único) ya no hay
  /// multiplicidad: un null acá significa de verdad "sin red / sin fila", nunca
  /// "hubo ambigüedad de email".
  Future<UsuarioRemoto?> _resolverUsuarioRemoto() async {
    final identidad = _identidad;
    // HU-118: la revalidación de `activo` depende sólo de que haya identidad remota
    // con sesión, NO de `_sync`. Con sync apagada pero backend online, un usuario
    // deshabilitado igual debe ser rechazado.
    if (identidad == null) return null;
    if (!identidad.haySesion) return null;
    final authUserId = identidad.authUserIdActual;
    if (authUserId == null) return null;
    try {
      return await identidad.usuarioPorAuthId(authUserId);
    } catch (_) {
      return null;
    }
  }

  /// Realinea la fila local a la identidad remota y descarta la cola: sus
  /// mutaciones pertenecen al tenant viejo y la RLS las rechazaría.
  Future<void> _reconciliarTenantLocal(
    Usuario local,
    UsuarioRemoto remoto,
  ) async {
    final identidad = _identidad;
    // El negocio remoto puede no existir aún en esta base local: lo espejamos
    // primero para no violar la FK usuarios.negocio_id al actualizar.
    if (identidad != null) {
      await _asegurarNegocioLocal(
        identidad,
        remoto.negocioId,
        local.email ?? '',
      );
    }
    try {
      await _usuarios.reasignarIdentidad(
        idActual: local.id,
        nuevoId: remoto.usuarioId,
        negocioId: remoto.negocioId,
        rol: remoto.rol,
      );
    } catch (e) {
      // HU-131: defensa en profundidad. Un fallo al persistir la reconciliación
      // NO es un problema de credenciales: no debe degradarse a "credenciales
      // incorrectas" (camino 2) ni a un SqliteException crudo (camino 1).
      debugPrint('[LOGIN] Falla al reconciliar la identidad local: $e');
      throw const ErrorAcceso(
        'No pudimos actualizar los datos de tu cuenta en este dispositivo. '
        'Cerrá la app e intentá de nuevo; si persiste, contactá al administrador.',
      );
    }
    // HU-132: descartar la cola SIEMPRE que se reconcilia el tenant, aunque la
    // sync esté desactivada (_sync == null). Las mutaciones encoladas del tenant
    // viejo sobrevivirían y, al volver a modo híbrido, se drenarían con el JWT
    // del tenant nuevo (42501 / dead-letter).
    await (_limpiadorCola ?? _sync)?.descartarPendientes();
  }

  /// Espeja localmente un negocio que ya existe en Supabase si falta en esta base
  /// (p. ej. primer login en un dispositivo nuevo). No encola: ya está en el backend.
  Future<void> _asegurarNegocioLocal(
    RepositorioIdentidadRemota identidad,
    String negocioId,
    String emailFallback,
  ) async {
    if (await _negocios.obtener(negocioId) != null) return;

    var nombre = 'Mi Negocio';
    var tipo = 'restaurante';
    String? email = emailFallback.isEmpty ? null : emailFallback;
    try {
      final remoto = await identidad.negocioPorId(negocioId);
      if (remoto != null) {
        nombre = remoto.nombre;
        tipo = remoto.tipo;
        email = remoto.email ?? email;
      }
    } catch (_) {
      // Sin conexión o sin lectura: espejo mínimo con los valores por defecto.
    }

    await _negocios.espejarLocal(
      id: negocioId,
      nombre: nombre,
      tipo: tipo,
      email: email,
    );
  }

  /// Descarga (pull) los datos del negocio si hay sesión remota. Offline-first:
  /// si falla, se sigue con lo local.
  Future<void> _descargarNegocioSiOnline(String negocioId) async {
    final descarga = _descarga;
    if (descarga == null || negocioId.isEmpty) return;
    if (_identidad == null || !_identidad.haySesion) return;
    try {
      await descarga.descargarNegocio(negocioId);
    } catch (_) {
      // Sin conexión o lectura parcial: la app funciona con lo que haya local.
    }
  }
}

/// Desenlace del intento de asegurar sesión de Supabase durante el login offline-first.
enum _EstadoSesionRemota {
  /// Hay sesión (recién creada o ya existente).
  establecida,

  /// El backend RECHAZÓ las credenciales estando online: la contraseña cambió.
  credencialRechazada,

  /// No se pudo llegar al backend (sin red, timeout, rate-limit). No se invalida nada.
  fallaRed,

  /// No hay backend de identidad configurado: la app corre 100% local. (HU-118: la
  /// sync ya no influye acá — con backend pero sync apagada sí se establece sesión.)
  sinBackend,
}

/// Identidad local resuelta tras un login online.
class _IdentidadLocal {
  final String negocioId;
  final String usuarioId;
  final String nombre;
  final String rol;
  const _IdentidadLocal({
    required this.negocioId,
    required this.usuarioId,
    required this.nombre,
    required this.rol,
  });
}
