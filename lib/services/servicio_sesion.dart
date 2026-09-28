import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/almacen_seguro/almacen_seguro.dart';
import '../data/claves_dispositivo.dart' as claves;
import '../data/almacen_seguro/almacen_seguro_preferencias.dart';
import '../data/almacen_seguro/migracion_lectura.dart';
import 'guarda_primer_pull.dart';

/// Estado de la sesión activa (negocio, usuario y rol).
///
/// HU-077: se ELIMINÓ la elevación temporal de privilegios por PIN (el antiguo
/// patrón "sudo" de HU-043). El rol de un usuario es SIEMPRE su rol base: no
/// existe ningún camino en runtime para que un cocinero obtenga permisos de
/// administrador. La única excepción es el SuperAdmin, que al entrar a un
/// negocio actúa como admin efectivo de ese negocio (identidad distinta, no
/// una elevación del cocinero).
class ServicioSesion extends ChangeNotifier implements GuardaPrimerPull {
  // Claves de persistencia de sesión. Públicas para que otros servicios
  // (p. ej. la semilla de demostración) escriban exactamente las mismas claves.
  static const String keyNegocioId = 'insuma_negocio_id';
  static const String keyUsuarioId = 'insuma_usuario_id';
  static const String keyUsuarioNombre = 'insuma_usuario_nombre';
  static const String keyUsuarioRol = 'insuma_usuario_rol';
  // SuperAdmin global (HU-037): usuario de control que puede entrar a cualquier negocio.
  static const String keyEsSuperAdmin = 'insuma_es_superadmin';

  /// HU-266: epoch millis del login ORIGINAL. La sesión local vence de forma
  /// ABSOLUTA a los [duracionMaxSesion] de esa marca (offline-first, sin backend),
  /// para que un dispositivo perdido/compartido no quede con acceso indefinido.
  static const String keyFechaLogin = 'insuma_fecha_login';

  /// HU-266: plazo absoluto de vida de la sesión local desde el login original.
  static const Duration duracionMaxSesion = Duration(days: 30);
  // Lo que sobrevive al logout (marca de primer-pull y preferencias de
  // apariencia) se declara en `data/claves_dispositivo.dart`: no son datos de
  // sesión, y tenerlos acá obligaba al servicio de apariencia a importar éste
  // —con su almacén cifrado detrás— sólo para armar una clave.

  /// Claves de IDENTIDAD que viven en el almacén seguro (HU-036). `rol` y
  /// `es_superadmin` son las críticas: en claro eran editables y escalaban
  /// privilegios en el dispositivo (los permisos de la UI se deciden con ellas).
  static const List<String> clavesSecretas = [
    keyNegocioId,
    keyUsuarioId,
    keyUsuarioNombre,
    keyUsuarioRol,
    keyEsSuperAdmin,
    // HU-266: viaja cifrada como el resto de la identidad y —clave— se borra en
    // cerrarSesion() vía borrarClaves(clavesSecretas): una fecha huérfana que
    // sobreviva al logout haría expirar al instante la sesión siguiente.
    keyFechaLogin,
  ];

  /// HU-036: almacén CIFRADO de la identidad de sesión (Keystore/Keychain en
  /// nativo; SharedPreferences en web, donde el paquete no aporta seguridad real).
  final AlmacenSeguro _seguro;

  /// `false` en web: origen y destino de la migración son el MISMO storage, así
  /// que no hay copia vieja que mover ni borrar.
  final bool migrarDesdePrefs;

  /// Clave de la sesión de Supabase Auth (`sb-<ref>-auth-token`) para el borrado
  /// defensivo en el logout. Null si no hay backend configurado.
  final String? claveSesionSupabase;

  /// HU-266: reloj inyectable. Único seam que controla a la vez el estampado de
  /// la fecha de login y el cálculo de [sesionExpirada] → tests deterministas.
  /// En producción es `DateTime.now`.
  final DateTime Function() _ahora;

  ServicioSesion({
    AlmacenSeguro? almacenSeguro,
    this.migrarDesdePrefs = true,
    this.claveSesionSupabase,
    DateTime Function()? ahora,
  }) : _seguro = almacenSeguro ?? const AlmacenSeguroPreferencias(),
       _ahora = ahora ?? DateTime.now;

  SharedPreferences? _prefs;

  /// Caché en memoria de la identidad, hidratada en [inicializar]. Existe para
  /// que los getters sigan siendo SÍNCRONOS (el almacén seguro es async y los
  /// consumen ~20 archivos, incluido GuardiaPermiso): la API pública no cambia.
  final Map<String, String> _cache = {};

  String get negocioId => _cache[keyNegocioId] ?? '';
  String get usuarioId => _cache[keyUsuarioId] ?? '';
  String get usuarioNombre => _cache[keyUsuarioNombre] ?? '';

  /// Rol con el que la app decide TODOS los permisos. Es el rol base de la
  /// sesión: no hay elevación posible (HU-077).
  String get usuarioRol => _cache[keyUsuarioRol] ?? '';

  bool get esSuperAdmin => _cache[keyEsSuperAdmin] == 'true';

  /// HU-266: la sesión local venció (pasaron [duracionMaxSesion] desde el login).
  /// SÍNCRONO, contra [_cache] (no toca el almacén async): [estaAutenticado] —que
  /// lo usa el enrutado raíz (PantallaInicial)— y los getters de identidad que
  /// consume la app (p. ej. GuardiaPermiso vía `usuarioRol`) tienen que seguir
  /// siendo síncronos. Sin fecha o fecha ilegible ⇒ NO vencida (el backfill de
  /// [inicializar] la estampa en instalaciones viejas). Reloj hacia atrás
  /// (diferencia negativa) ⇒ no vencida.
  ///
  /// El flip a `true` es puro cálculo del reloj y NO dispara notifyListeners: se
  /// aplica al ARRANCAR ([descartarSesionSiVencida], que sí purga y notifica). Si
  /// la sesión cruza el plazo con la app abierta (requiere ~30 días continuos),
  /// PantallaInicial recién re-enruta al login en el próximo reinicio o cambio de
  /// sesión; no se agrega un timer por ser un caso extremo.
  bool get sesionExpirada {
    final crudo = _cache[keyFechaLogin];
    if (crudo == null) return false;
    final loginMs = int.tryParse(crudo);
    if (loginMs == null) return false;
    final transcurrido = _ahora().millisecondsSinceEpoch - loginMs;
    return transcurrido >= duracionMaxSesion.inMilliseconds;
  }

  // Un SuperAdmin está autenticado aunque todavía no haya elegido un negocio activo.
  // HU-266: una sesión vencida NO está autenticada, aunque la identidad siga en
  // caché (defensa en profundidad: vale aunque la purga de arranque no corriera).
  bool get estaAutenticado =>
      (negocioId.isNotEmpty || esSuperAdmin) && !sesionExpirada;
  bool get esAdmin => usuarioRol == 'admin';

  Future<void> inicializar() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    // HU-036: read-through. Lo que falte en el almacén seguro se toma de la copia
    // vieja EN CLARO, se cifra y se borra la vieja → las instalaciones existentes
    // NO se desloguean al actualizar.
    for (final clave in clavesSecretas) {
      final valor = await leerOMigrar(
        seguro: _seguro,
        prefs: prefs,
        clave: clave,
        // `es_superadmin` se guardaba como bool en prefs.
        lectorViejo: clave == keyEsSuperAdmin ? lectorBoolViejo : null,
        migrar: migrarDesdePrefs,
      );
      if (valor != null) _cache[clave] = valor;
    }
    // HU-266: una instalación ya logueada ANTES de esta versión no tiene fecha de
    // login. En vez de deslogearla (mala UX) o dejarla sin vencer nunca (agujero),
    // se estampa "ahora" una sola vez: arranca su plazo de 30 días desde el primer
    // arranque con esta versión.
    //
    // OJO (web): AlmacenSeguroPreferencias NO cifra (localStorage). Como el
    // backfill re-estampa en cada arranque donde falte la clave, alguien con
    // devtools puede borrarla y renovar el plazo indefinidamente. En web la
    // expiración es ORIENTATIVA, no forzada — igual que el vector del reloj y que
    // `rol`/`es_superadmin`, que ya viven sin cifrar y son peores de manipular. La
    // HU acepta este límite; el blindaje real es nativo (Keystore/Keychain).
    if (estaAutenticado && _cache[keyFechaLogin] == null) {
      await _guardar(keyFechaLogin, _ahora().millisecondsSinceEpoch.toString());
    }
  }

  /// Escribe una clave de identidad en la caché y en el almacén seguro.
  Future<void> _guardar(String clave, String valor) async {
    _cache[clave] = valor;
    await _seguro.escribir(clave, valor);
  }

  Future<void> _quitar(String clave) async {
    _cache.remove(clave);
    await _seguro.borrar(clave);
  }

  Future<void> guardarSesion({
    required String negocioId,
    required String usuarioId,
    required String nombre,
    required String rol,
  }) async {
    await _guardar(keyNegocioId, negocioId);
    await _guardar(keyUsuarioId, usuarioId);
    await _guardar(keyUsuarioNombre, nombre);
    await _guardar(keyUsuarioRol, rol);
    await _guardar(keyEsSuperAdmin, 'false');
    // HU-266: marca del login para la expiración absoluta. Va acá (y en
    // guardarSesionSuperAdmin), NO en entrarANegocio/salirDeNegocio: navegar
    // entre negocios no renueva el plazo.
    await _guardar(keyFechaLogin, _ahora().millisecondsSinceEpoch.toString());
    notifyListeners();
  }

  /// Inicia sesión como SuperAdmin global (HU-037). Todavía SIN negocio activo:
  /// el SuperAdmin primero elige a qué negocio entrar desde el selector.
  Future<void> guardarSesionSuperAdmin({
    required String usuarioId,
    required String nombre,
  }) async {
    await _guardar(keyEsSuperAdmin, 'true');
    await _guardar(keyUsuarioId, usuarioId);
    await _guardar(keyUsuarioNombre, nombre);
    await _guardar(keyUsuarioRol, 'superadmin');
    await _quitar(keyNegocioId);
    // HU-266: el SuperAdmin también expira (es el que se olvida fácil). Marca del
    // login SA; entrarANegocio/salirDeNegocio no la tocan (expiración absoluta).
    await _guardar(keyFechaLogin, _ahora().millisecondsSinceEpoch.toString());
    notifyListeners();
  }

  /// El SuperAdmin entra a gestionar un negocio: pasa a ser admin EFECTIVO de ese
  /// negocio (acceso completo) conservando su identidad de SuperAdmin para poder volver.
  Future<void> entrarANegocio({required String negocioId}) async {
    await _guardar(keyNegocioId, negocioId);
    await _guardar(keyUsuarioRol, 'admin');
    notifyListeners();
  }

  /// El SuperAdmin sale del negocio y vuelve al selector (mantiene la sesión SA).
  Future<void> salirDeNegocio() async {
    await _quitar(keyNegocioId);
    await _guardar(keyUsuarioRol, 'superadmin');
    notifyListeners();
  }

  Future<void> cerrarSesion() async {
    // HU-036: la identidad vive cifrada → se borra del almacén seguro (y de la
    // caché). Se suma el borrado DEFENSIVO de la sesión de Supabase Auth: antes
    // el barrido de prefs la eliminaba de rebote; ahora vive en el almacén y
    // `signOut()` (que la borra vía el adapter) puede fallar offline.
    _cache.clear();
    await _seguro.borrarClaves(clavesSecretas);
    final claveSupabase = claveSesionSupabase;
    if (claveSupabase != null) await _seguro.borrar(claveSupabase);

    final prefs = _prefs;
    if (prefs != null) {
      // Se borra todo MENOS lo que es del dispositivo (ver [prefijosDelDispositivo]:
      // marcas de primer-pull de HU-090 y preferencias de apariencia de HU-054).
      // El barrido es por descarte a propósito: una clave de sesión nueva queda
      // cubierta sin que nadie tenga que acordarse de sumarla acá.
      final aBorrar = prefs
          .getKeys()
          .where((k) => !claves.prefijosDelDispositivo.any(k.startsWith))
          .toList();
      for (final k in aBorrar) {
        await prefs.remove(k);
      }
    }
    notifyListeners();
  }

  /// HU-266: si la sesión local venció, la descarta por completo (mismo camino
  /// que [cerrarSesion]: identidad + clave de Supabase Auth + barrido de prefs,
  /// SuperAdmin incluido), para no dejar una identidad "stale" a medias. Devuelve
  /// `true` si descartó algo. La llama `main` justo tras [inicializar], antes de
  /// armar la sincronización, para que una sesión vencida no dispare el pull.
  Future<bool> descartarSesionSiVencida() async {
    if (!sesionExpirada) return false;
    await cerrarSesion();
    return true;
  }

  // ─── HU-090: guarda del primer pull ────────────────────────────────────────
  @override
  bool primerPullHecho(String negocioId) =>
      _prefs?.getBool('${claves.prefijoPrimerPull}$negocioId') ?? false;

  @override
  Future<void> marcarPrimerPull(String negocioId) async {
    if (negocioId.isEmpty) return;
    await _prefs?.setBool('${claves.prefijoPrimerPull}$negocioId', true);
  }
}
