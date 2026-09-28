import 'package:insuma/constants/politica_password.dart';
import '../data/repositorios/repositorio_identidad_remota.dart';
import '../data/repositorios/repositorio_usuarios.dart';
import '../utils/validador_datos.dart';
import 'servicio_sesion.dart';

/// Datos de entrada para dar de alta un miembro de equipo.
class DatosNuevoMiembro {
  final String nombre;
  final String email;
  final String password;
  final String rol;
  const DatosNuevoMiembro({
    required this.nombre,
    required this.email,
    required this.password,
    required this.rol,
  });
}

/// Servicio de gestión de equipo (HU-087): lógica de negocio del alta de un
/// MIEMBRO con cuenta Supabase Auth real.
///
/// Toda la seguridad (que el caller sea admin, el negocio, el rol) se resuelve
/// server-side en la Edge Function `crear-miembro`. Este servicio valida la
/// entrada, exige que haya una sesión de Supabase (sin JWT no hay quién autorice
/// la Edge Function) y espeja localmente la fila que devuelve el backend.
///
/// Regla de conexión (como HU-075): sin backend/sesión NO se crea el miembro; no
/// se cae a un alta local a medias que después no podría loguear en la nube.
class ServicioGestionEquipo {
  final RepositorioUsuarios _usuarios;
  final ServicioSesion _sesion;
  final RepositorioIdentidadRemota? _identidad;

  ServicioGestionEquipo(this._usuarios, this._sesion, [this._identidad]);

  /// #257: negocio activo (de [ServicioSesion]) que viaja en el payload de las
  /// 3 Edge Functions. La EF lo usa SÓLO si el caller es superadmin; para un
  /// admin lo ignora y fuerza su propio negocio. Enviarlo siempre es inofensivo
  /// (el cliente no es la frontera de seguridad: la EF lo es).
  String get _negocioActivo => _sesion.negocioId;

  static const int minPassword = PoliticaPassword.longitudMinima;
  static const Set<String> rolesPermitidos = {'cocinero', 'admin'};
  static const String mensajeSinConexion =
      'Necesitás conexión para crear un usuario: la cuenta se crea en la nube. '
      'Verificá tu internet y volvé a intentar.';

  /// Constante propia y no reutilización de [mensajeSinConexion]: aquél dice
  /// literalmente "para crear un usuario", que en un reset sería incoherente.
  static const String mensajeSinConexionReset =
      'Necesitás conexión para resetear una contraseña: la cuenta vive en la nube. '
      'Verificá tu internet y volvé a intentar.';

  /// Constante propia (la baja tampoco es offline-first): banear la cuenta y revocar
  /// sesiones exige llegar al backend; sin conexión no se hace nada a medias.
  static const String mensajeSinConexionBaja =
      'Necesitás conexión para dar de baja a un usuario: la cuenta vive en la nube. '
      'Verificá tu internet y volvé a intentar.';

  /// Éxito PARCIAL: la contraseña cambió, pero el backend no pudo cerrarle las sesiones
  /// abiertas. Se avisa en vez de callarlo, porque el admin cree estar cortando un
  /// acceso y en realidad el miembro sigue adentro hasta que su token expire.
  static const String mensajeRevocacionFallida =
      'La contraseña se cambió, pero no pudimos cerrar las sesiones que el usuario '
      'ya tenía abiertas: puede seguir usando la app hasta una hora. Volvé a '
      'intentar el reseteo o contactá a soporte.';

  /// #257: el superadmin gestiona usuarios sobre el negocio en el que ENTRÓ.
  /// Sin negocio activo (`negocio_requerido`) o con uno inexistente
  /// (`negocio_invalido`), la EF rechaza y estos mensajes lo explican en vez de
  /// caer al genérico "No se pudo…".
  static const String mensajeSinNegocioActivo =
      'Entrá a un negocio antes de gestionar sus usuarios.';
  static const String mensajeNegocioInvalido =
      'El negocio seleccionado no existe. Salí y volvé a entrar.';

  /// Valida los datos de un miembro. Devuelve `null` si son válidos, o el mensaje
  /// de error. ÚNICA fuente de verdad de las reglas de entrada: la usan tanto el
  /// alta desde Gestionar Equipo como la validación previa del onboarding (HU-088),
  /// para que ambos rechacen exactamente lo mismo que rechazaría la Edge Function.
  String? validar(DatosNuevoMiembro datos) {
    if (datos.nombre.trim().isEmpty) return 'El nombre es requerido.';
    if (!ValidadorDatos.validarEmail(datos.email.trim().toLowerCase())) {
      return 'El correo electrónico no es válido.';
    }
    if (datos.password.length < minPassword) {
      return 'La contraseña debe tener al menos $minPassword caracteres.';
    }
    if (!rolesPermitidos.contains(datos.rol.trim())) {
      return 'El rol seleccionado no es válido.';
    }
    return null;
  }

  /// Crea un miembro con cuenta en la nube y lo espeja localmente.
  /// Devuelve `null` si salió bien, o un mensaje de error listo para mostrar.
  Future<String?> crearMiembro(DatosNuevoMiembro datos) async {
    final error = validar(datos);
    if (error != null) return error;

    final nombre = datos.nombre.trim();
    final email = datos.email.trim().toLowerCase();
    final rol = datos.rol.trim();

    final identidad = _identidad;
    // Sin backend o sin sesión de Supabase no hay JWT que autorice la Edge
    // Function: no se puede crear la cuenta en la nube (y no se crea local a medias).
    if (identidad == null || !identidad.haySesion) return mensajeSinConexion;

    try {
      final miembro = await identidad.crearMiembroEnNube(
        email: email,
        password: datos.password,
        nombre: nombre,
        rol: rol,
        negocioId: _negocioActivo,
      );
      // Espeja la fila que YA existe en el backend (NO encola). Sin passwordHash:
      // el miembro inicia sesión en SU propio dispositivo contra Supabase Auth,
      // no en el del admin; guardar su hash acá sería innecesario e inseguro.
      await _usuarios.espejarLocal(
        id: miembro.id,
        negocioId: miembro.negocioId,
        nombre: miembro.nombre,
        rol: miembro.rol,
        email: miembro.email,
      );
      return null;
    } on ErrorCrearMiembro catch (e) {
      return _mensajeDeError(e.codigo);
    }
  }

  /// Resetea la contraseña de un miembro del equipo (HU-076).
  ///
  /// TODA la autorización vive server-side en la Edge Function `resetear-password`:
  /// que el caller sea admin, que el objetivo sea un miembro ACTIVO de SU negocio, y
  /// la reconfirmación de [passwordAdmin]. Acá sólo se valida la entrada, se exige
  /// conexión y se ajusta el estado local.
  ///
  /// El miembro HEREDADO (sin cuenta Auth) se provisiona en el mismo acto, pero lo
  /// hace la EF de reset — NO se reutiliza `crear-miembro`, cuyo upsert forzaría
  /// `activo: true` y tomaría rol/nombre del cliente: resucitaría a un dado de baja
  /// y habilitaría una escalada de rol.
  ///
  /// Devuelve `null` si salió bien, o un mensaje de error listo para mostrar.
  Future<String?> resetearPassword({
    required String usuarioId,
    required String nuevaPassword,
    required String passwordAdmin,
  }) async {
    if (nuevaPassword.length < minPassword) {
      return 'La contraseña debe tener al menos $minPassword caracteres.';
    }
    if (passwordAdmin.isEmpty) {
      return 'Ingresá tu contraseña para confirmar la operación.';
    }

    final identidad = _identidad;
    // Sin sesión no hay JWT que autorice la Edge Function. No se cae a un cambio
    // local: eso dejaría al miembro con una contraseña que la nube no conoce.
    if (identidad == null || !identidad.haySesion) {
      return mensajeSinConexionReset;
    }

    try {
      final resultado = await identidad.resetearPasswordEnNube(
        usuarioId: usuarioId,
        password: nuevaPassword,
        passwordAdmin: passwordAdmin,
        negocioId: _negocioActivo,
      );

      // INVALIDA el hash local del objetivo EN ESTE dispositivo. Sólo importa si el
      // admin y el miembro compartieron este teléfono (el hash del miembro vive acá):
      // así su contraseña vieja tampoco entra offline en este equipo. En el teléfono
      // propio del miembro, la invalidación la dispara su propio login (ServicioAcceso).
      await _usuarios.actualizarPasswordHash(id: usuarioId, passwordHash: null);

      // La contraseña YA cambió, pero si no se pudieron matar sus sesiones el miembro
      // sigue adentro con la sesión vieja. Es un éxito PARCIAL y se dice: callarlo
      // dejaría al admin creyendo que cortó un acceso que en realidad sigue abierto
      // (exactamente el falso verde que esta HU vino a arreglar).
      if (resultado.revocacionFallida) return mensajeRevocacionFallida;

      return null;
    } on ErrorResetPassword catch (e) {
      return _mensajeDeErrorReset(e.codigo);
    }
  }

  /// Traduce los códigos de `resetear-password`. Tabla propia y no reutilización de
  /// [_mensajeDeError]: los modos de falla del reset son otros (contraseña del admin
  /// incorrecta, objetivo inexistente, demasiados intentos) y el copy del alta
  /// ("No se pudo crear el usuario") sería directamente incorrecto acá.
  String _mensajeDeErrorReset(String codigo) {
    switch (codigo) {
      case 'password_admin_incorrecta':
        return 'Tu contraseña no es correcta. Volvé a intentar.';
      case 'password_admin_requerida':
        return 'Ingresá tu contraseña para confirmar la operación.';
      case 'demasiados_intentos':
        return 'Demasiados intentos seguidos. Esperá un momento y volvé a probar.';
      case 'password_corta':
        return 'La contraseña debe tener al menos $minPassword caracteres.';
      case 'usuario_no_encontrado':
        // Mensaje NEUTRO a propósito: la EF no distingue "no existe" de "es de otro
        // negocio" ni de "está dado de baja", para no filtrar datos de otros tenants.
        return 'Ese usuario no está disponible en tu equipo.';
      case 'cuenta_huerfana':
        return 'El correo de ese usuario ya tiene una cuenta que no le pertenece. '
            'Contactá a soporte para resolverlo.';
      case 'enlace_inconsistente':
        // La cuenta en la nube ligada a ese usuario no coincide con su correo: dato
        // inconsistente que la EF NO resuelve a ciegas (resetearía la cuenta equivocada).
        return 'La cuenta de ese usuario tiene datos inconsistentes. '
            'Contactá a soporte para resolverlo.';
      case 'no_autorizado':
        return 'Solo un administrador puede resetear contraseñas.';
      case 'negocio_requerido':
        return mensajeSinNegocioActivo;
      case 'negocio_invalido':
        return mensajeNegocioInvalido;
      case 'no_autenticado':
        return 'Tu sesión expiró. Volvé a iniciar sesión e intentá de nuevo.';
      case 'sin_conexion':
        return mensajeSinConexionReset;
      default:
        return 'No se pudo resetear la contraseña. Intentá de nuevo.';
    }
  }

  /// Da de baja a un miembro del equipo (HU-076 Fase 3).
  ///
  /// A diferencia de la baja vieja (que sólo ponía `activo=false` y dejaba la cuenta
  /// Auth viva), la Edge Function `dar-de-baja-usuario` BANEA la cuenta y revoca sus
  /// sesiones: el usuario deja de poder entrar, online y offline. [passwordAdmin]
  /// reconfirma la identidad del admin (se verifica server-side).
  ///
  /// Online-only: sin sesión de Supabase no hay JWT que autorice la EF. Devuelve `null`
  /// si salió bien, o un mensaje de error listo para mostrar.
  Future<String?> darDeBajaMiembro({
    required String usuarioId,
    required String passwordAdmin,
  }) async {
    if (passwordAdmin.isEmpty) {
      return 'Ingresá tu contraseña para confirmar la operación.';
    }

    final identidad = _identidad;
    if (identidad == null || !identidad.haySesion) {
      return mensajeSinConexionBaja;
    }

    try {
      await identidad.cambiarEstadoMiembroEnNube(
        usuarioId: usuarioId,
        activar: false,
        passwordAdmin: passwordAdmin,
        negocioId: _negocioActivo,
      );
      // Espeja `activo=false` local (sin re-encolar: la EF ya lo escribió server-side)
      // para que la lista y el login offline reaccionen sin esperar el próximo pull.
      // Reutiliza reconciliarActivo (HU-071): mismo update parcial marcado 'sincronizado'.
      await _usuarios.reconciliarActivo(usuarioId: usuarioId, activo: false);
      return null;
    } on ErrorBajaMiembro catch (e) {
      return _mensajeDeErrorBaja(e.codigo);
    }
  }

  /// Traduce los códigos de `dar-de-baja-usuario`. Tabla propia: los modos de falla
  /// (auto-baja, último admin) no existen en el alta ni en el reset.
  String _mensajeDeErrorBaja(String codigo) {
    switch (codigo) {
      case 'no_puede_a_si_mismo':
        return 'No podés darte de baja a vos mismo.';
      case 'ultimo_admin':
        return 'No podés dar de baja al último administrador activo del negocio.';
      case 'password_admin_incorrecta':
        return 'Tu contraseña no es correcta. Volvé a intentar.';
      case 'password_admin_requerida':
        return 'Ingresá tu contraseña para confirmar la operación.';
      case 'demasiados_intentos':
        return 'Demasiados intentos seguidos. Esperá un momento y volvé a probar.';
      case 'usuario_no_encontrado':
        return 'Ese usuario no está disponible en tu equipo.';
      case 'no_autorizado':
        return 'Solo un administrador puede dar de baja a un miembro.';
      case 'negocio_requerido':
        return mensajeSinNegocioActivo;
      case 'negocio_invalido':
        return mensajeNegocioInvalido;
      case 'no_autenticado':
        return 'Tu sesión expiró. Volvé a iniciar sesión e intentá de nuevo.';
      case 'sin_conexion':
        return mensajeSinConexionBaja;
      default:
        return 'No se pudo dar de baja al usuario. Intentá de nuevo.';
    }
  }

  /// Traduce el código estable de la Edge Function a un mensaje para el usuario.
  String _mensajeDeError(String codigo) {
    switch (codigo) {
      case 'email_en_uso':
        return 'Ese correo ya tiene una cuenta. Usá otro.';
      case 'email_invalido':
        return 'El correo electrónico no es válido.';
      case 'password_corta':
        return 'La contraseña debe tener al menos $minPassword caracteres.';
      case 'nombre_requerido':
        return 'El nombre es requerido.';
      case 'rol_no_permitido':
        return 'El rol seleccionado no es válido.';
      case 'no_autorizado':
        return 'Solo un administrador puede crear usuarios.';
      case 'negocio_requerido':
        return mensajeSinNegocioActivo;
      case 'negocio_invalido':
        return mensajeNegocioInvalido;
      case 'no_autenticado':
        return 'Tu sesión expiró. Volvé a iniciar sesión e intentá de nuevo.';
      case 'sin_conexion':
        return mensajeSinConexion;
      default:
        return 'No se pudo crear el usuario. Intentá de nuevo.';
    }
  }
}
