import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../data/repositorios/repositorio_pedidos.dart';
import '../utils/fecha_recepcion.dart';
import '../utils/id_determinista.dart';
import '../utils/validador_pedido.dart';
import '../utils/repetir_pedido.dart';
import '../utils/estados_pedido.dart';
import '../utils/transiciones_pedido.dart';
import '../models/insumo_ofrecido.dart';
import 'servicio_proveedor_categorias.dart';
import 'servicio_transiciones_pedido.dart';

/// Datos del formulario activo de creación/edición de un pedido (HU-010 / HU-059).
///
/// Objeto de transferencia que traslada el estado del formulario del controlador
/// al [ServicioPedidos], para que la lógica de negocio no lea el estado de la
/// vista. Los [items] son los del formulario en crudo, con la forma
/// `{insumoId, nombre, unidad, cantidad, costoUnitario, proveedorId}`.
class DatosFormularioPedido {
  final String negocioId;
  final String? proveedorId;
  final String? proveedorNombre;
  final List<Map<String, dynamic>> items;
  final String? nota;
  final bool tieneEfectivo;
  final String? creadoPor;
  final String? creadoPorNombre;

  /// Id del pedido en edición, o null si es un pedido nuevo.
  final String? pedidoEdicionId;

  /// HU-142: día en que se pide recibir la mercadería. OPCIONAL (decisión del
  /// PO): `null` es un valor válido y significa "sin fecha pedida".
  final DateTime? fechaRecepcionSolicitada;

  const DatosFormularioPedido({
    required this.negocioId,
    required this.proveedorId,
    required this.proveedorNombre,
    required this.items,
    required this.nota,
    required this.tieneEfectivo,
    required this.creadoPor,
    required this.creadoPorNombre,
    required this.pedidoEdicionId,
    this.fechaRecepcionSolicitada,
  });
}

/// Snapshot de datos que necesita la pantalla de Compras al (re)cargar: usuario
/// activo, proveedores activos y pedidos del negocio.
class DatosSesionPedidos {
  final Usuario? usuario;
  final List<Proveedore> proveedores;
  final List<Pedido> pedidos;
  const DatosSesionPedidos({
    required this.usuario,
    required this.proveedores,
    required this.pedidos,
  });
}

/// Resultado de preparar los ítems del formulario para persistir.
typedef _ItemsPreparados = ({String jsonItems, double total, int cantidad});

/// Servicio de negocio del módulo Compras/Pedidos (HU-010 / HU-059).
///
/// Concentra TODA la lógica de negocio antes dispersa en `ControladorRecibir`:
/// creación/edición/envío de pedidos, validaciones, cálculo de totales,
/// re-pedidos y precarga de precio estimado. La persistencia y el encolado de
/// sincronización se delegan íntegramente en [RepositorioPedidos].
class ServicioPedidos {
  final RepositorioPedidos _repo;

  /// Autoridad de los cambios de estado (HU-141): valida contra la matriz y
  /// audita. Los métodos de estado de este servicio son fachadas hacia él.
  final ServicioTransicionesPedido _transiciones;

  /// Relación proveedor↔categoría (#262). OPCIONAL a propósito: sin ella el
  /// selector de insumos por categoría queda vacío (los llamadores viejos siguen
  /// compilando). Reemplazó al catálogo de suministro insumo↔proveedor (HU-138),
  /// retirado con el rediseño: los insumos ya no cuelgan de un proveedor.
  final ServicioProveedorCategorias? _proveedorCategorias;

  ServicioPedidos(this._repo, this._transiciones, [this._proveedorCategorias]);

  // --- Lecturas para la vista ---------------------------------------------

  /// Carga el snapshot inicial del módulo (usuario activo, proveedores y pedidos).
  Future<DatosSesionPedidos> cargarSesion(
    String negocioId,
    String usuarioId,
  ) async {
    final usuario = await _repo.obtenerUsuario(usuarioId);
    final proveedores = await _repo.proveedoresActivos(negocioId);
    final pedidos = await _repo.listarPorNegocio(negocioId);
    return DatosSesionPedidos(
      usuario: usuario,
      proveedores: proveedores,
      pedidos: pedidos,
    );
  }

  /// Stream reactivo de los pedidos del negocio (HU-089): la UI se actualiza sola cuando
  /// el pull deposita filas o tras una mutación, sin recarga manual.
  Stream<List<Pedido>> observarPedidos(String negocioId) =>
      _repo.observarPorNegocio(negocioId);

  /// Stream reactivo de los proveedores activos del negocio (HU-096): el selector del
  /// formulario de pedido se actualiza solo cuando el pull deposita filas, sin recarga
  /// manual. Espejo de [observarPedidos] para el picker de proveedores.
  Stream<List<Proveedore>> observarProveedores(String negocioId) =>
      _repo.observarProveedoresActivos(negocioId);

  /// Qué insumos se le ofrecen a quien arma un pedido, AGRUPADOS por categoría
  /// (#262).
  ///
  /// Modelo ESTRICTO (decisión del PO): un desplegable por cada categoría que el
  /// proveedor tiene asignada, con los insumos que le pertenecen. Para pedir algo
  /// de una categoría que el proveedor no suministra, primero hay que asignársela
  /// en su ficha. Reemplaza al viejo par (delProveedor/otros) del eje
  /// insumo↔proveedor de HU-073/HU-138.
  ///
  /// Un insumo sin `categoriaId` (creado offline y todavía sin derivar del lado
  /// del servidor, o con su categoría dada de baja) cae en la categoría
  /// "Sin categoría" del negocio: aparece sólo si el proveedor la suministra.
  Future<List<GrupoCategoriaOfrecida>> insumosOfrecidos({
    required String negocioId,
    required String proveedorId,
  }) async {
    if (_proveedorCategorias == null) return const [];
    // Categorías activas que suministra el proveedor, ya ordenadas por nombre.
    final categorias = await _proveedorCategorias.categoriasDe(
      negocioId,
      proveedorId,
    );
    if (categorias.isEmpty) return const [];

    final activos = await _repo.insumosActivos(negocioId);
    // Fallback de lectura: un insumo sin categoría se agrupa bajo "Sin categoría".
    final sinCategoriaId = IdDeterminista.categoria(negocioId, 'sin categoría');

    // Índice insumos por categoría, en una pasada.
    final porCategoria = <String, List<Insumo>>{};
    for (final insumo in activos) {
      final catId = insumo.categoriaId ?? sinCategoriaId;
      (porCategoria[catId] ??= <Insumo>[]).add(insumo);
    }

    final grupos = <GrupoCategoriaOfrecida>[];
    for (final categoria in categorias) {
      final insumosDeCat = porCategoria[categoria.id] ?? const <Insumo>[];
      final ofrecidos = <InsumoOfrecido>[];
      for (final insumo in insumosDeCat) {
        final r = await resolverPrecio(
          insumoId: insumo.id,
          proveedorId: proveedorId,
        );
        ofrecidos.add(
          InsumoOfrecido(insumo: insumo, precio: r.precio, origen: r.origen),
        );
      }
      grupos.add(
        GrupoCategoriaOfrecida(categoria: categoria, insumos: ofrecidos),
      );
    }
    return grupos;
  }

  Future<double> precioEstimado({
    required String insumoId,
    String? proveedorId,
  }) async => (await resolverPrecio(
    insumoId: insumoId,
    proveedorId: proveedorId,
  )).precio;

  /// Precio de REFERENCIA a ofrecer para un insumo, y de dónde salió.
  ///
  /// Cascada de siempre: último historial de ese proveedor → último historial de
  /// cualquiera → caché del insumo → 0. El "precio de lista pactado por
  /// proveedor" (escalón 0 de HU-138) se abandonó con #262: el costo se estima
  /// sobre el último real tras procesar la recepción.
  ///
  /// Vive en el Service y no en el repositorio ni en `BaseDatosApp` porque es
  /// una regla de negocio, no acceso a datos (CLAUDE.md §3).
  Future<({double precio, OrigenPrecioOfrecido origen})> resolverPrecio({
    required String insumoId,
    String? proveedorId,
  }) async {
    final delHistorial = await _repo.precioEstimadoItem(
      insumoId: insumoId,
      proveedorId: proveedorId,
    );
    return (
      precio: delHistorial,
      origen: delHistorial > 0
          ? OrigenPrecioOfrecido.referencia
          : OrigenPrecioOfrecido.sinPrecio,
    );
  }

  /// Teléfono y email del proveedor, para WhatsApp (HU-011/063) y correo (#235).
  Future<({String? telefono, String? email})> contactoProveedor(
    String proveedorId,
  ) => _repo.contactoProveedor(proveedorId);

  /// Filtra una selección de insumos quedándose con los que tienen cantidad real
  /// (HU-140).
  ///
  /// La regla "cantidad 0 no se agrega" vive ACÁ y no en la pantalla: es la misma
  /// que `_prepararItems` aplica al guardar el pedido, sólo que ahora se aplica
  /// también al entrar. Marcar un insumo y dejarlo en 0 es decir "al final no",
  /// no "pedime cero".
  List<({InsumoOfrecido ofrecido, double cantidad})> itemsDeSeleccion(
    List<({InsumoOfrecido ofrecido, double cantidad})> seleccion,
  ) => seleccion.where((s) => s.cantidad > 0).toList();

  // --- Escrituras / lógica de negocio -------------------------------------

  /// HU-142: ¿la fecha de recepción pedida es aceptable para persistir?
  ///
  /// La regla "no se piden fechas pasadas" vive acá, en el Service, y no en la
  /// pantalla: así la respeta cualquier otra entrada futura (la agenda
  /// recurrente de HU-013, por ejemplo).
  ///
  /// Con un matiz importante: si la fecha **no cambió** respecto de la que ya
  /// estaba guardada, se acepta aunque hoy esté vencida. Sin esto, un borrador
  /// creado la semana pasada para "ayer" quedaría imposible de guardar y —peor—
  /// el guardado fallaría en silencio, sin que el usuario entienda por qué.
  /// Vencerse no es culpa de la edición que se está haciendo ahora.
  bool _fechaAceptable(DatosFormularioPedido datos, Pedido? previo) {
    final nueva = FechaRecepcion.soloDiaNullable(
      datos.fechaRecepcionSolicitada,
    );
    final anterior = FechaRecepcion.soloDiaNullable(
      previo?.fechaRecepcionSolicitada,
    );
    if (nueva == anterior) return true;
    return FechaRecepcion.validar(nueva) == null;
  }

  /// Guarda el formulario como "borrador". Devuelve el pedido persistido, o null
  /// si falta proveedor, la validación de ítems falla o hubo un error al guardar.
  Future<Pedido?> guardarBorrador(DatosFormularioPedido datos) async {
    if (datos.proveedorId == null) return null;
    if (ValidadorPedido.validarItems(datos.items) != null) return null;

    // HU-141: "guardar como borrador" sólo aplica a borradores; un pedido ya
    // enviado no se degrada (se re-envía con [enviarPedido] o se cancela).
    Pedido? previo;
    if (datos.pedidoEdicionId != null) {
      previo = await _repo.obtener(datos.pedidoEdicionId!);
      if (previo == null || previo.estado != EstadosPedido.borrador) {
        return null;
      }
    }
    if (!_fechaAceptable(datos, previo)) return null;

    final prep = _prepararItems(datos.items);
    final id = datos.pedidoEdicionId ?? const Uuid().v4();

    try {
      if (datos.pedidoEdicionId == null) {
        return await _repo.crear(
          id: id,
          negocioId: datos.negocioId,
          proveedorNombre: datos.proveedorNombre!,
          proveedorId: datos.proveedorId,
          estado: 'borrador',
          nota: datos.nota,
          creadoPor: datos.creadoPor,
          creadoPorNombre: datos.creadoPorNombre,
          itemsJson: prep.jsonItems,
          total: prep.total,
          tieneEfectivo: datos.tieneEfectivo,
          fechaRecepcionSolicitada: datos.fechaRecepcionSolicitada,
        );
      }
      // El estado de un borrador editado no cambia (sigue 'borrador').
      return await _repo.actualizarContenido(
        id: id,
        estado: null,
        itemsJson: prep.jsonItems,
        total: prep.total,
        nota: datos.nota,
        tieneEfectivo: datos.tieneEfectivo,
        fechaRecepcionSolicitada: datos.fechaRecepcionSolicitada,
      );
    } catch (_) {
      return null;
    }
  }

  /// Envía el pedido (estado 'enviado'): queda visible pero ya NO editable
  /// (HU-063). El paso enviado → en_espera lo hace [confirmar] (HU-064).
  /// Devuelve el pedido persistido, o null si la validación falla o hay error.
  Future<Pedido?> enviarPedido(DatosFormularioPedido datos) async {
    if (datos.proveedorId == null) return null;
    if (ValidadorPedido.validarItems(datos.items) != null) return null;

    // HU-141: editable = borrador o enviado (re-envío). Confirmado o recibido,
    // el contenido queda congelado: la matriz no admite volver a 'enviado'.
    Pedido? previo;
    if (datos.pedidoEdicionId != null) {
      previo = await _repo.obtener(datos.pedidoEdicionId!);
      if (previo == null ||
          !TransicionesPedido.puede(previo.estado, EstadosPedido.enviado)) {
        return null;
      }
    }
    if (!_fechaAceptable(datos, previo)) return null;

    final prep = _prepararItems(datos.items);
    if (prep.cantidad == 0) return null;

    final id = datos.pedidoEdicionId ?? const Uuid().v4();

    try {
      if (datos.pedidoEdicionId == null) {
        return await _repo.crear(
          id: id,
          negocioId: datos.negocioId,
          proveedorNombre: datos.proveedorNombre!,
          proveedorId: datos.proveedorId,
          estado: 'enviado',
          nota: datos.nota,
          creadoPor: datos.creadoPor,
          creadoPorNombre: datos.creadoPorNombre,
          itemsJson: prep.jsonItems,
          total: prep.total,
          tieneEfectivo: datos.tieneEfectivo,
          fechaRecepcionSolicitada: datos.fechaRecepcionSolicitada,
          // #273: este pedido NACE enviado, asi que quien lo crea es quien lo
          // envia. Hasta #273 este hecho no se registraba en ningun lado: el
          // paso mas importante del ciclo —el momento en que el pedido sale de
          // la casa— era el unico que no se podia reconstruir.
          envio: (usuarioId: datos.creadoPor, nombre: datos.creadoPorNombre),
        );
      }
      return await _repo.actualizarContenido(
        id: id,
        estado: 'enviado',
        itemsJson: prep.jsonItems,
        total: prep.total,
        nota: datos.nota,
        tieneEfectivo: datos.tieneEfectivo,
        fechaRecepcionSolicitada: datos.fechaRecepcionSolicitada,
        // #273: re-envio de un pedido corregido (HU-141). El repositorio se
        // queda con el PRIMER envio y no lo pisa: sobrescribirlo borraria el
        // momento en que ese pedido salio de la casa para reemplazarlo por el
        // de una correccion. Ver `registraElEnvio`.
        envio: (usuarioId: datos.creadoPor, nombre: datos.creadoPorNombre),
      );
    } catch (_) {
      return null;
    }
  }

  /// Cancela un pedido (HU-141): valida la matriz y la regla "en_espera sólo
  /// sin recepciones", y audita. Lanza [TransicionInvalidaException] si no se puede.
  Future<void> cancelar(Pedido pedido, {String? usuarioId}) =>
      _transiciones.cancelar(pedido, usuarioId: usuarioId);

  /// Mueve la fecha de entrega pedida, o la quita (#269). `null` es un valor
  /// válido, no un faltante.
  ///
  /// Delega en el service de transiciones, que es el único que combina
  /// transacción + relectura de la fila viva + auditoría. Ahí también vive la
  /// validación del choque con otra entrega de la misma serie recurrente.
  Future<void> reprogramar(
    Pedido pedido,
    DateTime? nuevaFecha, {
    String? usuarioId,
  }) => _transiciones.reprogramar(pedido, nuevaFecha, usuarioId: usuarioId);

  /// Marca un pedido como confirmado por el proveedor: 'enviado' → 'en_espera'
  /// (HU-064). Ese es el estado que habilita la recepción.
  Future<void> confirmar(Pedido pedido, {String? usuarioId}) =>
      _transiciones.transicionar(
        pedido,
        EstadosPedido.enEspera,
        usuarioId: usuarioId,
        motivo: 'confirmacion_proveedor',
      );

  /// Elimina físicamente un borrador (HU-141): sólo estado 'borrador'; el resto
  /// se cancela. Lanza [TransicionInvalidaException] si no es un borrador.
  Future<void> eliminar(Pedido pedido, {String? usuarioId}) =>
      _transiciones.eliminarBorrador(pedido, usuarioId: usuarioId);

  /// Cierra un pedido PARCIAL cuyo faltante ya fue re-pedido (HU-064): pasa a
  /// `parcial_cerrado` y sale del listado de Parciales hacia el Historial.
  Future<void> cerrarParcialPorRepedido(Pedido pedido, {String? usuarioId}) =>
      _transiciones.transicionar(
        pedido,
        EstadosPedido.parcialCerrado,
        usuarioId: usuarioId,
        motivo: 'faltante_repedido',
      );

  /// Descarta un PARCIAL que no se va a reclamar (HU-145): transición explícita
  /// y auditada a `parcial_cerrado`; jamás borra recepciones ni evidencia.
  Future<void> descartarParcial(Pedido pedido, {String? usuarioId}) =>
      _transiciones.descartarParcial(pedido, usuarioId: usuarioId);

  /// Repite un pedido (HU-012): crea un NUEVO borrador con los mismos ítems y
  /// cantidades, usando catálogo y precios ACTUALES; omite insumos desactivados.
  /// NO modifica el original. Devuelve el resumen de lo que se pudo repetir.
  Future<RepetirResultado> repetir({
    required Pedido original,
    required String? usuarioId,
    required String usuarioNombre,
  }) async {
    final itemsOriginales = (jsonDecode(original.items) as List)
        .cast<Map<String, dynamic>>();
    final resultado = await _construirRepedido(
      itemsBase: itemsOriginales,
      proveedorId: original.proveedorId,
    );

    await _repo.crear(
      id: const Uuid().v4(),
      negocioId: original.negocioId,
      proveedorNombre: original.proveedorNombre,
      proveedorId: original.proveedorId,
      estado: 'borrador',
      nota: original.nota,
      creadoPor: usuarioId,
      creadoPorNombre: usuarioNombre,
      itemsJson: jsonEncode(resultado.items),
      total: _totalDe(resultado.items),
      tieneEfectivo: original.tieneEfectivo,
    );
    return resultado;
  }

  /// Crea un NUEVO borrador con la mercadería FALTANTE de un pedido PARCIAL
  /// (HU-064): lo que no entró. Devuelve el borrador creado, o null si [faltantes]
  /// está vacío. El pedido parcial original NO se toca acá.
  Future<Pedido?> crearBorradorRepedidoParcial({
    required Pedido pedido,
    required List<Map<String, dynamic>> faltantes,
    required String? usuarioId,
    required String usuarioNombre,
  }) async {
    if (faltantes.isEmpty) return null;

    final resultado = await _construirRepedido(
      itemsBase: faltantes,
      proveedorId: pedido.proveedorId,
    );

    return _repo.crear(
      id: const Uuid().v4(),
      negocioId: pedido.negocioId,
      proveedorNombre: pedido.proveedorNombre,
      proveedorId: pedido.proveedorId,
      estado: EstadosPedido.borrador,
      nota: pedido.nota,
      creadoPor: usuarioId,
      creadoPorNombre: usuarioNombre,
      itemsJson: jsonEncode(resultado.items),
      total: _totalDe(resultado.items),
      tieneEfectivo: pedido.tieneEfectivo,
    );
  }

  // --- Helpers privados ----------------------------------------------------

  /// Filtra los ítems del formulario a los de cantidad > 0, los normaliza a la
  /// forma persistida `{insumoId, nombre, unidad, cantidadPedida, precioUnitario}`
  /// y calcula el total. Unifica el bloque antes duplicado en guardar/enviar.
  _ItemsPreparados _prepararItems(List<Map<String, dynamic>> items) {
    final filtrados = items.where((it) => (it['cantidad'] as double) > 0).map((
      it,
    ) {
      return {
        'insumoId': it['insumoId'],
        'nombre': it['nombre'],
        'unidad': it['unidad'],
        'cantidadPedida': it['cantidad'],
        'precioUnitario': it['costoUnitario'],
      };
    }).toList();

    return (
      jsonItems: jsonEncode(filtrados),
      total: _totalDe(filtrados),
      cantidad: filtrados.length,
    );
  }

  /// Ítems sugeridos a partir de [itemsBase] para [proveedorId]: omite los
  /// insumos dados de baja y aplica los precios de HOY.
  ///
  /// Es el mismo motor que usa "repetir pedido", expuesto para que el generador
  /// de pedidos recurrentes (HU-013) no copie la lista congelada de la agenda:
  /// una agenda de hace tres meses arrastraría precios viejos y podría seguir
  /// pidiendo un insumo discontinuado para siempre. La lista de insumos y sus
  /// cantidades sí son fijas —es lo que el usuario eligió—; el precio no.
  Future<RepetirResultado> itemsSugeridosDe({
    required List<Map<String, dynamic>> itemsBase,
    required String? proveedorId,
  }) => _construirRepedido(itemsBase: itemsBase, proveedorId: proveedorId);

  /// Construye los ítems de un re-pedido a partir de [itemsBase], resolviendo
  /// insumos activos y precios actuales de [proveedorId] (HU-012 / HU-064).
  Future<RepetirResultado> _construirRepedido({
    required List<Map<String, dynamic>> itemsBase,
    required String? proveedorId,
  }) async {
    final ids = itemsBase.map((it) => it['insumoId'] as String).toList();
    final insumos = await _repo.insumosPorIds(ids);
    final activos = insumos.where((i) => i.activo).map((i) => i.id).toSet();

    // Se resuelve con la MISMA regla que al armar un pedido (la cascada de
    // referencia de [resolverPrecio]). Si acá se usara otra, armar un pedido y
    // repetirlo darían precios distintos para el mismo insumo.
    final precios = <String, double>{};
    for (final id in activos) {
      precios[id] = (await resolverPrecio(
        insumoId: id,
        proveedorId: proveedorId,
      )).precio;
    }

    return RepetirPedido.construir(
      itemsOriginales: itemsBase,
      insumosActivos: activos,
      preciosActuales: precios,
    );
  }

  /// Total (cantidadPedida × precioUnitario) de una lista de ítems ya normalizados.
  double _totalDe(List<Map<String, dynamic>> items) {
    double total = 0.0;
    for (final it in items) {
      total +=
          (it['cantidadPedida'] as num).toDouble() *
          (it['precioUnitario'] as num).toDouble();
    }
    return total;
  }
}
