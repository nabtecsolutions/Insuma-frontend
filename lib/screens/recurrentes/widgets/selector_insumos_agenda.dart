import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../constants/unidades.dart';
import '../../../models/insumo_ofrecido.dart';
import '../../../services/servicio_pedidos.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/validador_datos.dart';
import '../../insumos/widgets/formulario_insumo_modal.dart';
import '../../widgets/campo_numerico.dart';

/// Slide 2 del wizard de pedidos recurrentes (HU-013): qué insumos entran en la
/// agenda y con qué cantidad.
///
/// **Es un gemelo deliberado de `SelectorInsumosPedido`, no una reutilización.**
/// El PO pidió "la misma lógica de los pedidos" y de ahí sale todo el lenguaje
/// visual de este archivo —buscador, secciones, checkbox + cantidad, contador,
/// botón "Insumo nuevo"—, pero aquel widget NO se puede invocar desde acá por
/// dos motivos que rompen cosas de verdad:
///
///  1. **Está atado al borrador VIVO del usuario.** Lee y ESCRIBE el
///     `ControladorRecibir` del árbol global (`proveedorSeleccionadoId`,
///     `itemsPedido`, `agregarSeleccion`). Abrirlo desde el wizard le metería
///     ítems —y hasta le cambiaría el proveedor— al pedido que la persona tenga
///     a medio armar en "Nuevo Pedido". No es un detalle estético: es corromper
///     datos de otro flujo. Este widget no toca `ControladorRecibir` ni una vez.
///  2. **Escribe en la base al marcar.** Allá, marcar un insumo de "Otros
///     insumos" crea el vínculo insumo↔proveedor en el acto. Acá el usuario
///     puede abandonar el wizard en este mismo slide, así que eso dejaría
///     vínculos de una agenda que nunca existió. **Este widget no persiste
///     nada**: junta la selección y la comunica con [onCambiar]. Vincular, si
///     hiciera falta, es problema del Confirmar del slide 3.
///
/// La otra diferencia de fondo: allá la selección se confirma con un botón
/// "Agregar seleccionados (N)" que cierra el diálogo. Acá no hay tal botón —el
/// wizard mira `items.isNotEmpty` para habilitar "Siguiente"—, así que
/// [onCambiar] se dispara en CADA cambio, incluido el tipeo de una cantidad.
class SelectorInsumosAgenda extends StatefulWidget {
  const SelectorInsumosAgenda({
    super.key,
    required this.negocioId,
    required this.proveedorId,
    required this.seleccionados,
    required this.onCambiar,
    required this.puedeVerFinanzas,
  });

  final String negocioId;
  final String proveedorId;

  /// Selección de arranque, en la forma canónica de `pedidos.items`
  /// (`{insumoId, nombre, unidad, cantidadPedida, precioUnitario}`). En alta
  /// viene vacía; en edición, con los ítems que la agenda ya tenía.
  ///
  /// Se lee UNA sola vez, en `initState`. Después la fuente de verdad es el
  /// estado interno: releerla en cada rebuild pisaría el campo de cantidad
  /// mientras el usuario tipea (nuestro propio [onCambiar] hace que el wizard
  /// se reconstruya).
  final List<Map<String, dynamic>> seleccionados;

  /// Avisa la selección completa, ya en forma canónica, ante cualquier cambio.
  final ValueChanged<List<Map<String, dynamic>>> onCambiar;

  /// HU-060: el cocinero no ve costos. Oculta precios y total, pero el
  /// `precioUnitario` se sigue emitiendo: si lo pusiéramos en cero, una agenda
  /// creada por un cocinero nacería con total 0.
  final bool puedeVerFinanzas;

  @override
  State<SelectorInsumosAgenda> createState() => _SelectorInsumosAgendaState();
}

class _SelectorInsumosAgendaState extends State<SelectorInsumosAgenda> {
  String _query = '';

  /// Ids marcados. Es un `LinkedHashSet` (el `Set` por defecto de Dart), así que
  /// respeta el orden en que se fueron eligiendo y la lista emitida no baila.
  final Set<String> _marcados = {};

  /// Un controlador por insumo, vivo aunque se desmarque o se filtre por el
  /// buscador: así volver atrás no pierde la cantidad ya tipeada.
  final Map<String, TextEditingController> _cantidades = {};

  /// Datos del ítem que NO están en el campo de cantidad (nombre, unidad,
  /// precio). Se guardan por id porque la selección tiene que sobrevivir al
  /// filtro del buscador y a una recarga de la oferta.
  final Map<String, Map<String, dynamic>> _datos = {};

  /// Ids con los que llegó la agenda en edición. Se guardan aparte de
  /// [_marcados] para que los que ya no figuran en la oferta se sigan viendo
  /// después de destildarlos: si desaparecieran de la lista, destildar uno sería
  /// un camino de ida (no está en la oferta, así que no hay forma de recuperarlo).
  final Set<String> _heredados = {};

  /// El future se cachea en el State para poder REEMPLAZARLO cuando la oferta
  /// cambie (alta de un insumo desde acá).
  late Future<List<GrupoCategoriaOfrecida>> _futureOferta;

  @override
  void initState() {
    super.initState();
    for (final item in widget.seleccionados) {
      final id = item['insumoId'] as String?;
      if (id == null) continue;
      _marcados.add(id);
      _heredados.add(id);
      _datos[id] = _datoDe(
        id: id,
        nombre: (item['nombre'] as String?) ?? '',
        unidad: (item['unidad'] as String?) ?? '',
        precio: (item['precioUnitario'] as num?)?.toDouble() ?? 0,
      );
      _cantidades[id] = TextEditingController(
        text: CampoNumerico.textoDe(
          (item['cantidadPedida'] as num?)?.toDouble(),
        ),
      );
    }
    _futureOferta = _cargarOferta();
    if (_datos.isNotEmpty) _refrescarDatosGuardados(_futureOferta);
  }

  /// Pone al día nombre, unidad y precio de los ítems que venían de la agenda.
  ///
  /// Lo guardado es una foto del día en que se creó la agenda; el generador,
  /// en cambio, re-resuelve los precios con los de HOY cada vez que materializa
  /// una entrega. Sin este refresco la fila mostraría el precio nuevo (sale de
  /// la oferta) y el estimado —y el resumen del slide 3— seguirían con el viejo.
  ///
  /// Corre en un microtask posterior al `initState`, nunca dentro de un build,
  /// así que el [_emitir] de acá es seguro.
  void _refrescarDatosGuardados(Future<List<GrupoCategoriaOfrecida>> futuro) {
    futuro
        .then((oferta) {
          if (!mounted) return;
          var cambio = false;
          for (final o in _aplanar(oferta)) {
            final viejo = _datos[o.insumo.id];
            if (viejo == null) continue;
            final fresco = _datoDe(
              id: o.insumo.id,
              nombre: o.insumo.nombre,
              unidad: o.insumo.unidad,
              precio: o.precio,
            );
            if (_mismoDato(viejo, fresco)) continue;
            _datos[o.insumo.id] = fresco;
            cambio = true;
          }
          // Sin cambios no se notifica: un `onCambiar` de más haría rebotar al
          // wizard entero por nada.
          if (!cambio) return;
          setState(() {});
          _emitir();
        })
        .catchError((_) {
          // El error de carga ya lo pinta el FutureBuilder; acá no hay nada más
          // que hacer, pero hay que tragarlo para no dejar un future sin dueño.
        });
  }

  static bool _mismoDato(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['nombre'] == b['nombre'] &&
      a['unidad'] == b['unidad'] &&
      a['precioUnitario'] == b['precioUnitario'];

  @override
  void dispose() {
    for (final c in _cantidades.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Es `async` a propósito: si `ServicioPedidos` no estuviera en el árbol de
  /// providers, la excepción del `read` cae DENTRO del future (un cuerpo `async`
  /// captura hasta lo que tira antes del primer `await`) y termina en el estado
  /// de error del `FutureBuilder`, en vez de tumbar el wizard entero.
  Future<List<GrupoCategoriaOfrecida>> _cargarOferta() async {
    final servicio = context.read<ServicioPedidos>();
    return servicio.insumosOfrecidos(
      negocioId: widget.negocioId,
      proveedorId: widget.proveedorId,
    );
  }

  Map<String, dynamic> _datoDe({
    required String id,
    required String nombre,
    required String unidad,
    required double precio,
  }) => {
    'insumoId': id,
    'nombre': nombre,
    'unidad': unidad,
    'precioUnitario': precio,
  };

  /// Cantidad tipeada para un insumo. `null` (campo vacío o texto inválido) vale
  /// 0: no bloquea nada acá porque el servicio filtra los ítems en cero al
  /// persistir, y trabar el slide por un campo a medio tipear sería peor.
  double _cantidadDe(String id) =>
      ValidadorDatos.parsearNumero(_cantidades[id]?.text) ?? 0;

  /// La selección completa, en la forma canónica de `pedidos.items`.
  List<Map<String, dynamic>> _itemsCanonicos() => _marcados
      .where(_datos.containsKey)
      .map((id) => {...?_datos[id], 'cantidadPedida': _cantidadDe(id)})
      .toList();

  void _emitir() => widget.onCambiar(_itemsCanonicos());

  /// Marca un insumo SIN `setState`: la usan el tap y el alta de insumo nuevo,
  /// que ya vienen envueltos en su propio `setState`.
  void _marcar(
    String id, {
    required String nombre,
    required String unidad,
    required double precio,
  }) {
    _marcados.add(id);
    _datos[id] = _datoDe(
      id: id,
      nombre: nombre,
      unidad: unidad,
      precio: precio,
    );
    // Arranca en 1 como en el selector de pedidos: la cantidad más frecuente, y
    // el campo queda listo para sobrescribir.
    _cantidades.putIfAbsent(id, () => TextEditingController(text: '1'));
  }

  void _alternar(InsumoOfrecido ofrecido) {
    setState(() {
      final id = ofrecido.insumo.id;
      // Desmarcar NO destruye el controlador: si se vuelve a marcar, la cantidad
      // que ya se había puesto sigue ahí. Se liberan todos juntos en dispose().
      if (_marcados.remove(id)) return;
      _marcar(
        id,
        nombre: ofrecido.insumo.nombre,
        unidad: ofrecido.insumo.unidad,
        precio: ofrecido.precio,
      );
    });
    _emitir();
  }

  /// Marca/desmarca un ítem heredado de la agenda que ya no figura en la oferta.
  /// Sus datos salen de [_datos], que es lo único que quedó de él.
  void _alternarHeredado(String id) {
    setState(() {
      if (_marcados.remove(id)) return;
      _marcados.add(id);
      _cantidades.putIfAbsent(id, () => TextEditingController(text: '1'));
    });
    _emitir();
  }

  @override
  Widget build(BuildContext context) {
    // Tope de ancho: en una ventana de escritorio, una fila de checkbox estirada
    // a 1400px deja el nombre del insumo lejísimos de su cantidad.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _encabezado(),
          const SizedBox(height: 10),
          _buscador(),
          const SizedBox(height: 12),
          FutureBuilder<List<GrupoCategoriaOfrecida>>(
            future: _futureOferta,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError) return _error(snap.error);
              return _listado(snap.data);
            },
          ),
          if (widget.puedeVerFinanzas && _marcados.isNotEmpty) ...[
            const SizedBox(height: 12),
            _total(),
          ],
        ],
      ),
    );
  }

  Widget _encabezado() {
    final n = _marcados.length;
    return Row(
      children: [
        Expanded(
          child: Text(
            n == 0
                ? 'Elegí qué insumos entran en la agenda'
                : (n == 1 ? '1 insumo elegido' : '$n insumos elegidos'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: n == 0 ? FontWeight.normal : FontWeight.bold,
              color: n == 0 ? Colors.black54 : Colors.black87,
            ),
          ),
        ),
        // Mismo atajo que en el armado de pedidos (HU-139): descubrir que falta
        // un insumo no obliga a abandonar el wizard y perder lo cargado.
        TextButton.icon(
          onPressed: _crearInsumo,
          icon: const Icon(Icons.add_circle_outline, size: 16),
          label: const Text('Insumo nuevo', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buscador() {
    return TextField(
      style: const TextStyle(fontSize: 13, color: Colors.black87),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Buscar insumo...',
        hintStyle: const TextStyle(fontSize: 13),
        prefixIcon: const Icon(Icons.search, size: 20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  Widget _error(Object? error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: InsumaColors.alertRed,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'No se pudo cargar la lista de insumos.\n$error',
        style: const TextStyle(fontSize: 12, color: Colors.black87),
      ),
    );
  }

  Widget _listado(List<GrupoCategoriaOfrecida>? oferta) {
    // #262: los insumos de todas las categorías que suministra el proveedor, en
    // una sola lista (el agrupado por categoría vive en el selector del pedido).
    final delProveedor = _filtrar(_aplanar(oferta));
    // Ítems que la agenda ya tenía pero que hoy no están en la oferta (el insumo
    // se dio de baja, o su categoría ya no la suministra este proveedor). Se
    // muestran igual: si se ocultaran, el contador diría "3 insumos" y en
    // pantalla habría 2.
    final heredados = _heredadosFueraDeOferta(oferta);

    if (delProveedor.isEmpty && heredados.isEmpty) {
      return _vacio();
    }

    return ListView(
      shrinkWrap: true,
      // Scrollea el slide, no la lista —igual que la grilla de `SelectorDiaMes`—:
      // con dos scrolls anidados, en Chrome la rueda del mouse queda peleando
      // entre los dos y el usuario nunca sabe qué va a mover. El precio es que
      // el buscador se va con el scroll en un catálogo largo; se paga, porque
      // buscar acorta la lista y ése es el caso normal.
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        if (heredados.isNotEmpty) ...[
          _tituloSeccion('Ya estaban en la agenda'),
          ...heredados.map(_filaHeredada),
          const SizedBox(height: 4),
        ],
        if (delProveedor.isNotEmpty) ...[
          if (heredados.isNotEmpty) _tituloSeccion('Del proveedor'),
          ...delProveedor.map(_fila),
        ],
      ],
    );
  }

  Widget _vacio() {
    final buscando = _query.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              buscando
                  ? 'Ningún insumo coincide con la búsqueda'
                  : 'Este proveedor todavía no tiene insumos',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              buscando
                  ? 'Probá con otro nombre, o dalo de alta con "Insumo nuevo".'
                  : 'Podés darlos de alta acá mismo con "Insumo nuevo".',
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tituloSeccion(String texto) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      texto,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: Colors.grey,
      ),
    ),
  );

  /// Aplana los grupos por categoría a una lista de insumos ofrecidos.
  static List<InsumoOfrecido> _aplanar(
    List<GrupoCategoriaOfrecida>? oferta,
  ) => [
    for (final g in oferta ?? const <GrupoCategoriaOfrecida>[]) ...g.insumos,
  ];

  List<InsumoOfrecido> _filtrar(List<InsumoOfrecido>? lista) {
    final q = _query.trim().toLowerCase();
    return (lista ?? const <InsumoOfrecido>[])
        .where((o) => o.insumo.nombre.toLowerCase().contains(q))
        .toList();
  }

  /// Ítems que traía la agenda y que hoy no aparecen en la oferta del proveedor.
  List<String> _heredadosFueraDeOferta(List<GrupoCategoriaOfrecida>? oferta) {
    final enOferta = <String>{for (final o in _aplanar(oferta)) o.insumo.id};
    final q = _query.trim().toLowerCase();
    return _heredados
        .where((id) => !enOferta.contains(id))
        .where(
          (id) => ((_datos[id]?['nombre'] as String?) ?? '')
              .toLowerCase()
              .contains(q),
        )
        .toList();
  }

  Widget _fila(InsumoOfrecido ofrecido) {
    final ins = ofrecido.insumo;
    final marcado = _marcados.contains(ins.id);
    return _filaBase(
      id: ins.id,
      nombre: ins.nombre,
      unidad: ins.unidad,
      marcado: marcado,
      // HU-138: se dice DE DÓNDE sale el precio. Un precio heredado del
      // historial no es lo mismo que uno pactado con este proveedor, y
      // mostrarlos igual induce a pedir a ciegas.
      subtitulo: widget.puedeVerFinanzas
          ? 'Unidad: ${ins.unidad} · ${ofrecido.etiquetaPrecio(_money)}'
          : 'Unidad: ${ins.unidad}',
      colorSubtitulo: null,
      onTap: () => _alternar(ofrecido),
    );
  }

  Widget _filaHeredada(String id) {
    final dato = _datos[id] ?? const <String, dynamic>{};
    return _filaBase(
      id: id,
      nombre: (dato['nombre'] as String?) ?? 'Insumo sin nombre',
      unidad: (dato['unidad'] as String?) ?? '',
      marcado: _marcados.contains(id),
      subtitulo:
          'Este proveedor ya no lo ofrece — sigue en la agenda hasta que lo destildes',
      colorSubtitulo: Colors.orange.shade800,
      onTap: () => _alternarHeredado(id),
    );
  }

  Widget _filaBase({
    required String id,
    required String nombre,
    required String unidad,
    required bool marcado,
    required String subtitulo,
    required Color? colorSubtitulo,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: marcado,
          onChanged: (_) => onTap(),
          title: Text(
            nombre,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          subtitle: Text(
            subtitulo,
            style: TextStyle(fontSize: 11, color: colorSubtitulo),
          ),
        ),
        // La cantidad aparece recién al marcar: hasta entonces no hay nada que
        // decidir y ocuparía lugar en una lista larga.
        if (marcado)
          Padding(
            padding: const EdgeInsets.only(left: 52, right: 8, bottom: 8),
            child: SizedBox(
              // #214: ensanchado por legibilidad: los dos botones de paso se comen
              // 64 px y al campo le quedaban menos de 80.
              width: 230,
              child: CampoNumerico(
                // La key NO lleva el valor del campo: si lo llevara, cada tecla
                // crearía un widget nuevo y el foco se perdería (bug de HU-153).
                key: ValueKey('agenda_cant_$id'),
                controlador: _cantidades[id],
                etiqueta: 'Cantidad',
                sufijo: unidad,
                decimales: decimalesDeCantidad(
                  unidad,
                  ValidadorDatos.parsearNumero(_cantidades[id]?.text),
                ),
                paso: 1,
                obligatorio: false,
                permitirCero: true,
                denso: true,
                estilo: const TextStyle(fontSize: 12, color: Colors.black87),
                // Cada tecla se propaga: acá no hay botón "Agregar seleccionados"
                // que confirme la tanda, el wizard lee la selección en vivo.
                alCambiar: (_) => _emitirYRefrescarTotal(),
              ),
            ),
          ),
      ],
    );
  }

  /// El `setState` es sólo para repintar el total; la cantidad la guarda el
  /// propio `TextEditingController`.
  void _emitirYRefrescarTotal() {
    if (widget.puedeVerFinanzas) setState(() {});
    _emitir();
  }

  Widget _total() {
    final total = _itemsCanonicos().fold<double>(
      0,
      (acc, it) =>
          acc +
          ((it['cantidadPedida'] as num).toDouble() *
              (it['precioUnitario'] as num).toDouble()),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: InsumaColors.financialPanelBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: InsumaColors.financialPanelBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'Estimado por entrega',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          Text(
            _money(total),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  /// Da de alta un insumo sin salir del wizard y lo deja marcado (HU-139).
  ///
  /// #262: el formulario se abre con las categorías del proveedor como únicas
  /// opciones, así el insumo nace en una categoría que él suministra y vuelve en
  /// la oferta. Es la ÚNICA escritura en base que dispara este slide, y es
  /// explícita: la pidió el usuario apretando el botón.
  Future<void> _crearInsumo() async {
    // Las categorías que suministra el proveedor de la agenda.
    final oferta = await _futureOferta;
    if (!mounted) return;
    final categoriasPermitidas = [for (final g in oferta) g.categoria];
    if (categoriasPermitidas.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Asignale al menos una categoría al proveedor antes de crear un '
            'insumo desde acá.',
          ),
        ),
      );
      return;
    }

    final creado = await FormularioInsumoModal.mostrar(
      context,
      categoriasPermitidas: categoriasPermitidas,
    );
    if (!mounted || creado == null) return;

    // Se espera la oferta nueva ANTES de pintar para poder tomar de ahí el
    // precio ya resuelto del insumo recién creado, en vez de adivinarlo.
    final futuro = _cargarOferta();
    final ofrecido = await _buscarEnOferta(futuro, creado.id);
    if (!mounted) return;

    setState(() {
      _futureOferta = futuro;
      _marcar(
        creado.id,
        nombre: creado.nombre,
        unidad: creado.unidad,
        // Si por lo que sea no volvió en la oferta, el caché del insumo
        // alcanza — desde #239 un insumo recién creado vale 0 ahí ("a
        // confirmar"): el precio real se resuelve igual al materializar cada
        // entrega.
        precio: ofrecido?.precio ?? creado.costoPorUnidad,
      );
    });
    _emitir();
  }

  /// Busca un insumo en la oferta recién pedida. Devuelve `null` si el future
  /// falla: un error de recarga no puede tumbar el alta que ya se guardó.
  Future<InsumoOfrecido?> _buscarEnOferta(
    Future<List<GrupoCategoriaOfrecida>> futuro,
    String insumoId,
  ) async {
    try {
      final oferta = await futuro;
      for (final o in _aplanar(oferta)) {
        if (o.insumo.id == insumoId) return o;
      }
    } catch (_) {
      // El estado de error ya lo muestra el FutureBuilder.
    }
    return null;
  }
}
