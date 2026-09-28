import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../constants/mensajes_operacion.dart';
import '../database/database.dart';
import '../data/repositorios/repositorio_pedidos.dart';
import '../data/repositorios/repositorio_recepciones.dart';
import '../data/repositorios/repositorio_auditoria.dart';
import '../services/servicio_sesion.dart';
import '../services/servicio_recepciones.dart';
import '../services/servicio_pedidos.dart';
import '../services/servicio_transiciones_pedido.dart';
import '../services/servicio_envio_pedido.dart';
import '../services/servicio_sincronizacion_supabase.dart';
import '../utils/fecha_recepcion.dart';
import '../utils/validador_pedido.dart';
import '../utils/busqueda_proveedores.dart';
import '../utils/repetir_pedido.dart';
import '../utils/desenlace_recepcion.dart';
import 'controlador_adjuntos.dart';
import '../data/repositorios/repositorio_categorias.dart';
import '../data/repositorios/repositorio_proveedor_categorias.dart';
import '../services/servicio_proveedor_categorias.dart';
import '../models/insumo_ofrecido.dart';

/// Controlador de la pantalla de Compras: gestiona el ESTADO DE UI (listados,
/// formulario activo) y delega TODA la lógica de negocio y el acceso a datos en
/// [ServicioPedidos] (Patrón MVC + Service Layer, HU-059). No contiene queries
/// Drift ni reglas de negocio: sólo arma la entrada, invoca al servicio y
/// refresca el estado para la Vista.
class ControladorRecibir extends ChangeNotifier {
  final ServicioSesion sesion;
  final ServicioRecepciones _recepciones;
  final ServicioPedidos _servicio;
  final ServicioEnvioPedido _envio;

  /// El controlador puede recibir un [servicio]/[envio] ya construidos (inyección
  /// desde `main.dart` con el repositorio de la Fábrica); si no, arma los suyos a
  /// partir de la BD y la sincronización (comodidad para tests con Drift en memoria).
  ControladorRecibir(
    this.sesion,
    BaseDatosApp db,
    this._recepciones, [
    ServicioSincronizacionSupabase? sync,
    ServicioPedidos? servicio,
    ServicioEnvioPedido? envio,
  ]) : _servicio =
           servicio ??
           ServicioPedidos(
             RepositorioPedidosDrift(db, sync),
             // HU-141: autoridad de transiciones con los mismos db/sync.
             ServicioTransicionesPedido(
               db,
               RepositorioPedidosDrift(db, sync),
               RepositorioRecepcionesDrift(db, sync),
               RepositorioAuditoriaDrift(db, sync),
               sync,
             ),
             // #262: la relación proveedor↔categoría se arma acá, así los tests
             // que construyen el controlador con una BD en memoria obtienen el
             // selector por categoría sin cambiar su firma.
             ServicioProveedorCategorias(
               RepositorioProveedorCategoriasDrift(db, sync),
               RepositorioCategoriasDrift(db, sync),
             ),
           ),
       _envio = envio ?? ServicioEnvioPedido();

  /// Servicio que arma el mensaje editable y la URL de WhatsApp del Resumen (HU-063).
  ServicioEnvioPedido get envio => _envio;

  List<Pedido> _pedidos = [];
  StreamSubscription<List<Pedido>>? _subPedidos; // HU-089: pedidos reactivos
  List<Proveedore> _proveedores = [];
  StreamSubscription<List<Proveedore>>?
  _subProveedores; // HU-096: selector reactivo
  bool _cargando = true;

  /// Motivo por el que la última carga no trajo datos, o `null` si salió bien.
  /// Existe para que las pantallas puedan ofrecer "Reintentar" en vez de dejar
  /// un spinner girando sin explicación.
  String? _errorCarga;
  String _negocioId = '';
  String _usuarioNombre = 'Operador';
  String _usuarioRol = 'cocinero';

  // Campos para el formulario activo de creación/edición de pedido
  String? _pedidoEdicionId;
  String? _proveedorSeleccionadoId;
  String? _proveedorSeleccionadoNombre;
  final List<Map<String, dynamic>> _itemsPedido =
      []; // {insumoId, nombre, unidad, cantidad, costoUnitario}
  String _notaPedido = '';
  bool _tieneEfectivo = false;

  /// HU-142: día pedido de recepción. `null` = sin fecha (el campo es opcional).
  DateTime? _fechaRecepcionSolicitada;

  /// #176: hay un guardado del pedido EN VUELO.
  ///
  /// Son DOS flags y no uno compartido a propósito: "guardar el pedido" y
  /// "cargar la selección de insumos" son operaciones distintas, y un flag
  /// único apagaría los botones del pedido mientras trabaja el selector, sin
  /// ninguna razón.
  bool _guardandoPedido = false;

  /// #176: hay una carga de insumos al pedido EN VUELO (selector de insumos).
  ///
  /// NO tiene getter público ni notifica: el selector es un diálogo que a
  /// propósito no escucha a este controlador (suscribirlo lo haría redibujarse
  /// en medio del bucle de carga), así que apaga su botón con un flag local
  /// suyo. Este de acá es la segunda puerta, la que impide la carga duplicada.
  bool _cargandoSeleccion = false;

  // Getters para la Vista
  List<Pedido> get pedidos => _pedidos;
  List<Proveedore> get proveedores => _proveedores;
  bool get cargando => _cargando;
  String? get errorCarga => _errorCarga;

  /// Buscador de proveedores para armar un pedido (HU-058): filtra la lista ya cargada
  /// (sólo activos, en memoria — sin round-trips a la BBDD) por nombre y categoría.
  List<Proveedore> buscarProveedores({
    String query = '',
    String categoria = 'Todos',
  }) => buscarProveedoresActivos(
    _proveedores,
    query: query,
    categoria: categoria,
  );

  /// Categorías disponibles para el filtro del buscador (con 'Todos' al frente).
  List<String> get categoriasProveedores =>
      categoriasDeProveedores(_proveedores);
  String get negocioId => _negocioId;
  String get usuarioNombre => _usuarioNombre;
  String get usuarioRol => _usuarioRol;

  String? get pedidoEdicionId => _pedidoEdicionId;
  String? get proveedorSeleccionadoId => _proveedorSeleccionadoId;
  String? get proveedorSeleccionadoNombre => _proveedorSeleccionadoNombre;
  List<Map<String, dynamic>> get itemsPedido => _itemsPedido;
  String get notaPedido => _notaPedido;
  bool get tieneEfectivo => _tieneEfectivo;
  DateTime? get fechaRecepcionSolicitada => _fechaRecepcionSolicitada;

  /// #176: hay un guardado del pedido en curso. La pantalla lo consulta para
  /// apagar los botones y para explicar el segundo toque en vez de tratarlo
  /// como un error.
  bool get guardandoPedido => _guardandoPedido;

  void actualizarTieneEfectivo(bool valor) {
    _tieneEfectivo = valor;
    notifyListeners();
  }

  /// HU-142: fija (o borra, con `null`) el día pedido de recepción. Notifica
  /// porque la pantalla muestra la fecha elegida en el propio botón.
  void actualizarFechaRecepcionSolicitada(DateTime? fecha) {
    _fechaRecepcionSolicitada = FechaRecepcion.soloDiaNullable(fecha);
    notifyListeners();
  }

  /// Carga la sesión del usuario activo, los proveedores y el listado de pedidos locales.
  Future<void> cargarSesionYPedidos() async {
    final negocioId = sesion.negocioId;
    final usuarioActivoId = sesion.usuarioId;

    // Sin negocio no hay nada que cargar, pero HAY que apagar el spinner: como
    // `_cargando` arranca en true, salir de largo lo dejaba girando para
    // siempre. Lo destapó la ficha del proveedor (HU-009), que muestra el
    // historial fuera de la pantalla de Recibir.
    if (negocioId.isEmpty) {
      _cargando = false;
      _errorCarga = 'No hay un negocio activo en esta sesión.';
      notifyListeners();
      return;
    }

    final DatosSesionPedidos datos;
    try {
      datos = await _servicio.cargarSesion(negocioId, usuarioActivoId);
      _errorCarga = null;
    } catch (e) {
      // Antes esto se propagaba y dejaba la pantalla colgada en el spinner, sin
      // mensaje ni forma de reintentar.
      debugPrint('[RECIBIR] No se pudieron cargar los pedidos: $e');
      _cargando = false;
      _errorCarga = 'No se pudieron cargar los pedidos.';
      notifyListeners();
      return;
    }

    _negocioId = negocioId;
    _usuarioNombre = datos.usuario?.nombre ?? 'Operador';
    _usuarioRol = datos.usuario?.rol ?? 'cocinero';
    _proveedores = datos.proveedores;
    _pedidos = datos.pedidos; // foto inicial; el stream la mantiene al día
    _cargando = false;
    notifyListeners();

    // HU-089: los pedidos pasan a un STREAM reactivo. La UI se actualiza SOLA cuando el
    // pull deposita filas (aunque llegue después del primer frame) o tras una mutación,
    // sin recarga manual. Se re-suscribe con el negocio actual (cancela la anterior).
    // Se reasigna la subscription ANTES de await-ear la cancelación de la anterior, para
    // que dos `cargar*` interleavados no dejen una subscription huérfana.
    final subAnterior = _subPedidos;
    _subPedidos = _servicio.observarPedidos(negocioId).listen((pedidos) {
      _pedidos = pedidos;
      _cargando = false;
      notifyListeners();
    });
    await subAnterior?.cancel();

    // HU-096: el selector de proveedores del formulario pasa a un STREAM reactivo (mismo
    // root cause y patrón que los pedidos en HU-089). En un arranque en frío, si el pull
    // deposita los proveedores DESPUÉS del get() inicial, el picker de 'Nuevo Pedido' ya
    // no queda vacío: se puebla solo, sin depender de una recarga manual.
    final subProvAnterior = _subProveedores;
    _subProveedores = _servicio.observarProveedores(negocioId).listen((
      proveedores,
    ) {
      _proveedores = proveedores;
      notifyListeners();
    });
    await subProvAnterior?.cancel();
  }

  @override
  void dispose() {
    _subPedidos?.cancel();
    _subProveedores?.cancel();
    super.dispose();
  }

  /// Arma el DTO con el estado actual del formulario para pasarlo al servicio.
  /// La FOTO del formulario en el instante del toque (#176, decisión D).
  ///
  /// Los ítems se COPIAN —lista nueva y mapa nuevo por ítem— y no se pasa
  /// `_itemsPedido` tal cual. No es prolijidad: `ServicioPedidos.guardarBorrador`
  /// / `enviarPedido` leen `datos.items` DESPUÉS de su primer `await` cuando el
  /// pedido ya existía (la lectura del pedido previo de HU-141), así que
  /// entregar la lista viva deja una ventana en la que cualquier cambio le
  /// cambia la foto al guardado en vuelo. El caso feo: cerrar la hoja mientras
  /// guarda y reabrirla dispara `limpiarFormulario()` —que hace
  /// `_itemsPedido.clear()`— y el borrador se persiste VACÍO, sin un solo
  /// aviso. El bloqueo de la pantalla no alcanza: la hoja se cierra igual
  /// tocando afuera.
  DatosFormularioPedido _formulario() => DatosFormularioPedido(
    negocioId: _negocioId,
    proveedorId: _proveedorSeleccionadoId,
    proveedorNombre: _proveedorSeleccionadoNombre,
    items: _itemsPedido.map((it) => Map<String, dynamic>.from(it)).toList(),
    nota: _notaPedido,
    tieneEfectivo: _tieneEfectivo,
    creadoPor: sesion.usuarioId,
    creadoPorNombre: _usuarioNombre,
    pedidoEdicionId: _pedidoEdicionId,
    fechaRecepcionSolicitada: _fechaRecepcionSolicitada,
  );

  /// Cambia el proveedor del formulario (HU-073). NO autocarga insumos: sólo se agregan
  /// los que el usuario elige. Como cada insumo pertenece a un único proveedor, al
  /// cambiar de proveedor se quitan del pedido los ítems que no le corresponden (item d).
  ///
  /// Los ítems SIN dueño son la excepción, y es la regla que el PO fijó:
  /// **pedirle un insumo a un proveedor es declarar que ese proveedor te lo
  /// vende**, así que lo ADOPTAN en vez de irse. Antes se los llevaba el
  /// `removeWhere` —que compara contra `null` y por lo tanto los barría todos—
  /// sin ningún aviso: cargábas tres insumos de "Otros insumos", elegías
  /// proveedor y desaparecían. Es un defecto viejo y no reportado; #178 y #179
  /// sólo le agregan escenas.
  ///
  /// La adopción acá es sólo EN MEMORIA y el método sigue siendo síncrono a
  /// propósito: escribir el vínculo en el catálogo al tocar un nombre en el
  /// buscador dejaría rastro permanente de un proveedor que se miró y se
  /// descartó. El vínculo se graba cuando el pedido se guarda —ver
  /// [ServicioPedidos.asegurarVinculosDeItems]—, que es cuando la persona
  /// confirmó a quién le pide.
  void cambiarProveedorSeleccionado(String? provId) {
    _proveedorSeleccionadoId = provId;
    _proveedorSeleccionadoNombre = provId == null
        ? null
        : _nombreProveedor(provId);
    if (provId != null) {
      for (final item in _itemsPedido) {
        item['proveedorId'] ??= provId;
      }
    }
    _itemsPedido.removeWhere((it) => it['proveedorId'] != provId);
    notifyListeners();
  }

  /// Nombre de un proveedor de la lista activa cargada, o null si no está.
  String? _nombreProveedor(String provId) {
    for (final p in _proveedores) {
      if (p.id == provId) return p.nombre;
    }
    return null;
  }

  /// Actualiza la cantidad de un ítem del pedido en armado.
  ///
  /// Ya no recibe `costoUnitario` (#213): el precio dejó de ser editable a mano
  /// y lo resuelve la cascada de HU-138. Se sacó el parámetro en vez de dejarlo
  /// sin usar porque es un named OPCIONAL: volver a agregarlo el día que haga
  /// falta no obliga a tocar ningún llamador. (Distinto de `validarRecepcion`,
  /// donde el parámetro sin uso se conservó a propósito: ahí es requerido y
  /// sacarlo obligaba a re-enhebrarlo por dos call sites.)
  void actualizarItemPedido(int indice, {double? cantidad}) {
    if (indice >= 0 && indice < _itemsPedido.length) {
      if (cantidad != null) {
        _itemsPedido[indice]['cantidad'] = cantidad;
      }
      notifyListeners();
    }
  }

  void agregarItemPedido(
    String insumoId,
    String nombre,
    String unidad,
    double cantidad,
    double costoUnitario, {
    String? proveedorId,
  }) {
    _itemsPedido.add({
      'insumoId': insumoId,
      'nombre': nombre,
      'unidad': unidad,
      'cantidad': cantidad,
      'costoUnitario': costoUnitario,
      // Proveedor dueño del insumo: sirve para la coherencia al cambiar de proveedor (HU-073).
      'proveedorId': proveedorId,
    });
    notifyListeners();
  }

  /// Agrega VARIOS insumos de una vez, cada uno con su cantidad (HU-140).
  ///
  /// Los de cantidad 0 se descartan (regla del Service). Devuelve el resultado
  /// del primer problema encontrado, o el ok con cuántos entraron.
  Future<ResultadoAgregarInsumo> agregarSeleccion(
    List<({InsumoOfrecido ofrecido, double cantidad})> seleccion,
  ) async {
    // #176: una de las DOS puertas de entrada del selector. La guarda va acá y
    // NO en `agregarInsumoOfrecido`: ese es el paso interno que el bucle de más
    // abajo llama una vez por insumo, así que un flag ahí se frenaría a sí
    // mismo desde la segunda vuelta y una selección múltiple cargaría UN SOLO
    // insumo. Devuelve error —y no ok— para que el diálogo no se cierre dos
    // veces: el `Navigator.pop` cuelga del ok.
    if (_cargandoSeleccion) {
      return const ResultadoAgregarInsumo.error(
        MensajesOperacion.agregadoEnCurso,
      );
    }
    _cargandoSeleccion = true;
    try {
      return await _agregarSeleccion(seleccion);
    } finally {
      // Sin `finally`, una excepción dejaría el selector inservible para el
      // resto de la sesión (el controlador no se recrea).
      _cargandoSeleccion = false;
    }
  }

  Future<ResultadoAgregarInsumo> _agregarSeleccion(
    List<({InsumoOfrecido ofrecido, double cantidad})> seleccion,
  ) async {
    final aCargar = _servicio.itemsDeSeleccion(seleccion);
    if (aCargar.isEmpty) {
      return const ResultadoAgregarInsumo.error(
        'Poné una cantidad mayor a 0 en al menos un insumo.',
      );
    }

    // #262: el pedido siempre se arma PARA un proveedor ya elegido (el selector
    // muestra sus categorías). Ya no hay deducción de proveedor desde los
    // insumos (camino 2 de HU-073, retirado).
    for (final item in aCargar) {
      final r = await agregarInsumoOfrecido(item.ofrecido);
      if (!r.ok) return r;
      // La cantidad real reemplaza al 1.0 con el que entra por defecto.
      final idx = _itemsPedido.indexWhere(
        (it) => it['insumoId'] == item.ofrecido.insumo.id,
      );
      if (idx >= 0) actualizarItemPedido(idx, cantidad: item.cantidad);
    }
    return const ResultadoAgregarInsumo.ok();
  }

  /// Agrega al pedido un insumo RECIÉN CREADO desde el selector (HU-139).
  ///
  /// Nace vinculado al proveedor del pedido (lo hizo el alta), así que se
  /// resuelve su precio y se reutiliza el mismo camino que la oferta normal.
  Future<ResultadoAgregarInsumo> agregarInsumoNuevo(Insumo creado) async {
    // #176: la OTRA puerta del selector ("Insumo nuevo"). Comparte el flag con
    // [agregarSeleccion] porque son la misma sesión de trabajo del diálogo:
    // mientras una carga está en vuelo, la otra tampoco debe arrancar.
    if (_cargandoSeleccion) {
      return const ResultadoAgregarInsumo.error(
        MensajesOperacion.agregadoEnCurso,
      );
    }
    _cargandoSeleccion = true;
    try {
      return await _agregarInsumoNuevo(creado);
    } finally {
      _cargandoSeleccion = false;
    }
  }

  Future<ResultadoAgregarInsumo> _agregarInsumoNuevo(Insumo creado) async {
    final r = await _servicio.resolverPrecio(
      insumoId: creado.id,
      proveedorId: _proveedorSeleccionadoId,
    );
    return agregarInsumoOfrecido(
      InsumoOfrecido(insumo: creado, precio: r.precio, origen: r.origen),
    );
  }

  /// Agrega al pedido un insumo de la oferta (HU-138).
  ///
  /// Devuelve un [ResultadoAgregarInsumo]: si no se pudo, trae el motivo para
  /// mostrarlo; si auto-seleccionó el proveedor, lo avisa.
  ///
  /// Reglas:
  ///  • Si el insumo NO tiene proveedores y hay uno elegido, se vincula solo:
  ///    es la contrapartida de ofrecerlo en "Otros insumos".
  ///  • Sin proveedor elegido y con UN solo candidato, se auto-selecciona
  ///    (camino 2 de HU-073). Con varios no se adivina: se pide elegir.
  Future<ResultadoAgregarInsumo> agregarInsumoOfrecido(
    InsumoOfrecido ofrecido,
  ) async {
    final ins = ofrecido.insumo;
    // #262: el pedido ya tiene proveedor (el selector muestra sus categorías).
    // El insumo pertenece a una categoría, no a un proveedor: no se crea ningún
    // vínculo insumo↔proveedor ni se deduce nada. El precio ya vino resuelto
    // para este proveedor en [ServicioPedidos.insumosOfrecidos].
    agregarItemPedido(
      ins.id,
      ins.nombre,
      ins.unidad,
      1.0,
      ofrecido.precio,
      proveedorId: _proveedorSeleccionadoId,
    );
    return const ResultadoAgregarInsumo.ok();
  }

  /// Valida los ítems del formulario contra los criterios de HU-010 delegando en
  /// la regla pura [ValidadorPedido.validarItems] (testeable de forma aislada).
  /// Devuelve null si es válido, o un mensaje claro para mostrar al usuario.
  String? validarItemsPedido() => ValidadorPedido.validarItems(_itemsPedido);

  void removerItemPedido(int indice) {
    if (indice >= 0 && indice < _itemsPedido.length) {
      _itemsPedido.removeAt(indice);
      notifyListeners();
    }
  }

  void limpiarFormulario() {
    _pedidoEdicionId = null;
    _proveedorSeleccionadoId = null;
    _proveedorSeleccionadoNombre = null;
    _itemsPedido.clear();
    _notaPedido = '';
    _tieneEfectivo = false;
    _fechaRecepcionSolicitada = null; // HU-142
    notifyListeners();
  }

  void actualizarNota(String valor) {
    _notaPedido = valor;
  }

  /// Carga los datos de un borrador existente en el formulario para editarlo.
  void cargarBorradorEnFormulario(Pedido borrador) {
    _pedidoEdicionId = borrador.id;
    _proveedorSeleccionadoId = borrador.proveedorId;
    _proveedorSeleccionadoNombre = borrador.proveedorNombre;
    _notaPedido = borrador.nota ?? '';
    _tieneEfectivo = borrador.tieneEfectivo;
    // HU-142: se conserva tal cual, incluso si ya quedó en el pasado. El Service
    // acepta una fecha vencida mientras no se la toque, así que el borrador se
    // puede seguir editando sin que el usuario pierda el dato ni quede trabado.
    _fechaRecepcionSolicitada = borrador.fechaRecepcionSolicitada;
    _itemsPedido.clear();

    final itemsList = jsonDecode(borrador.items) as List<dynamic>;
    for (final it in itemsList) {
      _itemsPedido.add({
        'insumoId': it['insumoId'],
        'nombre': it['nombre'],
        'unidad': it['unidad'],
        'cantidad': (it['cantidadPedida'] as num).toDouble(),
        'costoUnitario': (it['precioUnitario'] as num).toDouble(),
        // Todos los ítems de un borrador pertenecen a su proveedor (HU-073, item d).
        'proveedorId': borrador.proveedorId,
      });
    }
    notifyListeners();
  }

  /// Guarda el estado del formulario actual como "Borrador". Devuelve true si se guardó.
  ///
  /// #176: con un guardado en vuelo devuelve `false` SIN guardar. Ojo con leer
  /// ese `false` como "falló": la pantalla consulta [guardandoPedido] ANTES de
  /// llamar y muestra el aviso correcto, así que este camino es la última
  /// línea de defensa —el toque del mismo frame que llegó antes del
  /// redibujado—, no el mensaje de error.
  Future<bool> guardarBorrador() async {
    if (_guardandoPedido) return false;

    // La puerta se cierra ANTES de cualquier `await`: el cuerpo de un async
    // corre síncrono hasta el primero, así que el segundo toque del mismo frame
    // ya encuentra el flag prendido. Marcarlo después del await dejaría el
    // hueco abierto y el arreglo PARECERÍA hecho.
    _guardandoPedido = true;
    notifyListeners();
    try {
      final pedido = await _servicio.guardarBorrador(_formulario());
      if (pedido == null) return false;
      return true;
    } finally {
      // `finally` obligatorio: este controlador es ÚNICO para toda la sesión.
      // Si una excepción dejara el flag prendido, TODOS los guardados
      // siguientes serían un no-op silencioso, con el botón gris para siempre.
      _guardandoPedido = false;
      notifyListeners();
    }
  }

  /// Envía el pedido como activo (HU-063): queda visible pero ya NO editable.
  /// Devuelve el [Pedido] persistido para abrir el Resumen y ofrecer el envío por
  /// WhatsApp, o `null` si la validación falla o hay un error al guardar.
  /// #176: con un envío en vuelo devuelve `null` SIN enviar. Devolver el
  /// pedido del primer toque tampoco serviría: la pantalla abriría el Resumen
  /// dos veces y ofrecería mandar la misma orden por WhatsApp de nuevo.
  Future<Pedido?> enviarPedido() async {
    if (_guardandoPedido) return null;

    // Igual que en [guardarBorrador]: el flag se prende antes del primer
    // `await`. Acá el duplicado es irreversible desde la app —dos pedidos, dos
    // encolados al Outbox y DOS ÓRDENES AL PROVEEDOR—, así que la puerta se
    // cierra en los dos lados: el botón apagado en la pantalla y esta guarda.
    _guardandoPedido = true;
    notifyListeners();
    try {
      final pedido = await _servicio.enviarPedido(_formulario());
      if (pedido == null) return null;
      return pedido;
    } finally {
      _guardandoPedido = false;
      notifyListeners();
    }
  }

  /// Usuario para la auditoría de transiciones: la FK remota de
  /// registros_auditoria exige un uuid válido o null — nunca '' (default de
  /// sesión sin login). Misma convención que controlador_pagos.
  String? get _usuarioAuditoria =>
      sesion.usuarioId.isEmpty ? null : sesion.usuarioId;

  /// Elimina físicamente un borrador (HU-141). Devuelve `null` si se eliminó,
  /// o un mensaje de error listo para mostrar si la transición es inválida.
  Future<String?> eliminarPedido(Pedido pedido) => _conMensajeDeTransicion(
    () => _servicio.eliminar(pedido, usuarioId: _usuarioAuditoria),
  );

  /// Cancela un pedido (HU-141). Devuelve `null` si se canceló, o un mensaje de
  /// error listo para mostrar (p. ej. en_espera con recepciones registradas).
  Future<String?> cancelarPedido(Pedido pedido) => _conMensajeDeTransicion(
    () => _servicio.cancelar(pedido, usuarioId: _usuarioAuditoria),
  );

  /// Mueve la fecha de entrega, o la quita (#269). `null` en [nuevaFecha] es
  /// un valor válido: dejar la entrega sin fecha.
  ///
  /// Devuelve `null` si salió bien, o el mensaje listo para mostrar. El Service
  /// rechaza con un motivo legible cuando el estado ya no lo permite, cuando la
  /// fecha cae fuera de la ventana, y cuando choca con otra entrega de la misma
  /// serie recurrente.
  Future<String?> reprogramarPedido(Pedido pedido, DateTime? nuevaFecha) =>
      _conMensajeDeTransicion(
        () => _servicio.reprogramar(
          pedido,
          nuevaFecha,
          usuarioId: _usuarioAuditoria,
        ),
      );

  /// Marca un pedido como "confirmado por el proveedor" (HU-064): pasa de 'enviado'
  /// a 'en_espera'. Ese es el estado que habilita la recepción (gate manual: el
  /// WhatsApp es saliente, la confirmación del proveedor llega por fuera de la app).
  Future<String?> confirmarPedido(Pedido pedido) => _conMensajeDeTransicion(
    () => _servicio.confirmar(pedido, usuarioId: _usuarioAuditoria),
  );

  /// Ejecuta un cambio de estado y traduce [TransicionInvalidaException] a un
  /// mensaje para la vista (null = éxito). Cualquier otro error es genérico.
  Future<String?> _conMensajeDeTransicion(
    Future<void> Function() accion,
  ) async {
    try {
      await accion();
      return null;
    } on TransicionInvalidaException catch (e) {
      return e.mensaje;
    } catch (_) {
      return 'No se pudo actualizar el pedido. Intentá de nuevo.';
    }
  }

  /// Registra la recepción física como un EVENTO append-only (RN-013 / HU-064):
  /// valida los desenlaces por ítem, delega la persistencia en [ServicioRecepciones]
  /// (no toca la BD acá) y refresca el listado.
  ///
  /// Devuelve `null` si todo salió bien, o un mensaje de error listo para mostrar.
  /// [adjuntos]: controlador con los remitos staged; se exige al menos uno cuando se
  /// recibió mercadería (HU-066). Si todo se rechazó, el remito es opcional.
  Future<String?> registrarRecepcionFisica({
    required Pedido pedido,
    required List<Map<String, dynamic>> itemsVerificados,
    required List<Map<String, dynamic>> alertas,
    required bool pagarEfectivo,
    ControladorAdjuntos? adjuntos,
    double? totalManual,
    bool cerrarSinParcial = false,
    String? nota,
  }) async {
    final errorValidacion = validarRecepcion(itemsVerificados, adjuntos);
    if (errorValidacion != null) return errorValidacion;

    // #227: validar y comprimir ANTES de tocar la base. Lo que puede fallar por
    // el archivo (tipo, tamaño, un comprimido que igual pasa el tope) falla acá,
    // con mensaje, cero filas escritas y los archivos intactos para reintentar.
    // Antes fallaba DESPUÉS de registrar la recepción, y el bucle de
    // `persistirEn` lo descartaba en silencio: quedaba una recepción sin el
    // comprobante que #226 exige, sin que nadie se enterara nunca.
    if (adjuntos != null && adjuntos.tieneAdjuntos) {
      final errorAdjunto = await adjuntos.prepararTodo();
      if (errorAdjunto != null) return errorAdjunto;
    }

    try {
      await _recepciones.registrar(
        pedido: pedido,
        itemsVerificados: itemsVerificados,
        alertas: alertas,
        usuarioId: sesion.usuarioId,
        usuarioNombre: _usuarioNombre,
        pagarEfectivo: pagarEfectivo,
        totalManual: totalManual,
        cerrarSinParcial: cerrarSinParcial,
        // HU-146: comentario libre de la recepción — el parámetro existía de
        // punta a punta (repo/service/sync) pero nunca se enviaba desde acá.
        nota: nota,
        // #227: el comprobante se escribe DENTRO de la transacción del evento.
        // Si falla, no queda recepción a medias: se revierte todo y el archivo
        // sobrevive staged. (#229: acá vivía además la persistencia del OCR,
        // que se fue con el escaneo a la pantalla de Procesar.)
        adjuntarEnTransaccion: (adjuntos != null && adjuntos.tieneAdjuntos)
            ? (recepcionId) => adjuntos.persistirEn(
                negocioId: pedido.negocioId,
                recepcionId: recepcionId,
              )
            : null,
      );
      return null;
    } on TransicionInvalidaException catch (e) {
      // HU-141: el motivo real (reintentar no lo arregla; el snapshot está viejo).
      return e.mensaje;
    } catch (e) {
      // #227: este mensaje MENTÍA cuando el que fallaba era el adjunto — la
      // recepción ya estaba registrada y el "intentá de nuevo" generaba una
      // segunda. Ahora el adjunto va dentro de la transacción, así que un fallo
      // acá revierte de verdad y reintentar arranca limpio.
      return 'No se pudo registrar la recepción. Intentá de nuevo.';
    }
  }

  /// Validaciones previas de la recepción: ítems (HU-064) y comprobante
  /// adjunto. Reutilizables por la vista ANTES del diálogo de decisión de
  /// HU-145, así el usuario no decide sobre una recepción que después no valida.
  /// Devuelve un mensaje listo para mostrar, o null si es válida.
  ///
  /// ⚠ El comprobante es OBLIGATORIO cuando entró mercadería, y esta regla ya
  /// cambió dos veces: #212 la sacó —la mercadería a veces llega sin papel— y
  /// #226 la repuso por decisión del cliente. La recepción pasó a manejar SÓLO
  /// cantidades y el costeo se mudó a Pagos, así que el papel es lo único que
  /// respalda ese monto cuando administración lo procesa. Sin él, el
  /// administrador carga costos contra nada.
  ///
  /// Dice "comprobante" y no "remito": vale cualquiera de los dos papeles que
  /// puede traer el repartidor. NO se nombra la factura a propósito —aunque la
  /// regla la acepte— porque los adjuntos de la recepción los ve el cocinero, y
  /// una factura lleva precios (HU-060). Invitarla desde el texto sería abrir
  /// esa puerta.
  ///
  /// Una recepción con TODO rechazado no exige comprobante: no entró
  /// mercadería, así que no hay entrega que respaldar.
  ///
  /// ⚠ La regla mira los adjuntos PENDIENTES, en memoria, y el evento se
  /// registra antes de persistirlos. Un archivo que falle al guardarse se
  /// descarta en silencio y la recepción queda sin respaldo igual: es #227, y
  /// esta validación no lo cubre.
  String? validarRecepcion(
    List<Map<String, dynamic>> items,
    ControladorAdjuntos? adjuntos,
  ) {
    final errorItems = validarItemsRecepcion(items);
    if (errorItems != null) return errorItems;
    if (hayItemRecibido(items) &&
        (adjuntos == null || !adjuntos.tieneAdjuntos)) {
      return 'Adjuntá el comprobante de la entrega: es obligatorio cuando se '
          'recibió mercadería.';
    }
    return null;
  }

  /// Recepciones registradas de un pedido (HU-146): el detalle las muestra con
  /// desenlace y nota. Delegación pura al service (la vista no toca el repo).
  Future<List<Recepcion>> recepcionesDePedido(Pedido pedido) =>
      _recepciones.recepcionesDePedido(pedido.id);

  /// ¿La recepción con estos ítems dejaría el pedido PARCIAL? (HU-145: la vista
  /// lo pregunta antes de confirmar para ofrecer el cierre sin parcial.)
  Future<bool> recepcionQuedariaParcial(
    Pedido pedido,
    List<Map<String, dynamic>> items,
  ) => _recepciones.quedariaParcial(pedido: pedido, items: items);

  /// Descarta un parcial que no se va a reclamar (HU-145). Devuelve `null` si
  /// cerró, o un mensaje de error listo para mostrar.
  Future<String?> descartarParcial(Pedido pedido) => _conMensajeDeTransicion(
    () => _servicio.descartarParcial(pedido, usuarioId: _usuarioAuditoria),
  );

  /// Crea un NUEVO borrador con la mercadería FALTANTE de un pedido PARCIAL (HU-064).
  /// Obtiene los faltantes desde [ServicioRecepciones] y delega la creación en
  /// [ServicioPedidos]. Devuelve el borrador creado para que la vista lo abra en el
  /// formulario, o `null` si el pedido no tiene faltantes.
  Future<Pedido?> crearBorradorRepedidoParcial(Pedido pedido) async {
    final faltantes = await _recepciones.faltantesDePedido(pedido);
    final borrador = await _servicio.crearBorradorRepedidoParcial(
      pedido: pedido,
      faltantes: faltantes,
      usuarioId: sesion.usuarioId,
      usuarioNombre: _usuarioNombre,
    );
    if (borrador == null) return null;
    return borrador;
  }

  /// Cierra un pedido PARCIAL cuyo faltante ya fue re-pedido (HU-064): pasa a
  /// `parcial_cerrado` y sale del listado de Parciales hacia el Historial (resuelto).
  /// Devuelve `null` si cerró, o un mensaje de error listo para mostrar.
  Future<String?> cerrarParcialPorRepedido(Pedido pedido) =>
      _conMensajeDeTransicion(
        () => _servicio.cerrarParcialPorRepedido(
          pedido,
          usuarioId: _usuarioAuditoria,
        ),
      );

  /// Oferta de insumos para el selector del pedido, agrupada por categoría
  /// (#262): un grupo por cada categoría que suministra el proveedor elegido.
  ///
  /// Vacío si todavía no hay proveedor elegido: en el modelo estricto el pedido
  /// se arma PARA un proveedor, así que la vista pide primero elegir uno.
  Future<List<GrupoCategoriaOfrecida>> obtenerOfertaInsumos() {
    final proveedorId = _proveedorSeleccionadoId;
    if (proveedorId == null) {
      return Future.value(const <GrupoCategoriaOfrecida>[]);
    }
    return _servicio.insumosOfrecidos(
      negocioId: _negocioId,
      proveedorId: proveedorId,
    );
  }

  /// Teléfono y email del proveedor de un pedido, para los canales de envío
  /// (WhatsApp — HU-011 — y correo — #235).
  Future<({String? telefono, String? email})> contactoDeProveedor(
    String? proveedorId,
  ) async {
    if (proveedorId == null) return (telefono: null, email: null);
    return _servicio.contactoProveedor(proveedorId);
  }

  /// Repite un pedido (HU-012): crea un NUEVO borrador con los mismos ítems y
  /// cantidades, usando el catálogo y los precios ACTUALES; omite insumos
  /// desactivados. NO modifica el pedido original. Devuelve el resumen.
  Future<RepetirResultado> repetirPedido(Pedido original) async {
    final resultado = await _servicio.repetir(
      original: original,
      usuarioId: sesion.usuarioId,
      usuarioNombre: _usuarioNombre,
    );
    return resultado;
  }
}

/// Desenlace de agregar un insumo al pedido (HU-138).
class ResultadoAgregarInsumo {
  const ResultadoAgregarInsumo.ok({this.autoSelecciono = false}) : error = null;
  const ResultadoAgregarInsumo.error(this.error) : autoSelecciono = false;

  /// `null` si se agregó; si no, el motivo listo para mostrar.
  final String? error;

  /// El proveedor del pedido se dedujo del insumo elegido (camino 2 de HU-073).
  final bool autoSelecciono;

  bool get ok => error == null;
}
