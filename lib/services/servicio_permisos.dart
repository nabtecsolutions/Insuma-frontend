/// Autorización basada en roles (RBAC — Role-Based Access Control) de INSUMA.
///
/// Única fuente de verdad sobre "qué puede hacer cada rol". En lugar de comparar
/// strings sueltos (`rol == 'admin'`) repartidos por toda la app —frágil y fácil
/// de olvidar—, todo el código pregunta acá: `Permisos.puede(rol, Permiso.x)`.
///
/// Sumar un permiso nuevo o un rol nuevo se hace en UN solo lugar (este archivo).
library;

/// Acciones sensibles que la app protege por rol.
enum Permiso {
  /// Ver información financiera: métricas, márgenes, costos y alertas de precio.
  verFinanzas,

  /// Crear, editar y archivar recetas.
  gestionarRecetas,

  /// Gestionar el equipo: agregar y dar de baja usuarios.
  gestionarEquipo,

  /// #273: ver quién hizo cada paso de un pedido y cuándo.
  ///
  /// Eje propio y no `verFinanzas`, por decisión del PO: el bloque es entero o
  /// nada. Mezcla pasos operativos (quién creó, envió, recibió) con financieros
  /// (quién facturó, pagó), y partirlo por permiso daría una lista con huecos
  /// que se lee como si esos pasos no hubieran ocurrido.
  verTrazabilidad,
}

/// Definición de un rol: cómo se llama y qué puede hacer.
///
/// Etiqueta y permisos van JUNTOS, en una sola estructura, para que un rol nuevo
/// no pueda nacer sin nombre. Con un mapa de permisos y un `switch` de etiquetas
/// aparte —que fue el primer intento— agregar 'auditor' compilaba, otorgaba los
/// permisos bien y en la UI lo rotulaba "Cocinero" por el caso por defecto:
/// exactamente el defecto que la etiqueta vino a arreglar, un nivel más arriba.
typedef DefinicionRol = ({String etiqueta, Set<Permiso> permisos});

/// Tabla de autorización rol → permisos otorgados.
class Permisos {
  const Permisos._();

  static const Map<String, DefinicionRol> _porRol = {
    'admin': (
      etiqueta: 'Administrador',
      permisos: {
        Permiso.verFinanzas,
        Permiso.gestionarRecetas,
        Permiso.gestionarEquipo,
        Permiso.verTrazabilidad,
      },
    ),
    // El SuperAdmin (HU-037), al entrar a un negocio, actúa como admin efectivo.
    //
    // #273: LEER la trazabilidad sí puede —lee todo por diseño—; lo que no
    // puede es escribir, y este permiso no habilita ninguna escritura.
    'superadmin': (
      etiqueta: 'SuperAdmin',
      permisos: {
        Permiso.verFinanzas,
        Permiso.gestionarRecetas,
        Permiso.gestionarEquipo,
        Permiso.verTrazabilidad,
      },
    ),
    // El cocinero (operador de cocina) no accede a información ni acciones sensibles.
    'cocinero': (etiqueta: 'Cocinero', permisos: {}),
  };

  /// Indica si [rol] tiene concedido el [permiso]. Roles desconocidos → sin permiso.
  static bool puede(String rol, Permiso permiso) =>
      _porRol[rol]?.permisos.contains(permiso) ?? false;

  /// Conjunto de permisos de un rol (vacío si el rol es desconocido).
  static Set<Permiso> deRol(String rol) => _porRol[rol]?.permisos ?? const {};

  /// Nombre del rol para mostrarle al usuario (HU-054).
  ///
  /// Existe porque el atajo `esAdmin ? 'Administrador' : 'Cocinero'`, que estaba
  /// escrito en el AppBar, etiquetaba al **SuperAdmin como Cocinero**: `esAdmin`
  /// compara contra `'admin'` a secas y el rol `'superadmin'` no matchea. Al ser
  /// un binario, cada rol que se agregue cae del lado equivocado en silencio.
  ///
  /// Un rol desconocido ya se trata como cocinero para los permisos
  /// ([parsearRol]); acá se dice lo mismo, sin inventar un nombre.
  static String etiquetaDeRol(String rol) =>
      _porRol[rol]?.etiqueta ?? _porRol[rolPorDefecto]!.etiqueta;

  /// Rol seguro por defecto: el de MENOR privilegio. Se usa cuando el rol viene
  /// ausente, vacío o no reconocido, para no otorgar acceso de más (fail-closed).
  static const String rolPorDefecto = 'cocinero';

  /// Normaliza un valor de rol CRUDO (de la nube, un mapa JSON de PostgREST, etc.)
  /// a un rol válido y conocido. Punto ÚNICO de parseo de rol del cliente: cualquier
  /// valor nulo, no-string, vacío o desconocido cae en [rolPorDefecto] en lugar de
  /// heredar privilegios de más. Antes cada sitio ponía su propio default y uno
  /// caía a 'admin' (fail-open) — HU-108.
  static String parsearRol(Object? valor) {
    final rol = valor is String ? valor.trim() : '';
    return _porRol.containsKey(rol) ? rol : rolPorDefecto;
  }
}
