import 'package:insuma/constants/politica_password.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:uuid/uuid.dart';
import '../data/repositorios/repositorio_negocios.dart';
import '../data/repositorios/repositorio_usuarios.dart';
import '../data/repositorios/repositorio_identidad_remota.dart';
import '../utils/validador_datos.dart';
import 'servicio_activacion.dart';
import 'servicio_autenticacion.dart';
import 'servicio_gestion_equipo.dart';
import 'servicio_sesion.dart';

/// Resultado del alta de un negocio (HU-088).
///
/// Existe porque el alta tiene DOS desenlaces que no se pueden colapsar en un solo
/// `String?`: o falla el negocio (no se creó nada), o el negocio se creó pero algún
/// miembro del equipo no pudo provisionarse en la nube. En el segundo caso el alta
/// ES exitosa —la cuenta del admin ya existe y no hay forma de deshacerla desde el
/// cliente—, así que se entra a la app y se informa qué miembros quedaron pendientes.
class ResultadoRegistro {
  /// Mensaje de error si falló el alta del NEGOCIO. Null si el negocio se creó.
  final String? error;

  /// Miembros que el backend rechazó (p. ej. su email ya tenía cuenta). El negocio
  /// existe: el admin puede darlos de alta después desde Gestionar Equipo.
  final List<String> miembrosNoCreados;

  const ResultadoRegistro.exito({this.miembrosNoCreados = const []})
    : error = null;
  const ResultadoRegistro.fallo(String this.error)
    : miembrosNoCreados = const [];

  bool get exitoso => error == null;
}

/// Datos capturados por el onboarding para dar de alta un negocio (HU-075).
class DatosRegistroNegocio {
  final String nombreNegocio;
  final String tipoNegocio;
  final String email;
  final String password;
  final String nombreAdmin;

  /// Código de activación emitido por el SuperAdmin. Sin él no hay alta.
  final String codigoActivacion;

  /// Equipo cargado en el paso 6: `{nombre, rol, email, password}`.
  final List<Map<String, dynamic>> usuariosEquipo;

  const DatosRegistroNegocio({
    required this.nombreNegocio,
    required this.tipoNegocio,
    required this.email,
    required this.password,
    required this.nombreAdmin,
    required this.codigoActivacion,
    required this.usuariosEquipo,
  });
}

/// Servicio de alta de un negocio nuevo (HU-001 / HU-075).
///
/// Concentra la lógica que vivía en `ControladorOnboarding.finalizarOnboarding`
/// (deuda que HU-072 dejó anotada a propósito, porque esta HU la reescribe).
///
/// **Regla de seguridad (HU-075): sin conexión no se crea un negocio.** El alta
/// exige validar contra el backend un código de activación emitido por el
/// SuperAdmin; si no hay backend o no hay red, se rechaza. De lo contrario
/// cualquiera podría darse de alta estando offline.
///
/// El orden importa: **primero el alta remota, después el espejo local**. Si el
/// código es inválido o no hay red, `registrarCuenta` lanza y se corta ANTES de
/// escribir nada local, así un rechazo no deja un negocio huérfano.
class ServicioRegistroNegocio {
  /// Largo mínimo de contraseña. HU-112: unificado con el resto de los flujos vía
  /// [PoliticaPassword.longitudMinima] (10). Es más estricto que el mínimo de
  /// Supabase Auth (`minimum_password_length`, 8), lo cual está bien: la app rechaza
  /// antes de llegar al backend.
  static const minimoPassword = PoliticaPassword.longitudMinima;

  final ServicioGestionEquipo? _gestionEquipo;
  final ServicioSesion _sesion;
  final RepositorioNegocios _negocios;
  final RepositorioUsuarios _usuarios;
  final RepositorioIdentidadRemota? _identidad;
  final ServicioActivacion? _activacion;

  /// [identidad], [activacion] y [gestionEquipo] son null si no hay backend
  /// configurado; en ese caso el alta se rechaza con
  /// [ServicioActivacion.mensajeSinConexion].
  ServicioRegistroNegocio(
    this._sesion,
    this._negocios,
    this._usuarios, [
    this._identidad,
    this._activacion,
    this._gestionEquipo,
  ]);

  /// Da de alta el negocio, su administrador y su equipo.
  ///
  /// HU-088: los miembros del equipo ya NO se crean sólo en local. Cada uno recibe
  /// una cuenta Supabase Auth real vía la Edge Function `crear-miembro`, igual que
  /// los que se dan de alta desde Gestionar Equipo. Antes, este camino seguía
  /// fabricando "miembros heredados" (sin cuenta en la nube, atados a un único
  /// dispositivo), que es justamente lo que esta HU viene a erradicar.
  Future<ResultadoRegistro> registrar(DatosRegistroNegocio datos) async {
    if (datos.nombreAdmin.trim().isEmpty) {
      return const ResultadoRegistro.fallo(
        'Debe ingresar el nombre del administrador.',
      );
    }
    if (!ValidadorDatos.validarEmail(datos.email)) {
      return const ResultadoRegistro.fallo('Debe ingresar un email válido.');
    }
    if (datos.password.length < minimoPassword) {
      return const ResultadoRegistro.fallo(
        'La contraseña debe tener al menos $minimoPassword caracteres.',
      );
    }

    final identidad = _identidad;
    final activacion = _activacion;
    final gestionEquipo = _gestionEquipo;
    // Sin backend no hay forma de validar el código ni de crear las cuentas del
    // equipo en la nube: no se permite el alta.
    if (identidad == null || activacion == null || gestionEquipo == null) {
      return const ResultadoRegistro.fallo(
        ServicioActivacion.mensajeSinConexion,
      );
    }

    final emailAdmin = datos.email.trim().toLowerCase();

    // VALIDACIÓN PREVIA DEL EQUIPO (HU-088). Se hace ANTES del alta remota porque el
    // `signUp` es irreversible desde el cliente: si un miembro tiene la contraseña
    // corta o el email repetido, hay que rechazarlo mientras no se creó nada todavía.
    // Usa el MISMO validador que Gestionar Equipo, así el umbral no puede divergir.
    final miembros = <DatosNuevoMiembro>[];
    final emailsVistos = <String>{emailAdmin};
    for (final u in datos.usuariosEquipo) {
      final miembro = DatosNuevoMiembro(
        nombre: (u['nombre'] as String?) ?? '',
        email: ((u['email'] as String?) ?? '').trim().toLowerCase(),
        password: (u['password'] as String?) ?? '',
        rol: (u['rol'] as String?) ?? '',
      );
      final errorMiembro = gestionEquipo.validar(miembro);
      if (errorMiembro != null) {
        return ResultadoRegistro.fallo(
          'Usuario "${miembro.nombre.trim()}": $errorMiembro',
        );
      }
      if (!emailsVistos.add(miembro.email)) {
        return ResultadoRegistro.fallo(
          'El correo ${miembro.email} está repetido. Cada integrante necesita su propio correo.',
        );
      }
      miembros.add(miembro);
    }

    // Validación previa del código: da un mensaje claro ANTES de intentar el alta. El
    // consumo real (atómico, a prueba de carreras) lo hace el trigger del backend.
    final errorCodigo = await activacion.validar(datos.codigoActivacion);
    if (errorCodigo != null) return ResultadoRegistro.fallo(errorCodigo);

    try {
      final uuid = const Uuid();
      final negocioId = uuid.v4();
      final adminId = uuid.v4();

      // 1. Alta remota. El trigger `handle_new_user` provisiona negocio + admin +
      //    configuración con estos MISMOS UUID, y `enforce_codigo_activacion`
      //    consume el código en la misma transacción.
      try {
        await identidad.registrarCuenta(
          email: emailAdmin,
          password: datos.password,
          metadata: {
            'negocio_id': negocioId,
            'negocio_nombre': datos.nombreNegocio.trim(),
            'negocio_tipo': datos.tipoNegocio,
            'usuario_id': adminId,
            'usuario_nombre': datos.nombreAdmin.trim(),
            'rol': 'admin',
            'pais': 'Argentina',
            'codigo_activacion': activacion.normalizar(datos.codigoActivacion),
          },
        );
      } on AuthException catch (e) {
        return ResultadoRegistro.fallo(
          'No se pudo registrar la cuenta: ${e.message}',
        );
      } catch (_) {
        return const ResultadoRegistro.fallo(
          'No hay conexión para registrar la cuenta. Verificá tu internet e intentá nuevamente.',
        );
      }

      // 2. Espejo local del negocio y del admin. NO se encolan: ya existen en el
      //    backend (los creó el trigger).
      await _negocios.espejarLocal(
        id: negocioId,
        nombre: datos.nombreNegocio.trim(),
        tipo: datos.tipoNegocio,
        email: emailAdmin.isEmpty ? null : emailAdmin,
      );
      await _usuarios.espejarLocal(
        id: adminId,
        negocioId: negocioId,
        nombre: datos.nombreAdmin.trim(),
        rol: 'admin',
        email: emailAdmin,
        // HU-133: el KDF corre en un isolate aparte para no congelar el spinner
        // del alta (mismo motivo que en el login).
        passwordHash: await ServicioAutenticacion.hashearPasswordAsync(
          datos.password,
          salt: emailAdmin,
        ),
      );

      // 3. Equipo: cuenta real en la nube por cada miembro (Edge Function). Se hace
      //    DESPUÉS del `signUp` por necesidad: la Edge Function autoriza con el JWT del
      //    admin, que no existe hasta que el admin tiene sesión.
      //    Si alguno falla (su email ya tenía cuenta), NO se cae a un alta local: eso
      //    recrearía al miembro sin cuenta en la nube. Se informa y el admin lo reintenta
      //    desde Gestionar Equipo, con el negocio ya creado.
      final miembrosNoCreados = <String>[];
      for (final miembro in miembros) {
        final errorMiembro = await gestionEquipo.crearMiembro(miembro);
        if (errorMiembro != null) {
          miembrosNoCreados.add('${miembro.email}: $errorMiembro');
        }
      }

      // 4. Sesión activa.
      await _sesion.guardarSesion(
        negocioId: negocioId,
        usuarioId: adminId,
        nombre: datos.nombreAdmin.trim(),
        rol: 'admin',
      );
      // HU-090: un negocio recién creado no tiene nada que bajar → está hidratado por
      // definición; se marca su primer pull para no bloquear la operación inmediata.
      await _sesion.marcarPrimerPull(negocioId);

      return ResultadoRegistro.exito(miembrosNoCreados: miembrosNoCreados);
    } catch (e) {
      return ResultadoRegistro.fallo(
        'Ocurrió un error al guardar los datos del negocio: $e',
      );
    }
  }
}
