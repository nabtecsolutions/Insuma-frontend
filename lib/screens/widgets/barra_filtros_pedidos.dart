import 'package:flutter/material.dart';

import '../../utils/estados_pedido.dart';
import '../../utils/validador_datos.dart';
import 'campo_numerico.dart';

/// Criterios de filtrado que el usuario eligió en [BarraFiltrosPedidos].
///
/// Es un value object INMUTABLE y sin base de datos: sólo junta lo elegido. El
/// filtrado en sí sigue siendo del módulo puro `filtros_historial_pedidos.dart`,
/// que cada pantalla llama con estos valores — así cada una arma la consulta que
/// le corresponde (la ficha del proveedor, por ejemplo, NO usa el criterio por
/// nombre de proveedor).
///
/// Los montos se guardan como TEXTO CRUDO y no como `double?` a propósito
/// (#170): `FormatosEntrada.decimal` deja tipear una coma sola, que no parsea a
/// número pero SÍ se ve en pantalla. Guardando el parseado, [hayAlguno] daba
/// false, el botón "Limpiar" no se dibujaba y el usuario quedaba con texto a la
/// vista y ninguna forma de borrarlo con el botón. El valor interpretado se pide
/// con [montoMin] / [montoMax].
class CriteriosFiltroPedidos {
  const CriteriosFiltroPedidos({
    this.proveedor = '',
    this.articulo = '',
    this.rangoFechas,
    this.etiquetaEstado = etiquetaTodos,
    this.montoMinTexto = '',
    this.montoMaxTexto = '',
    this.rangoEntrega,
    this.ordenEntregaAscendente,
  });

  /// Etiqueta NEUTRA del filtro por estado, RE-EXPORTADA de
  /// [EstadosPedido.etiquetaTodos] para poder nombrarla desde la UI sin
  /// importar el módulo de estados.
  ///
  /// Es una re-exportación y no una constante propia a propósito: si esto
  /// fuera un segundo literal 'Todos' y el módulo de filtros renombrara el
  /// suyo, la barra seguiría compilando —[hayAlguno] y [vigenteEntre] siguen
  /// coherentes entre sí— pero el criterio que viaja al filtro dejaría de ser
  /// neutro: la lista saldría VACÍA con el desplegable diciendo "Todos".
  static const String etiquetaTodos = EstadosPedido.etiquetaTodos;

  /// Ningún criterio activo. Es el estado inicial de las pantallas.
  static const CriteriosFiltroPedidos vacio = CriteriosFiltroPedidos();

  /// Texto libre; se compara contra el NOMBRE del proveedor.
  final String proveedor;

  /// Texto libre; se compara contra los artículos del pedido.
  final String articulo;

  /// Rango por fecha de CREACIÓN del pedido.
  final DateTimeRange? rangoFechas;

  /// Etiqueta ELEGIDA por el usuario. Puede no existir entre las opciones
  /// disponibles en este momento: ver [vigenteEntre].
  final String etiquetaEstado;

  final String montoMinTexto;
  final String montoMaxTexto;

  /// HU-142: rango por día pedido de entrega.
  final DateTimeRange? rangoEntrega;

  /// HU-142: orden por fecha de entrega. `null` = orden natural del listado.
  final bool? ordenEntregaAscendente;

  /// Monto mínimo interpretado, o `null` si lo tipeado no es un número.
  double? get montoMin => ValidadorDatos.parsearNumero(montoMinTexto);

  /// Monto máximo interpretado, o `null` si lo tipeado no es un número.
  double? get montoMax => ValidadorDatos.parsearNumero(montoMaxTexto);

  /// Hay algún criterio activo (⇒ hay algo que "Limpiar").
  ///
  /// Mira el TEXTO y no los valores parseados, y NO lo recorta con `trim()`: un
  /// espacio o una coma sueltos no filtran nada pero se ven, y esconder ahí el
  /// botón "Limpiar" es exactamente el callejón sin salida de #170.
  bool get hayAlguno =>
      proveedor.isNotEmpty ||
      articulo.isNotEmpty ||
      montoMinTexto.isNotEmpty ||
      montoMaxTexto.isNotEmpty ||
      rangoFechas != null ||
      etiquetaEstado != etiquetaTodos ||
      rangoEntrega != null ||
      ordenEntregaAscendente != null;

  /// Estos mismos criterios pero con el estado SANEADO contra [opciones]: si la
  /// etiqueta elegida ya no existe, vale [etiquetaTodos] (#170).
  ///
  /// Es DERIVADO y no se guarda: las opciones salen de la lista REACTIVA de
  /// pedidos, así que la etiqueta elegida puede desaparecer sola —el último
  /// "A recibir" se recibe y pasa a "Recibido"— y volver a aparecer. Pisando la
  /// elección del usuario, se perdería para siempre y en silencio; derivándola,
  /// el filtro se restablece solo cuando la etiqueta vuelve.
  ///
  /// Lo aplican los DOS lados que tienen que estar de acuerdo: la barra, para
  /// que el `DropdownButton` nunca apunte a un item inexistente, y la pantalla,
  /// justo antes de filtrar. Por eso [BarraFiltrosPedidos] avisa el criterio
  /// CRUDO hacia arriba: si avisara el saneado, la elección quedaría pisada en
  /// la pantalla y al reaparecer la etiqueta el desplegable diría una cosa y la
  /// lista mostraría otra.
  CriteriosFiltroPedidos vigenteEntre(List<String> opciones) =>
      opciones.contains(etiquetaEstado) ? this : _conEstado(etiquetaTodos);

  CriteriosFiltroPedidos _conEstado(String etiqueta) => CriteriosFiltroPedidos(
    proveedor: proveedor,
    articulo: articulo,
    rangoFechas: rangoFechas,
    etiquetaEstado: etiqueta,
    montoMinTexto: montoMinTexto,
    montoMaxTexto: montoMaxTexto,
    rangoEntrega: rangoEntrega,
    ordenEntregaAscendente: ordenEntregaAscendente,
  );
}

/// Barra de filtros de listados de pedidos, compartida por el Historial general
/// (HU-151 + HU-142) y por el historial de la ficha del proveedor (HU-009).
///
/// Estaba duplicada casi textual entre las dos pantallas —controllers, saneo del
/// estado, "Limpiar", el armado del rango de fechas— y ninguna de las dos se va
/// a ningún lado: cada arreglo de UX habría que hacerlo dos veces y la segunda
/// se olvidaría. Acá los campos se ELIGEN según para qué sirve cada pantalla
/// ([mostrarCampoProveedor], [mostrarFiltrosEntrega], [puedeVerFinanzas]).
///
/// Qué NO hace, a propósito:
///  - **No filtra.** Sólo junta criterios y los avisa con [alCambiar]; el
///    filtrado es del módulo puro, que cada pantalla llama como le corresponde.
///  - **No cuenta.** [cantidadResultados] se lo pasa la pantalla, que es la que
///    sabe qué está listando (y que ya hizo la pasada de filtrado: repetirla acá
///    costaría un `jsonDecode` por pedido y por tecla). Se DIBUJA acá porque
///    comparte fila con el botón "Limpiar", adentro del mismo recuadro.
///  - **No decide los estados vacíos.** "Sin pedidos" y "ningún resultado" son
///    de cada pantalla; para el atajo "Limpiar filtros" de esos estados, la
///    pantalla llama a [BarraFiltrosPedidosState.limpiar] con una `GlobalKey`.
class BarraFiltrosPedidos extends StatefulWidget {
  const BarraFiltrosPedidos({
    super.key,
    required this.opcionesEstado,
    required this.cantidadResultados,
    required this.alCambiar,
    required this.puedeVerFinanzas,
    this.criteriosIniciales = CriteriosFiltroPedidos.vacio,
    this.mostrarCampoProveedor = true,
    this.mostrarFiltrosEntrega = true,
    this.margen = EdgeInsets.zero,
    this.decoracion = const BoxDecoration(color: Colors.white),
  });

  /// Etiquetas de estado disponibles, con 'Todos' al frente: salen de
  /// `etiquetasDeEstado(pedidos)` en la PANTALLA, porque dependen de los datos.
  final List<String> opcionesEstado;

  /// Resultados que dio el filtrado de la pantalla, para el contador.
  final int cantidadResultados;

  /// Avisa los criterios ELEGIDOS, sin sanear (ver [CriteriosFiltroPedidos.vigenteEntre]).
  final ValueChanged<CriteriosFiltroPedidos> alCambiar;

  /// Busca por nombre de proveedor. En la ficha del proveedor va en `false`: ya
  /// está acotado por id, que además es exacto (dos proveedores homónimos no se
  /// distinguen por nombre).
  final bool mostrarCampoProveedor;

  /// HU-142: rango por día pedido de entrega + orden por esa misma fecha.
  final bool mostrarFiltrosEntrega;

  /// HU-060: el rango de montos sólo para quien puede ver finanzas. No alcanza
  /// con esconder los campos —eso es cosmética—: los valores tampoco salen en
  /// los criterios, porque si llegaran al filtro el cocinero podría deducir a
  /// fuerza de tanteo el total que la tarjeta le oculta.
  ///
  /// Va OBLIGATORIO y sin valor por defecto: un permiso que se asume concedido
  /// cuando alguien se olvida de pasarlo no falla a la vista, así que el
  /// agujero no se descubre. Que lo exija el compilador.
  final bool puedeVerFinanzas;

  /// Criterios con los que la barra ARRANCA. Sólo se leen en `initState`:
  /// cambiarlos después no tiene efecto (la barra ya es dueña de su estado).
  ///
  /// Existe porque las dos pantallas esconden la barra cuando no queda ningún
  /// pedido que filtrar. Antes de extraerla, los filtros vivían en el State de
  /// la pantalla —que nunca se desmonta— y seguían aplicados cuando la lista
  /// volvía; sin sembrarlos, ese ida y vuelta los perdería en silencio.
  /// Pasándole lo que la pantalla tiene guardado, remontarla no cambia nada.
  final CriteriosFiltroPedidos criteriosIniciales;

  /// Margen exterior del recuadro.
  final EdgeInsets margen;

  /// Fondo del recuadro. Por defecto una banda blanca a sangre completa (la
  /// pantalla de Historial); la ficha del proveedor le pasa la receta de sus
  /// tarjetas —radio 16 y borde claro— porque ahí la barra va metida entre
  /// tarjetas redondeadas y un rectángulo pleno se leería como de otra pantalla.
  final BoxDecoration decoracion;

  @override
  State<BarraFiltrosPedidos> createState() => BarraFiltrosPedidosState();
}

/// Estado PÚBLICO —igual que `FormState`— para que la pantalla pueda limpiar los
/// filtros desde su estado "ningún pedido coincide", que vive fuera de la barra.
class BarraFiltrosPedidosState extends State<BarraFiltrosPedidos> {
  // #170: el controller es la ÚNICA fuente de verdad del texto de cada campo.
  // Cuando el texto vivía duplicado (un `String` en el State + lo que el campo
  // mostraba), "Limpiar" vaciaba sólo el primero: la lista volvía completa pero
  // lo tipeado seguía a la vista, y como no quedaban filtros activos el propio
  // botón "Limpiar" desaparecía, sin ninguna forma de vaciar los campos salvo
  // borrarlos a mano. Con una sola fuente, esa desincronización no se puede
  // volver a escribir.
  final _ctrlProveedor = TextEditingController();
  final _ctrlArticulo = TextEditingController();
  final _ctrlMontoMin = TextEditingController();
  final _ctrlMontoMax = TextEditingController();

  DateTimeRange? _rangoFechas;
  DateTimeRange? _rangoEntrega;
  bool? _ordenEntregaAscendente;

  /// Estado ELEGIDO por el usuario. Puede quedar temporalmente fuera de las
  /// opciones disponibles; se conserva igual, para que el filtro vuelva solo si
  /// la etiqueta reaparece (ver [CriteriosFiltroPedidos.vigenteEntre]).
  String _estado = CriteriosFiltroPedidos.etiquetaTodos;

  @override
  void initState() {
    super.initState();
    // Los campos arrancan con lo que la pantalla ya tenía elegido (normalmente
    // nada). El estado sembrado puede no estar entre las opciones del primer
    // build —la lista es reactiva— y no hace falta cuidarlo acá: `build` sanea
    // con `vigenteEntre` antes de dárselo al desplegable.
    final inicial = widget.criteriosIniciales;
    _ctrlProveedor.text = inicial.proveedor;
    _ctrlArticulo.text = inicial.articulo;
    _ctrlMontoMin.text = inicial.montoMinTexto;
    _ctrlMontoMax.text = inicial.montoMaxTexto;
    _rangoFechas = inicial.rangoFechas;
    _rangoEntrega = inicial.rangoEntrega;
    _ordenEntregaAscendente = inicial.ordenEntregaAscendente;
    _estado = inicial.etiquetaEstado;

    // Y le avisa a la pantalla con qué quedó. En el camino normal es un no-op
    // —le devuelve lo mismo que le pasó—, y esa es justamente la propiedad
    // buscada: pantalla y barra no pueden arrancar desincronizadas ni siquiera
    // por un frame. Si alguna pantalla futura sembrara `vacio` conservando sus
    // criterios, el aviso la corrige en vez de dejar campos en blanco filtrando
    // por lo bajo, que es el callejón sin salida de #170 por otra puerta. Va en
    // post-frame porque avisar desde `initState` haría `setState` de la
    // pantalla en pleno build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.alCambiar(_criterios);
    });
  }

  @override
  void dispose() {
    _ctrlProveedor.dispose();
    _ctrlArticulo.dispose();
    _ctrlMontoMin.dispose();
    _ctrlMontoMax.dispose();
    super.dispose();
  }

  /// Los criterios tal como están ahora.
  ///
  /// Lo que la barra NO muestra sale en su valor neutro aunque el controller
  /// tenga algo viejo: un campo que dejó de existir para esta pantalla no puede
  /// seguir filtrando por lo bajo ni hacer aparecer el botón "Limpiar".
  ///
  /// Ojo con el alcance: eso vale desde el PRÓXIMO aviso, porque los criterios
  /// viajan hacia arriba únicamente cuando algo llama a [_avisar]. Los tres
  /// flags tienen que ser constantes mientras la barra esté montada —hoy lo
  /// son: salen del rol de la sesión o son literales—; si alguna pantalla
  /// necesitara cambiarlos en caliente, que la remonte con otra `key` o que se
  /// agregue un `didUpdateWidget` que los compare y vuelva a avisar. Sin eso, la
  /// barra escondería el campo y el botón "Limpiar" mientras la pantalla sigue
  /// filtrando con lo viejo: el patrón de #170.
  CriteriosFiltroPedidos get _criterios => CriteriosFiltroPedidos(
    proveedor: widget.mostrarCampoProveedor ? _ctrlProveedor.text : '',
    articulo: _ctrlArticulo.text,
    rangoFechas: _rangoFechas,
    etiquetaEstado: _estado,
    montoMinTexto: widget.puedeVerFinanzas ? _ctrlMontoMin.text : '',
    montoMaxTexto: widget.puedeVerFinanzas ? _ctrlMontoMax.text : '',
    rangoEntrega: widget.mostrarFiltrosEntrega ? _rangoEntrega : null,
    ordenEntregaAscendente: widget.mostrarFiltrosEntrega
        ? _ordenEntregaAscendente
        : null,
  );

  /// Repinta la barra (etiquetas de los botones, botón "Limpiar") y avisa hacia
  /// arriba. Siempre juntos: lo que se ve acá y el contador de la pantalla
  /// tienen que salir del MISMO cambio, si no el contador dice un número y la
  /// lista muestra otro.
  void _avisar([VoidCallback? mutar]) {
    setState(() => mutar?.call());
    widget.alCambiar(_criterios);
  }

  /// Deja todos los filtros en su valor neutro, BORRANDO el texto visible.
  ///
  /// Para el usuario el texto y el filtro son la misma cosa, y separarlos es lo
  /// que dejaba campos escritos sin filtro activo (#170). Es público porque el
  /// estado "ningún pedido coincide" —que dibuja la pantalla, no la barra—
  /// ofrece el mismo atajo.
  void limpiar() {
    _ctrlProveedor.clear();
    _ctrlArticulo.clear();
    _ctrlMontoMin.clear();
    _ctrlMontoMax.clear();
    _avisar(() {
      _rangoFechas = null;
      _estado = CriteriosFiltroPedidos.etiquetaTodos;
      _rangoEntrega = null;
      _ordenEntregaAscendente = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // `etiquetasDeEstado` siempre antepone 'Todos'; el guard es por si alguna
    // pantalla armara la lista a mano: sin la opción neutra, el saneo no tendría
    // a dónde caer y el assert del desplegable volvería por la ventana.
    const todos = CriteriosFiltroPedidos.etiquetaTodos;
    final opciones = widget.opcionesEstado.contains(todos)
        ? widget.opcionesEstado
        : [todos, ...widget.opcionesEstado];

    // Saneado contra las opciones de ESTE build: así el `value` del desplegable
    // y sus items no pueden discrepar ni por un frame, y el botón "Limpiar"
    // aparece con los mismos criterios con los que la pantalla filtra.
    final vigentes = _criterios.vigenteEntre(opciones);

    return Container(
      margin: widget.margen,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: widget.decoracion,
      child: Column(
        children: [
          if (widget.mostrarCampoProveedor)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrlProveedor,
                    decoration: const InputDecoration(
                      hintText: 'Proveedor…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    // El controller ya guardó el texto: sólo hay que repintar.
                    onChanged: (_) => _avisar(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _campoArticulo()),
              ],
            )
          else
            _campoArticulo(),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _elegirRango(context),
                  icon: const Icon(Icons.date_range, size: 16),
                  label: Text(
                    _rangoFechas == null
                        ? 'Fechas'
                        : '${_fechaCorta(_rangoFechas!.start)} → ${_fechaCorta(_rangoFechas!.end)}',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // #170: `DropdownButton` y NO `DropdownButtonFormField`. El
              // FormField guarda su valor en un estado propio, aparte del
              // widget, y sólo lo re-sincroniza cuando `initialValue` CAMBIA
              // entre builds: si el usuario elegía una opción del menú ya
              // obsoleto, el valor interno quedaba apuntando a un item que no
              // existe y saltaba el assert "There should be exactly one item
              // with [DropdownButton]'s value" —pantalla roja en Flutter Web
              // debug, que es donde prueba el PO—. `DropdownButton` lee `value`
              // del widget en CADA build, así que no hay estado que
              // desincronizar.
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Estado',
                    isDense: true,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: vigentes.etiquetaEstado,
                      isDense: true,
                      isExpanded: true,
                      items: opciones
                          .map(
                            (e) => DropdownMenuItem(
                              value: e,
                              child: Text(
                                e,
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => _avisar(() => _estado = v ?? todos),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // HU-142: rango por día pedido de entrega + orden por esa misma fecha.
          if (widget.mostrarFiltrosEntrega) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _elegirRangoEntrega(context),
                    icon: const Icon(Icons.event_outlined, size: 16),
                    label: Text(
                      _rangoEntrega == null
                          ? 'Entrega pedida'
                          : '${_fechaCorta(_rangoEntrega!.start)} → ${_fechaCorta(_rangoEntrega!.end)}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Tres estados: sin orden → ascendente → descendente → sin orden.
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _alternarOrdenEntrega,
                    icon: Icon(
                      _ordenEntregaAscendente == null
                          ? Icons.swap_vert
                          : (_ordenEntregaAscendente!
                                ? Icons.arrow_upward
                                : Icons.arrow_downward),
                      size: 16,
                    ),
                    label: Text(
                      _ordenEntregaAscendente == null
                          ? 'Ordenar'
                          : (_ordenEntregaAscendente!
                                ? 'Más próxima'
                                : 'Más lejana'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (widget.puedeVerFinanzas) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: CampoNumerico(
                    etiqueta: 'Monto desde',
                    controlador: _ctrlMontoMin,
                    obligatorio: false,
                    permitirCero: true,
                    denso: true,
                    alCambiar: (_) => _avisar(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: CampoNumerico(
                    etiqueta: 'Monto hasta',
                    controlador: _ctrlMontoMax,
                    obligatorio: false,
                    permitirCero: true,
                    denso: true,
                    alCambiar: (_) => _avisar(),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${widget.cantidadResultados} resultado(s)',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (vigentes.hayAlguno)
                TextButton.icon(
                  onPressed: limpiar,
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text('Limpiar', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// El campo de artículo va en los dos usos; lo que cambia es si comparte fila
  /// con el de proveedor o si ocupa el ancho entero.
  Widget _campoArticulo() => TextField(
    controller: _ctrlArticulo,
    decoration: const InputDecoration(
      hintText: 'Artículo…',
      prefixIcon: Icon(Icons.inventory_2_outlined, size: 18),
      isDense: true,
    ),
    onChanged: (_) => _avisar(),
  );

  Future<void> _elegirRango(BuildContext context) async {
    final hoy = DateTime.now();
    final elegido = await showDateRangePicker(
      context: context,
      firstDate: DateTime(hoy.year - 5),
      lastDate: DateTime(hoy.year + 1),
      initialDateRange: _rangoFechas,
    );
    if (elegido == null || !mounted) return;
    // El final del rango se lleva al último instante del día: si no, un pedido
    // creado a las 15:00 del día "hasta" quedaría afuera.
    _avisar(
      () => _rangoFechas = DateTimeRange(
        start: DateTime(
          elegido.start.year,
          elegido.start.month,
          elegido.start.day,
        ),
        end: DateTime(
          elegido.end.year,
          elegido.end.month,
          elegido.end.day,
          23,
          59,
          59,
        ),
      ),
    );
  }

  /// HU-142: rango de días pedidos de entrega. A diferencia del rango de
  /// creación, acá la ventana se abre hacia ADELANTE: lo que se busca son
  /// entregas futuras. Igual se dejan 5 años atrás para el historial viejo.
  Future<void> _elegirRangoEntrega(BuildContext context) async {
    final hoy = DateTime.now();
    final elegido = await showDateRangePicker(
      context: context,
      firstDate: DateTime(hoy.year - 5),
      lastDate: DateTime(hoy.year + 2),
      initialDateRange: _rangoEntrega,
      helpText: 'Entrega pedida',
    );
    if (elegido == null || !mounted) return;
    // Ambos extremos a medianoche: `fecha_recepcion_solicitada` es un día puro,
    // así que no hace falta estirar el final al 23:59 como con fechaCreacion.
    _avisar(
      () => _rangoEntrega = DateTimeRange(
        start: DateTime(
          elegido.start.year,
          elegido.start.month,
          elegido.start.day,
        ),
        end: DateTime(elegido.end.year, elegido.end.month, elegido.end.day),
      ),
    );
  }

  /// Cicla el orden por entrega: sin orden → más próxima → más lejana → sin orden.
  void _alternarOrdenEntrega() => _avisar(() {
    _ordenEntregaAscendente = switch (_ordenEntregaAscendente) {
      null => true,
      true => false,
      false => null,
    };
  });

  String _fechaCorta(DateTime f) =>
      '${f.day.toString().padLeft(2, '0')}/${f.month.toString().padLeft(2, '0')}';
}
