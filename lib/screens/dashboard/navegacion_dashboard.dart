import '../../services/servicio_permisos.dart';

/// Pestañas de la barra de navegación principal del dashboard.
///
/// El antiguo `recibir` se dividió en dos (separar el ciclo del PEDIDO del ciclo
/// de la RECEPCIÓN): `pedidos` (crear/confirmar/parciales) y `recepciones` (recibir
/// lo que el proveedor ya confirmó). El orden es pedidos → recepciones porque crear
/// precede a recibir.
enum PestanaDashboard { pedidos, recepciones, proveedores, recetas, metricas }

/// Decide qué pestañas se muestran en la navegación principal según el permiso
/// financiero del usuario (HU-053).
///
/// La pestaña **Métricas** solo se renderiza para quien puede ver finanzas (admin
/// o superadmin). Para el cocinero no se incluye, de modo que la View ni siquiera
/// instancia su pantalla (no dispara consultas de métricas). Las demás pestañas
/// están siempre presentes.
///
/// Es una función PURA (sin Flutter ni IO) para poder testear la regla de
/// visibilidad sin levantar un widget.
List<PestanaDashboard> pestanasVisibles({required bool puedeVerFinanzas}) {
  return [
    PestanaDashboard.pedidos,
    PestanaDashboard.recepciones,
    PestanaDashboard.proveedores,
    PestanaDashboard.recetas,
    if (puedeVerFinanzas) PestanaDashboard.metricas,
  ];
}

// ═══════════════════════════════════════════════════════════════════════════
// Menú lateral (HU-048 / #164)
// ═══════════════════════════════════════════════════════════════════════════

/// Los bloques del menú, en orden de aparición.
///
/// El [encabezado] vacío significa "sin título": la sección operativa arranca el
/// menú y no necesita rótulo. Una sección se dibuja SÓLO si el usuario tiene al
/// menos una entrada suya; si no, no existe — ni su encabezado (mínimo
/// privilegio, HU-077).
enum SeccionMenu {
  operativa(''),
  administracion('Administración'),
  // HU-054: no es operativa ni administrativa. Cada uno ajusta cómo ve SU app,
  // sin importar el rol, así que va en su propio bloque y al final: es lo que
  // menos se usa en el día a día.
  preferencias('Preferencias');

  const SeccionMenu(this.encabezado);

  final String encabezado;
}

/// Las entradas del menú lateral, en ORDEN DE APARICIÓN.
///
/// Es un enhanced enum y no un enum + una lista paralela: con dos estructuras
/// había que testear que coincidieran, o sea que el diseño permitía el error en
/// vez de impedirlo. Acá una entrada nueva nace con su título, su sección y su
/// permiso; desincronizarlos es imposible.
///
/// **Historial de pedidos** e **Insumos** no piden permiso a propósito: son
/// operativos y el cocinero los usa (arma pedidos con insumos y consulta el
/// historial). Es la decisión de HU-077, POSTERIOR al texto de HU-048 que pedía
/// ocultarle el menú entero: lo que se le oculta es la sección Administración,
/// no el acceso a su propio trabajo. La pantalla de Insumos ya se autolimita
/// (lectura sin costos) para quien no tiene permiso financiero.
enum ItemMenu {
  historialPedidos('Historial de pedidos', SeccionMenu.operativa, null),
  insumos('Insumos', SeccionMenu.operativa, null),
  pagos('Pagos', SeccionMenu.administracion, Permiso.verFinanzas),
  // El permiso de `motivos` es el que YA guarda su pantalla
  // (`motivos_recepcion_screen.dart`), no una decisión de esta HU: se conserva
  // para que menú y guardia coincidan. Dicho eso, `gestionarRecetas` no es lo
  // que gobierna configurar recepciones; en cuanto exista un rol que maneje
  // recetas pero no configuración, el menú va a mostrar la entrada equivocada.
  // Merece su propio permiso, cambiando enum y guardia a la vez.
  motivos(
    'Motivos de recepción',
    SeccionMenu.administracion,
    Permiso.gestionarRecetas,
  ),
  // #262: catálogo de categorías de insumo. Usa `gestionarRecetas` porque es el
  // MISMO permiso de gestión de catálogo que ya gobierna insumos (ver
  // controlador_insumos.puedeCrearInsumos e insumos_screen) — decisión del PO de
  // reusar ese permiso, no crear uno nuevo.
  categorias(
    'Categorías',
    SeccionMenu.administracion,
    Permiso.gestionarRecetas,
  ),
  // HU-054: sin permiso, y no por descuido. Es el panel donde uno agranda la
  // letra: condicionarlo al rol le negaría al cocinero una función de
  // accesibilidad. Su pantalla tampoco lleva `GuardiaPermiso`.
  configuracion('Configuración', SeccionMenu.preferencias, null);

  const ItemMenu(this.titulo, this.seccion, this.permisoRequerido);

  final String titulo;
  final SeccionMenu seccion;

  /// Permiso necesario para verla. `null` = visible para todos los roles.
  final Permiso? permisoRequerido;
}

/// Entradas que ve quien tiene [permisos], en orden de aparición.
///
/// Recibe el CONJUNTO DE PERMISOS y no un rol a propósito: hoy ningún rol de la
/// tabla tiene un conjunto parcial (admin los tiene todos, cocinero ninguno), así
/// que filtrando por rol un bug grueso —tipo "el rol tiene algún permiso"— pasaría
/// todos los tests. Con el conjunto explícito, el filtrado POR ENTRADA se puede
/// falsar: ver los tests de permisos parciales.
///
/// Lo que un usuario no puede operar NO se devuelve: no se muestra bloqueado ni
/// deshabilitado (mismo criterio que HU-053 con Métricas y HU-060 con los costos).
List<ItemMenu> entradasVisibles(Set<Permiso> permisos) => ItemMenu.values
    .where(
      (i) =>
          i.permisoRequerido == null || permisos.contains(i.permisoRequerido),
    )
    .toList();

/// Atajo para la UI, que tiene el rol y no el conjunto.
///
/// Un rol desconocido cae en un conjunto vacío ([Permisos.deRol] devuelve `{}`),
/// así que hereda la vista más acotada en vez de abrirse por defecto.
List<ItemMenu> entradasVisiblesDeRol(String rol) =>
    entradasVisibles(Permisos.deRol(rol));
