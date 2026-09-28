import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../services/servicio_pedidos_recurrentes.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../../utils/agenda_recurrente.dart';
import '../../utils/fecha_recepcion.dart';
import 'widgets/selector_dias_semana.dart';
import 'wizard_pedido_recurrente.dart';

/// Pantalla "Pedidos recurrentes" de UN proveedor (HU-013, Etapa 2 del PO).
///
/// Se abre desde el ícono de calendario de la ficha del proveedor y es el único
/// lugar donde se ven, se modifican y se eliminan las agendas de ese proveedor,
/// además de crear una nueva.
///
/// **El modelo, que es lo que explica el diseño de la tarjeta** (decisión del PO
/// del 2026-08-10): el pedido recurrente se confirma UNA sola vez, al crearlo; a
/// partir de ahí cada entrega aparece directamente en Recepciones, ya
/// confirmada. Y hay EXACTAMENTE UNA entrega pendiente por agenda: la próxima no
/// se agenda hasta recepcionar la anterior, **sin gracia**. Por eso el freno
/// tiene que verse acá: una recepción que nadie carga congela la serie para
/// siempre y el usuario tiene que poder entender por qué dejó de aparecer. Esa
/// visibilidad es la mitigación del riesgo que el PO aceptó a sabiendas, no un
/// adorno.
///
/// **Cero lógica de negocio.** El calendario lo resuelven los módulos puros
/// (`agenda_recurrente.dart` / `ancla_agenda.dart`) y el estado de cada serie lo
/// arma [ServicioPedidosRecurrentes.estadoDeAgendas]. Acá sólo se dibuja lo que
/// esos dos devuelven, y las acciones son un `Future<String?>` del Service que
/// la vista muestra tal cual (el error como texto, o `null` si salió bien).
class PantallaPedidosRecurrentes extends StatefulWidget {
  final String negocioId;
  final String proveedorId;
  final String proveedorNombre;

  const PantallaPedidosRecurrentes({
    super.key,
    required this.negocioId,
    required this.proveedorId,
    required this.proveedorNombre,
  });

  @override
  State<PantallaPedidosRecurrentes> createState() =>
      _PantallaPedidosRecurrentesState();
}

class _PantallaPedidosRecurrentesState
    extends State<PantallaPedidosRecurrentes> {
  /// Las agendas se leen REACTIVAMENTE (patrón HU-089): crear, modificar o
  /// eliminar una desde el wizard vuelve por acá sin que la pantalla tenga que
  /// acordarse de recargar.
  StreamSubscription<List<PedidosRecurrente>>? _sub;
  List<PedidosRecurrente> _agendas = const [];

  /// Estado de cada agenda (próxima entrega / freno), indexado por id.
  ///
  /// Mapa y no lista paralela a propósito: `estadoDeAgendas` devuelve las de
  /// TODO el negocio y saltea las filas con una frecuencia que esta versión de
  /// la app no conoce, así que los índices NUNCA calzarían con [_agendas].
  Map<String, EstadoAgenda> _estados = const {};

  /// Sólo hasta la PRIMERA emisión del stream. Si esperáramos a los estados, el
  /// estado vacío parpadearía en cada apertura.
  bool _cargando = true;

  String? _error;

  /// El día contra el que se resolvió [_estados]. Se guarda —en vez de llamar a
  /// `DateTime.now()` al dibujar— para que el `vencida(hoy:)` de la tarjeta use
  /// exactamente el mismo día que usó el Service. Dos `now()` independientes se
  /// contradicen justo al cruzar la medianoche.
  DateTime _hoy = FechaRecepcion.soloDia(DateTime.now());

  /// Descarta el resultado de un recálculo viejo: dos emisiones seguidas del
  /// stream lanzan dos consultas, y la primera puede resolver última.
  int _generacion = 0;

  ServicioPedidosRecurrentes get _servicio =>
      context.read<ServicioPedidosRecurrentes>();

  @override
  void initState() {
    super.initState();
    _sub = _servicio
        .observarDeProveedor(widget.proveedorId)
        .listen(_alLlegarAgendas);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// La lista se pinta EN EL ACTO y los estados se recalculan después: la
  /// próxima entrega depende de pedidos que este stream no mira, así que
  /// esperarla dejaría la lista atrasada respecto de lo que el usuario acaba de
  /// hacer.
  void _alLlegarAgendas(List<PedidosRecurrente> agendas) {
    if (!mounted) return;
    setState(() {
      _agendas = agendas;
      _cargando = false;
    });
    _recalcularEstados();
  }

  Future<void> _recalcularEstados() async {
    final generacion = ++_generacion;
    final hoy = FechaRecepcion.soloDia(DateTime.now());
    try {
      final todos = await _servicio.estadoDeAgendas(widget.negocioId, hoy: hoy);
      if (!mounted || generacion != _generacion) return;
      setState(() {
        _hoy = hoy;
        // `estadoDeAgendas` es de TODO el negocio (una sola pasada, sin N+1):
        // el filtro por proveedor es de esta pantalla.
        _estados = {
          for (final e in todos)
            if (e.agenda.proveedorId == widget.proveedorId) e.agenda.id: e,
        };
      });
    } catch (_) {
      // Si esto falla en silencio, las tarjetas se quedan SIN la línea de la
      // próxima entrega y el usuario ve exactamente el síntoma que esta
      // pantalla existe para explicar ("dejó de aparecer y no sé por qué").
      if (!mounted || generacion != _generacion) return;
      setState(
        () => _error =
            'No se pudo calcular cuándo llega la próxima entrega. Volvé a entrar.',
      );
    }
  }

  /// Ejecuta una acción del Service y muestra el mensaje que devuelva.
  ///
  /// Contrato de la casa (mismo patrón que `ControladorRecibir`): el Service
  /// devuelve el texto del error o `null`, y la vista no interpreta nada. La
  /// lista no se recarga a mano: la escritura hace emitir al stream.
  Future<void> _aplicar(Future<String?> accion) async {
    final error = await accion;
    if (!mounted) return;
    setState(() => _error = error);
  }

  /// Abre el wizard —alta si [edicion] es `null`, edición si viene una agenda—.
  ///
  /// No hay edición inline: una agenda es una frecuencia más N ítems con sus
  /// cantidades, no un número que se corrige en la tarjeta.
  Future<void> _abrirWizard({PedidosRecurrente? edicion}) async {
    // El error de la acción anterior se borra al arrancar otra: si no, un
    // "no se pudo eliminar" en rojo sobrevive al alta que sí funcionó y
    // contradice a la lista que el usuario está mirando.
    setState(() => _error = null);
    final guardo = await WizardPedidoRecurrente.mostrar(
      context,
      negocioId: widget.negocioId,
      proveedorId: widget.proveedorId,
      proveedorNombre: widget.proveedorNombre,
      edicion: edicion,
    );
    if (!mounted || guardo != true) return;
    // El stream ya trae la fila; lo que NO vuelve solo es la próxima entrega,
    // porque cambiar la frecuencia mueve la fecha sin tocar ningún pedido.
    await _recalcularEstados();
  }

  Future<void> _confirmarEliminar(PedidosRecurrente agenda) async {
    // El Service se toma ANTES del diálogo: leer el provider después de un
    // await sobre un context que puede haber muerto es el descuido que
    // `proveedores_tab._confirmarDesactivarProveedor` ya evita así.
    final servicio = _servicio;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Eliminar pedido recurrente',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        content: Text(
          '"${_TarjetaPedidoRecurrente.reglaDe(agenda)}" deja de agendar entregas '
          'nuevas para ${widget.proveedorNombre}. Los pedidos ya hechos no se '
          'tocan: son compromisos reales con el proveedor.',
          style: const TextStyle(fontSize: 13, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmar == true) await _aplicar(servicio.darDeBaja(agenda.id));
  }

  @override
  Widget build(BuildContext context) {
    // Misma regla que la ficha del proveedor, de donde se entra: el cocinero VE
    // la agenda (es el que recibe las entregas) y el admin la administra. No se
    // inventa un Permiso nuevo — ninguno del enum encaja (YAGNI).
    final rol = context.watch<ServicioSesion>().usuarioRol;
    final esAdmin = rol == 'admin';
    final puedeVerFinanzas = Permisos.puede(rol, Permiso.verFinanzas);

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Pedidos recurrentes',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              widget.proveedorNombre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _cuerpo(esAdmin: esAdmin, puedeVerFinanzas: puedeVerFinanzas),
    );
  }

  Widget _cuerpo({required bool esAdmin, required bool puedeVerFinanzas}) {
    return Center(
      // Tope de ancho: en una ventana de escritorio, tarjetas de 1400px con
      // tres líneas de texto quedan ilegibles.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _encabezado(esAdmin),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.red,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            Expanded(
              child: _agendas.isEmpty
                  ? _vacio(esAdmin)
                  : _listado(
                      esAdmin: esAdmin,
                      puedeVerFinanzas: puedeVerFinanzas,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _encabezado(bool esAdmin) {
    final cantidad = _agendas.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              cantidad == 1
                  ? '1 pedido recurrente'
                  : '$cantidad pedidos recurrentes',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
          // Con la lista vacía el alta ya está —y más grande— en el estado
          // vacío: repetirla acá arriba serían dos botones idénticos.
          if (esAdmin && cantidad > 0)
            TextButton.icon(
              onPressed: () => _abrirWizard(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Nuevo', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _vacio(bool esAdmin) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.event_repeat, size: 48, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(
              'Todavía no hay pedidos recurrentes',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              esAdmin
                  ? 'Creá uno y las entregas de ${widget.proveedorNombre} van a '
                        'aparecer solas en Recepciones, ya confirmadas.'
                  : 'Cuando el administrador cree uno, sus entregas aparecen '
                        'solas en Recepciones.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400], fontSize: 11),
            ),
            if (esAdmin) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: () => _abrirWizard(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text(
                  'Nuevo pedido recurrente',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: InsumaColors.primaryBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _listado({required bool esAdmin, required bool puedeVerFinanzas}) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _agendas.length,
      itemBuilder: (context, i) {
        final agenda = _agendas[i];
        return _TarjetaPedidoRecurrente(
          // La key preserva el "ver detalle" abierto cuando el stream reemite.
          key: ValueKey(agenda.id),
          agenda: agenda,
          estado: _estados[agenda.id],
          hoy: _hoy,
          puedeVerFinanzas: puedeVerFinanzas,
          soloLectura: !esAdmin,
          onModificar: () => _abrirWizard(edicion: agenda),
          onEliminar: () => _confirmarEliminar(agenda),
        );
      },
    );
  }
}

/// Tarjeta de UNA agenda: la regla en criollo, cuándo llega la próxima entrega
/// (o por qué no llega ninguna) y los insumos que se piden.
///
/// No reusa `TarjetaPedido`: aquella está tipada contra una fila `Pedido` de
/// Drift y muestra estado/total/fecha de creación. Una agenda no es un pedido,
/// es la plantilla que los genera. Se copia el LOOK —que ya es el mismo en
/// `tarjeta_pedido.dart` y en la lista de proveedores— y nada más.
class _TarjetaPedidoRecurrente extends StatefulWidget {
  final PedidosRecurrente agenda;

  /// Lo que el Service dedujo de esta serie. Puede faltar mientras el recálculo
  /// está en vuelo, o si la fila trae una frecuencia ilegible: en ese caso la
  /// tarjeta se dibuja igual, sin la línea de la próxima entrega.
  final EstadoAgenda? estado;

  /// El MISMO día con el que se resolvió [estado].
  final DateTime hoy;

  /// HU-060: sin este permiso no se muestran precios ni totales.
  final bool puedeVerFinanzas;

  /// El cocinero ve la agenda pero no la toca.
  final bool soloLectura;

  final VoidCallback onModificar;
  final VoidCallback onEliminar;

  const _TarjetaPedidoRecurrente({
    super.key,
    required this.agenda,
    required this.estado,
    required this.hoy,
    required this.puedeVerFinanzas,
    required this.soloLectura,
    required this.onModificar,
    required this.onEliminar,
  });

  /// La regla en CRIOLLO, para el título y para el diálogo de eliminar.
  ///
  /// Devuelve el texto de fallback cuando la fila no se puede leer, así quien la
  /// llama nunca tiene que decidir qué poner.
  static String reglaDe(PedidosRecurrente agenda) {
    final config = _configDe(agenda);
    return config == null ? 'Pedido recurrente' : describirRegla(config);
  }

  /// "Todos los lunes y jueves" · "Todos los 30 de cada mes" · "Cada 7 días,
  /// contando desde que recibo".
  ///
  /// Los días salen de [SelectorDiasSemana.describir], que es el mismo texto que
  /// arma el wizard: si acá se escribiera aparte, la tarjeta terminaría diciendo
  /// algo distinto de lo que el usuario leyó al crear la agenda.
  static String describirRegla(ConfigRecurrencia c) => switch (c.tipo) {
    TipoFrecuencia.semanal =>
      'Todos ${SelectorDiasSemana.describir(c.diasSemana)}',
    TipoFrecuencia.mensual => 'Todos los ${c.diaMes} de cada mes',
    TipoFrecuencia.cadaNDias => _describirCadaNDias(c),
  };

  /// El ancla es lo ÚNICO que distingue dos agendas de "cada N días" con el
  /// mismo N, así que va en el título y no escondida en el detalle.
  static String _describirCadaNDias(ConfigRecurrencia c) {
    final n = c.cadaNDias!;
    final cada = n == 1 ? 'Todos los días' : 'Cada $n días';
    return c.ancla == AnclaRecurrencia.real
        ? '$cada, contando desde que recibo'
        : '$cada, aunque la entrega se atrase';
  }

  /// Reconstruye la regla desde la fila con la API del módulo puro (nada de
  /// interpretar códigos a mano acá), y devuelve `null` si no se puede usar.
  ///
  /// El `validar` no es paranoia: estas filas también llegan del pull de
  /// Supabase, y una máscara de días en 0, un `diaMes` fuera de 1..31 o un N
  /// negativo harían que el título dijera "Todos " y que no hubiera ninguna
  /// próxima fecha, sin una sola pista de por qué.
  static ConfigRecurrencia? _configDe(PedidosRecurrente a) {
    final tipo = AgendaRecurrente.tipoDesdeCodigo(a.tipo);
    if (tipo == null) return null;
    final config = ConfigRecurrencia(
      tipo: tipo,
      diasSemana: AgendaRecurrente.desdeBitmask(a.diasSemana),
      diaMes: a.diaMes,
      cadaNDias: a.cadaNDias,
      ancla: AgendaRecurrente.anclaDesdeCodigo(a.ancla),
      fechaInicio: a.fechaInicio,
    );
    return AgendaRecurrente.validar(config) == null ? config : null;
  }

  /// Los ítems guardados, en la forma canónica de `pedidos.items`. Lectura
  /// defensiva: la columna es JSON y puede venir de otra versión de la app.
  static List<Map<String, dynamic>> _itemsDe(PedidosRecurrente a) {
    try {
      final crudo = jsonDecode(a.items);
      if (crudo is! List) return const [];
      return crudo.whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// "3 insumos · Tomate, Cebolla y 1 más".
  ///
  /// Sin insumos la agenda no puede materializar nada. No debería pasar (el
  /// Service lo rechaza al crear), pero la fila puede llegar del pull.
  static String _resumir(List<Map<String, dynamic>> items) {
    if (items.isEmpty) return 'Sin insumos';
    final nombres = items.map(_nombreDe).toList();
    final etiqueta = items.length == 1 ? '1 insumo' : '${items.length} insumos';
    if (items.length == 1) return '$etiqueta · ${nombres[0]}';
    if (items.length == 2) return '$etiqueta · ${nombres[0]} y ${nombres[1]}';
    return '$etiqueta · ${nombres[0]}, ${nombres[1]} y ${items.length - 2} más';
  }

  static double _total(List<Map<String, dynamic>> items) => items.fold<double>(
    0,
    (acc, it) =>
        acc +
        ((it['cantidadPedida'] as num?) ?? 0) *
            ((it['precioUnitario'] as num?) ?? 0),
  );

  /// Los campos se leen con tolerancia: el JSON lo pudo escribir otra versión.
  static String _nombreDe(Map<String, dynamic> item) {
    final nombre = (item['nombre'] as String?)?.trim();
    return (nombre == null || nombre.isEmpty) ? 'Insumo' : nombre;
  }

  /// Sin decimales cuando no hacen falta: "3 kg" y no "3.00 kg".
  static String _cantidadDe(Map<String, dynamic> item) {
    final cantidad = (item['cantidadPedida'] as num?)?.toDouble() ?? 0;
    return cantidad == cantidad.roundToDouble()
        ? cantidad.toStringAsFixed(0)
        : cantidad.toStringAsFixed(2);
  }

  @override
  State<_TarjetaPedidoRecurrente> createState() =>
      _TarjetaPedidoRecurrenteState();
}

class _TarjetaPedidoRecurrenteState extends State<_TarjetaPedidoRecurrente> {
  /// El detalle arranca plegado: la lista tiene que dejar comparar las agendas
  /// entre sí, y para eso lo que importa es la regla y la próxima entrega.
  bool _detalleAbierto = false;

  @override
  Widget build(BuildContext context) {
    final agenda = widget.agenda;
    final config = _TarjetaPedidoRecurrente._configDe(agenda);
    final items = _TarjetaPedidoRecurrente._itemsDe(agenda);
    final estado = widget.estado;

    // La serie está frenada Y la entrega que la frena ya pasó de fecha. Es el
    // caso que hay que hacer imposible de no ver: sin gracia, nadie la va a
    // desbloquear si no se entera.
    final vencida = estado?.vencida(hoy: widget.hoy) ?? false;

    // Puede no haber nada que decir de la serie (el recálculo todavía viaja):
    // se resuelve acá para no dejar dos separadores pegados en ese caso.
    final linea = _estadoDeLaSerie(config, estado, vencida);

    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: vencida
              ? Colors.orange.shade300
              : InsumaColors.cardBorderLight,
          width: vencida ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _encabezado(config),
            if (linea != null) ...[const SizedBox(height: 8), linea],
            const SizedBox(height: 8),
            _resumenDeItems(items),
            if (_detalleAbierto) ...[
              const SizedBox(height: 8),
              _detalle(items),
            ],
          ],
        ),
      ),
    );
  }

  /// Ícono + regla en criollo + botonera. Mismo `Icons.event_repeat` con el que
  /// se entra desde la ficha del proveedor.
  Widget _encabezado(ConfigRecurrencia? config) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(
            Icons.event_repeat,
            size: 15,
            color: InsumaColors.primaryBlue,
          ),
        ),
        const SizedBox(width: 6),
        // Expanded o el título de dos renglones desborda en 360px.
        Expanded(
          child: Text(
            config == null
                ? 'Pedido recurrente'
                : _TarjetaPedidoRecurrente.describirRegla(config),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
        ),
        if (!widget.soloLectura) ...[
          IconButton(
            tooltip: 'Modificar',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.edit_outlined,
              size: 18,
              color: InsumaColors.primaryBlue,
            ),
            onPressed: widget.onModificar,
          ),
          IconButton(
            tooltip: 'Eliminar',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.delete_outline,
              size: 18,
              color: Colors.redAccent,
            ),
            onPressed: widget.onEliminar,
          ),
        ],
      ],
    );
  }

  /// Cuándo llega la próxima entrega, o el motivo por el que no hay ninguna.
  /// `null` = no hay nada que mostrar todavía.
  Widget? _estadoDeLaSerie(
    ConfigRecurrencia? config,
    EstadoAgenda? estado,
    bool vencida,
  ) {
    if (config == null) {
      return _franja(
        texto:
            'No se reconoce la frecuencia de este pedido recurrente. '
            'Actualizá la app para poder verlo y modificarlo.',
        destacada: false,
        icono: Icons.help_outline,
      );
    }

    // Todavía no llegó el recálculo (o la agenda no estaba en la respuesta):
    // se omite la línea en vez de bloquear la tarjeta entera.
    if (estado == null) return null;

    if (estado.enEspera) {
      // `esperandoDesde` puede faltar aunque la serie esté frenada: la fecha de
      // un pedido es opcional y borrable, y el bloqueo cuelga del ESTADO.
      final desde = estado.esperandoDesde;
      final cual = desde == null
          ? 'la entrega pendiente'
          : 'la del ${FechaRecepcion.formatear(desde)}';
      return _franja(
        texto: vencida
            ? 'Esa entrega ya pasó de fecha. La próxima se agenda recién cuando '
                  'recibas $cual.'
            : 'La próxima se agenda cuando recibas $cual.',
        destacada: vencida,
        icono: vencida ? Icons.warning_amber_rounded : Icons.hourglass_empty,
      );
    }

    final proxima = estado.proxima;
    if (proxima == null) return null;

    return Row(
      children: [
        const Icon(Icons.event_outlined, size: 12, color: Colors.grey),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            'Próxima entrega: ${FechaRecepcion.formatear(proxima)}'
            '${_arrancaDespues(config) ? ' (la serie arranca el ${FechaRecepcion.formatear(config.fechaInicio)})' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  /// Una agenda con fecha de inicio futura no entrega nada hasta ese día. Se
  /// aclara sólo en ese caso, para no repetir un dato inútil en el 99%.
  bool _arrancaDespues(ConfigRecurrencia config) =>
      config.fechaInicio.isAfter(widget.hoy);

  /// Franja de aviso. Es la MISMA forma que el aviso de corrimiento del selector
  /// de día del mes: ícono + texto de 12 sobre un fondo redondeado.
  ///
  /// El ámbar (`alertYellow`) queda reservado para la serie frenada y vencida.
  /// Si lo usara también la espera normal, el destaque dejaría de significar
  /// "acá hay algo trabado".
  Widget _franja({
    required String texto,
    required bool destacada,
    required IconData icono,
  }) {
    final color = destacada ? Colors.orange.shade900 : Colors.black54;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: destacada ? InsumaColors.alertYellow : Colors.grey[100],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(texto, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  /// "3 insumos · Tomate, Cebolla y 1 más", con el detalle desplegable.
  Widget _resumenDeItems(List<Map<String, dynamic>> items) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: items.isEmpty
          ? null
          : () => setState(() => _detalleAbierto = !_detalleAbierto),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            const Icon(
              Icons.inventory_2_outlined,
              size: 12,
              color: Colors.grey,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _TarjetaPedidoRecurrente._resumir(items),
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
            if (items.isNotEmpty)
              Icon(
                _detalleAbierto ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: Colors.grey[500],
              ),
          ],
        ),
      ),
    );
  }

  /// El detalle es una `Column` y NUNCA una lista con scroll propio: en Chrome,
  /// un scroll adentro de otro deja la rueda del mouse peleando entre los dos.
  Widget _detalle(List<Map<String, dynamic>> items) {
    final nota = widget.agenda.nota?.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                _lineaDeItem(item),
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
          // HU-060: el total y los precios son información financiera. Y se
          // aclara que es ESTIMADO porque los precios se resuelven recién al
          // materializar cada entrega, con los vigentes de ese día.
          if (widget.puedeVerFinanzas) ...[
            const SizedBox(height: 4),
            Text(
              'Total estimado: '
              '\$${_TarjetaPedidoRecurrente._total(items).toStringAsFixed(2)} '
              '(cada entrega se arma con los precios de ese día)',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          // El efectivo NO va bajo el permiso financiero: no es un importe, es
          // cómo se paga la entrega, y quien recibe tiene que saberlo. Mismo
          // criterio que el switch del formulario de pedido, que tampoco se
          // esconde por rol.
          if (widget.agenda.tieneEfectivo) ...[
            const SizedBox(height: 4),
            const Text(
              'Se paga en efectivo',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          if (nota != null && nota.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Nota: $nota',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _lineaDeItem(Map<String, dynamic> item) {
    final cantidad = _TarjetaPedidoRecurrente._cantidadDe(item);
    final unidad = (item['unidad'] as String?)?.trim() ?? '';
    final precio = (item['precioUnitario'] as num?)?.toDouble();
    final buffer = StringBuffer(
      '•  ${_TarjetaPedidoRecurrente._nombreDe(item)}  —  $cantidad',
    );
    if (unidad.isNotEmpty) buffer.write(' $unidad');
    if (widget.puedeVerFinanzas && precio != null) {
      buffer.write('  ·  \$${precio.toStringAsFixed(2)} c/u');
    }
    return buffer.toString();
  }
}
