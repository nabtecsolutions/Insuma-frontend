import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../utils/enlaces_externos.dart';
import '../../controllers/controlador_pedido_recurrente.dart';
import '../../controllers/controlador_recibir.dart';
import '../../database/database.dart';
import '../../services/servicio_pedidos_recurrentes.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_sesion.dart';
import '../../theme/insuma_colors.dart';
import '../../utils/agenda_recurrente.dart';
import '../../utils/fecha_recepcion.dart';
import '../widgets/campo_fecha.dart';
import '../widgets/campo_numerico.dart';
import 'widgets/selector_dia_mes.dart';
import 'widgets/selector_dias_semana.dart';
import 'widgets/selector_insumos_agenda.dart';

/// Wizard de alta y edición de un pedido recurrente (HU-013), en tres slides:
/// (1) cada cuánto se repite, (2) qué insumos y cuántos, (3) resumen y confirmar.
///
/// **El modelo, que es lo que explica la pantalla**: el recurrente se confirma
/// UNA sola vez, acá. Al confirmar se le manda al proveedor un único aviso que
/// describe la PERIODICIDAD ("estos ítems todos los martes, queda pactado"), y
/// desde entonces cada entrega aparece directamente en Recepciones, ya
/// confirmada. Por eso el slide 3 remata en el aviso y no en un "enviar pedido".
///
/// Decisiones de estructura, todas con motivo:
///  • **`PageView` con `NeverScrollableScrollPhysics`**: se avanza con los
///    botones, nunca con un swipe, así no hay forma de saltearse la validación
///    de un paso. Es el mismo esqueleto del único wizard que ya tiene el repo
///    (`onboarding_screen.dart`).
///  • **Una sola ruta y no tres pantallas**: en Chrome —donde prueba el PO— el
///    botón Atrás del navegador saltaría fuera del wizard en vez de al slide
///    anterior. Con un `PageView`, el Atrás sale una sola vez y el retroceso de
///    pasos es el botón de abajo.
///  • **El `ChangeNotifierProvider` se crea EN LA RUTA** (ver [mostrar]), nunca
///    en el `MultiProvider` de `main.dart`: al hacer pop, el borrador del
///    recurrente muere, y así no puede filtrarse al borrador de pedido que el
///    usuario tenga a medio armar en "Nuevo Pedido".
///
/// Acá NO hay una sola regla de negocio: las de calendario viven en
/// `AgendaRecurrente` y las del wizard en [ControladorPedidoRecurrente].
class WizardPedidoRecurrente extends StatefulWidget {
  const WizardPedidoRecurrente({super.key});

  /// Abre el wizard. Devuelve `true` si se creó o modificó la agenda, y `null`
  /// (o `false`) si el usuario se volvió sin confirmar — con eso alcanza para
  /// que la pantalla que lo abrió decida si recarga.
  ///
  /// [edicion] precarga una agenda existente; si es `null`, es un alta.
  static Future<bool?> mostrar(
    BuildContext context, {
    required String negocioId,
    required String proveedorId,
    required String proveedorNombre,
    PedidosRecurrente? edicion,
  }) {
    // El Service se resuelve con el contexto de QUIEN ABRE y se captura: el
    // `create` del provider corre después, ya dentro de la ruta nueva, y así no
    // depende de dónde quede colgada en el árbol.
    final servicio = context.read<ServicioPedidosRecurrentes>();
    return Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ChangeNotifierProvider<ControladorPedidoRecurrente>(
          create: (_) => ControladorPedidoRecurrente(
            servicio: servicio,
            negocioId: negocioId,
            proveedorId: proveedorId,
            proveedorNombre: proveedorNombre,
            edicion: edicion,
          ),
          child: const WizardPedidoRecurrente(),
        ),
      ),
    );
  }

  @override
  State<WizardPedidoRecurrente> createState() => _WizardPedidoRecurrenteState();
}

class _WizardPedidoRecurrenteState extends State<WizardPedidoRecurrente> {
  static const int _totalPasos = 3;

  /// Tope de ancho del contenido. Sin él, en una ventana de escritorio los
  /// campos y las tarjetas se estiran de borde a borde y quedan ilegibles.
  static const double _anchoMaximo = 560;

  final PageController _pageController = PageController();

  /// Paso visible, 0..2. Vive en el State y no en el controlador a propósito:
  /// es navegación de esta pantalla, no parte del pedido recurrente.
  int _paso = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _avanzar() {
    if (_paso >= _totalPasos - 1) return;
    setState(() => _paso++);
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _retroceder() {
    if (_paso == 0) return;
    setState(() => _paso--);
    _pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  // --- Guardar y avisar ------------------------------------------------------

  /// Guarda la agenda y, recién después, ofrece el aviso al proveedor.
  ///
  /// El ORDEN es lo importante: cuando `confirmar()` devuelve `null` la agenda
  /// YA está guardada. Si el proveedor no tiene un teléfono válido, el aviso no
  /// se puede mandar y eso se informa, pero **no** convierte el alta en un
  /// fracaso ni impide cerrar el wizard: si no, un admin sin el teléfono cargado
  /// creería que no se creó nada.
  Future<void> _confirmar(ControladorPedidoRecurrente ctrl) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await ctrl.confirmar();
    if (!mounted) return;
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    await _ofrecerAviso(ctrl);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// Ofrece mandarle al proveedor el aviso de la periodicidad, con el texto ya
  /// armado y EDITABLE (mismo trato que el resumen del pedido normal, HU-063).
  ///
  /// En una edición el aviso también se ofrece —y no se manda solo—: es la
  /// decisión 5 del PO, "al modificar se OFRECE reenviar, el usuario decide".
  ///
  /// **El catch no es paranoia**: este paso corre DESPUÉS de guardar, así que la
  /// agenda ya existe. Si algo de acá falla —el controlador de pedidos no está
  /// en el árbol, la consulta del teléfono revienta— el error subiría por
  /// `_confirmar`, el wizard no se cerraría y el usuario volvería a confirmar
  /// una agenda que YA se creó, duplicándola. Degradar a "se guardó, pero no se
  /// pudo ofrecer el WhatsApp" es la única salida correcta.
  Future<void> _ofrecerAviso(ControladorPedidoRecurrente ctrl) async {
    try {
      await _mostrarAviso(ctrl);
    } catch (e) {
      debugPrint('[AGENDA] No se pudo ofrecer el aviso al proveedor: $e');
    }
  }

  Future<void> _mostrarAviso(ControladorPedidoRecurrente ctrl) async {
    // Lectura PURA del controlador de pedidos: `contactoDeProveedor` delega en
    // el Service y `envio` sólo arma la URL. No se le toca ni un campo del
    // borrador vivo — eso es lo que corrompería el pedido que el usuario tenga
    // a medio armar en "Nuevo Pedido".
    final recibir = context.read<ControladorRecibir>();
    final messenger = ScaffoldMessenger.of(context);
    // #235: el diálogo de recurrentes solo ofrece WhatsApp; del contacto se
    // usa el teléfono. Si el PO quiere el email también acá, es tema aparte.
    final telefono = (await recibir.contactoDeProveedor(
      ctrl.proveedorId,
    )).telefono;
    if (!mounted) return;

    final mensajeCtrl = TextEditingController(text: ctrl.textoParaProveedor);
    // Se calcula con el texto inicial sólo para saber si el TELÉFONO sirve: el
    // envío real usa lo que el usuario haya dejado escrito.
    final puedeEnviar =
        recibir.envio.construirUrl(
          telefonoProveedor: telefono,
          mensaje: mensajeCtrl.text,
        ) !=
        null;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          // Con el teclado abierto en un teléfono, un diálogo con un campo
          // multilínea no entra: `scrollable` lo resuelve sin layouts a mano.
          scrollable: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            ctrl.esEdicion
                ? 'Avisale del cambio al proveedor'
                : 'Avisale al proveedor',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ctrl.esEdicion
                      ? 'El pedido recurrente ya quedó actualizado. Si querés, '
                            'mandale el mensaje con los cambios.'
                      : 'El pedido recurrente ya quedó guardado. Este aviso se '
                            'manda UNA sola vez: desde ahora las entregas '
                            'aparecen directas en Recepciones.',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: mensajeCtrl,
                  maxLines: null,
                  minLines: 6,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                    helperText: 'Podés editarlo antes de enviarlo.',
                  ),
                ),
                if (!puedeEnviar) ...[
                  const SizedBox(height: 12),
                  const _Aviso(
                    icono: Icons.warning_amber_rounded,
                    texto:
                        'El proveedor no tiene un teléfono válido. Cargá un '
                        'número en su ficha para poder avisarle por WhatsApp.',
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Ahora no'),
            ),
            ElevatedButton.icon(
              onPressed: puedeEnviar
                  ? () async {
                      final url = recibir.envio.construirUrl(
                        telefonoProveedor: telefono,
                        mensaje: mensajeCtrl.text,
                      );
                      Navigator.of(dialogContext).pop();
                      if (url == null) return;
                      // #220: unificado en `EnlacesExternos`.
                      if (!await EnlacesExternos.abrir(url)) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text('No se pudo abrir WhatsApp.'),
                          ),
                        );
                      }
                    }
                  : null,
              icon: const Icon(Icons.chat_bubble_outline, size: 18),
              label: const Text('Enviar por WhatsApp'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(
                  0xFF25D366,
                ), // el verde de WhatsApp
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    } finally {
      mensajeCtrl.dispose();
    }
  }

  // --- Armado ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ctrl = context.watch<ControladorPedidoRecurrente>();
    // HU-060: el cocinero no ve precios. Se calcula UNA vez y se reparte, así
    // el resumen y el selector de insumos no pueden discrepar.
    final puedeVerFinanzas = Permisos.puede(
      context.watch<ServicioSesion>().usuarioRol,
      Permiso.verFinanzas,
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ctrl.esEdicion ? 'Modificar pedido fijo' : 'Pedido recurrente',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              ctrl.proveedorNombre,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
        bottom: _barraProgreso(),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              // Se avanza sólo con los botones: un swipe podría saltearse la
              // validación del paso.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _slidePeriodicidad(ctrl),
                _slideInsumos(ctrl, puedeVerFinanzas),
                _slideResumen(ctrl, puedeVerFinanzas),
              ],
            ),
          ),
          _botonera(ctrl),
        ],
      ),
    );
  }

  /// "Paso 1 de 3" + tres segmentos. Va en el `bottom` de la AppBar para que
  /// quede fijo mientras el slide scrollea.
  PreferredSizeWidget _barraProgreso() {
    return PreferredSize(
      // Alto holgado a propósito: el texto crece con la escala de fuente del
      // sistema y un `PreferredSize` justo se desborda en cuanto alguien la sube.
      preferredSize: const Size.fromHeight(46),
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paso ${_paso + 1} de $_totalPasos',
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < _totalPasos; i++)
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      margin: EdgeInsets.only(
                        right: i == _totalPasos - 1 ? 0 : 4,
                      ),
                      height: 4,
                      decoration: BoxDecoration(
                        color: i <= _paso
                            ? InsumaColors.primaryBlue
                            : Colors.grey[200],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- Slide 1: cada cuánto se repite ---------------------------------------

  Widget _slidePeriodicidad(ControladorPedidoRecurrente ctrl) {
    return _slideScrolleable([
      _tarjeta([
        const Text(
          '¿Cada cuánto se repite?',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final t in TipoFrecuencia.values)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: t == TipoFrecuencia.values.last ? 0 : 6,
                  ),
                  child: _OpcionTipo(
                    tipo: t,
                    elegido: ctrl.tipo == t,
                    onTap: () => ctrl.cambiarTipo(t),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 24),
        // El selector del tipo elegido va en la MISMA tarjeta (pedido del PO):
        // elegir la frecuencia y configurarla es un solo gesto.
        _selectorDelTipo(ctrl),
      ]),
      _tarjeta([
        const Text(
          '¿Desde cuándo?',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Desde este día se empiezan a contar las entregas. Si ponés una '
          'fecha más adelante, hasta ese día no llega ninguna.',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 12),
        CampoFecha(
          etiqueta: 'Fecha de inicio',
          valor: ctrl.fechaInicio,
          // En una edición la agenda puede haber arrancado hace meses: sin este
          // piso, el calendario no dejaría volver a elegir su propia fecha.
          primeraFecha:
              ctrl.fechaInicio.isBefore(FechaRecepcion.minima(hoy: ctrl.hoy))
              ? ctrl.fechaInicio
              : FechaRecepcion.minima(hoy: ctrl.hoy),
          // El mismo tope que cualquier pedido (6 meses): una entrega más lejos
          // que eso no se materializa hasta entrar en ventana.
          ultimaFecha: FechaRecepcion.maxima(hoy: ctrl.hoy),
          onCambiar: (f) {
            if (f != null) ctrl.cambiarFechaInicio(f);
          },
          permiteBorrar: false,
        ),
        // Para la frecuencia mensual la vista previa ya la muestra
        // `SelectorDiaMes` arriba —y mejor: nombra el mes que se corre—, así
        // que repetirla acá serían dos listas de fechas para la misma regla.
        if (ctrl.tipo != TipoFrecuencia.mensual) ...[
          const Divider(height: 24),
          _vistaPrevia(ctrl),
        ],
      ]),
    ]);
  }

  Widget _selectorDelTipo(ControladorPedidoRecurrente ctrl) {
    switch (ctrl.tipo) {
      case TipoFrecuencia.semanal:
        return SelectorDiasSemana(
          valor: ctrl.diasSemana,
          onCambiar: ctrl.cambiarDiasSemana,
        );
      case TipoFrecuencia.mensual:
        return SelectorDiaMes(
          valor: ctrl.diaMes,
          onCambiar: ctrl.cambiarDiaMes,
          // La proyección arranca donde la manda el controlador (hoy, o la
          // fecha de inicio si la agenda empieza más adelante): si no, esta
          // lista y la de la regla mostrarían fechas distintas.
          hoy: ctrl.desdeProyeccion,
        );
      case TipoFrecuencia.cadaNDias:
        return _configCadaNDias(ctrl);
    }
  }

  Widget _configCadaNDias(ControladorPedidoRecurrente ctrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: CampoNumerico(
            // La key ata el campo a ESTE tipo: al ir y volver de otra
            // frecuencia, el campo se rearma con el valor del controlador en
            // vez de quedarse con lo último tipeado.
            key: const ValueKey('agenda_cada_n_dias'),
            etiqueta: 'Cada cuántos días',
            valorInicial: ctrl.cadaNDias?.toDouble(),
            // Sin esto quedarían 2 decimales (el default es dinero) y se podría
            // tipear "cada 2,5 días", que no existe.
            decimales: 0,
            sufijo: 'días',
            alCambiar: (v) => ctrl.cambiarCadaNDias(v?.round()),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          '¿Desde cuándo se cuentan los días?',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 6),
        // Los dos anclajes, explicados por lo que le pasa al usuario y no por
        // cómo se llaman adentro ('fija' / 'recepcion').
        _OpcionAncla(
          etiqueta: 'Empiezo a contar cuando recibo el pedido',
          detalle:
              'Si una entrega llega tarde, la siguiente se corre igual: '
              'siempre pasan los mismos días entre una y otra.',
          elegido: ctrl.ancla == AnclaRecurrencia.real,
          onTap: () => ctrl.cambiarAncla(AnclaRecurrencia.real),
        ),
        const SizedBox(height: 8),
        _OpcionAncla(
          etiqueta: 'Cuento igual, aunque la entrega se atrase',
          detalle:
              'Las fechas quedan fijas desde el día de inicio, pase lo que '
              'pase con las entregas.',
          elegido: ctrl.ancla == AnclaRecurrencia.fija,
          onTap: () => ctrl.cambiarAncla(AnclaRecurrencia.fija),
        ),
      ],
    );
  }

  /// Las próximas entregas, en vivo.
  ///
  /// Con el ancla "cuento desde que recibo" se muestra UNA sola fecha: las
  /// siguientes dependen de recepciones que todavía no ocurrieron, así que
  /// dibujarlas sería inventarlas. El controlador ya decide cuántas hay
  /// ([ControladorPedidoRecurrente.vistaPreviaLimitada]); acá sólo se pintan.
  Widget _vistaPrevia(ControladorPedidoRecurrente ctrl) {
    final fechas = ctrl.proximasEntregas;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Próximas entregas',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 4),
        if (fechas.isEmpty)
          const Text(
            'Completá la frecuencia para ver cuándo llegarían los pedidos.',
            style: TextStyle(fontSize: 12, color: Colors.black45),
          )
        else
          for (final f in fechas)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '•  ${FechaRecepcion.formatear(f)}',
                style: const TextStyle(fontSize: 12, color: Colors.black87),
              ),
            ),
        if (ctrl.vistaPreviaLimitada && fechas.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Sólo se puede saber la primera: como los días se cuentan desde que '
            'recibís, la siguiente se agenda recién cuando cargues esta entrega.',
            style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
          ),
        ],
      ],
    );
  }

  // --- Slide 2: los insumos --------------------------------------------------

  Widget _slideInsumos(
    ControladorPedidoRecurrente ctrl,
    bool puedeVerFinanzas,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '¿Qué se pide cada vez?',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Estos insumos y estas cantidades se repiten en cada entrega. '
                'Los precios se actualizan solos.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        // El scroll lo pone ESTE slide, no el selector: adentro el selector
        // usa una lista con `shrinkWrap` + `NeverScrollableScrollPhysics`, que
        // se mide entera. Sin este `SingleChildScrollView` no scrollea nadie y
        // con más de un puñado de insumos las filas de abajo quedan
        // INALCANZABLES (no hay rueda ni arrastre que llegue).
        //
        // El `Center` además es lo que hace valer el tope de ancho del
        // selector: con `crossAxisAlignment: stretch` el ancho baja TIGHT y un
        // `ConstrainedBox` no puede achicarlo, así que en una ventana ancha el
        // slide 2 se estiraba de borde a borde mientras el 1 y el 3 quedaban
        // centrados — el contenido saltaba de lugar al apretar "Siguiente".
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Center(
              child: SelectorInsumosAgenda(
                negocioId: ctrl.negocioId,
                proveedorId: ctrl.proveedorId,
                seleccionados: ctrl.items,
                onCambiar: ctrl.cambiarItems,
                puedeVerFinanzas: puedeVerFinanzas,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // --- Slide 3: resumen ------------------------------------------------------

  Widget _slideResumen(
    ControladorPedidoRecurrente ctrl,
    bool puedeVerFinanzas,
  ) {
    final fechas = ctrl.proximasEntregas;
    return _slideScrolleable([
      _tarjeta([
        Row(
          children: [
            const Icon(
              Icons.event_repeat,
              size: 16,
              color: InsumaColors.primaryBlue,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ctrl.proveedorNombre,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // La periodicidad en criollo la redacta el controlador: es el MISMO
        // texto que va a leer el proveedor en el WhatsApp.
        _fila(Icons.repeat, 'Se recibe ${ctrl.descripcionPeriodicidad}'),
        if (ctrl.descripcionAncla != null)
          _fila(Icons.timer_outlined, ctrl.descripcionAncla!),
        _fila(
          Icons.event_outlined,
          'Empieza el ${FechaRecepcion.formatear(ctrl.fechaInicio)}',
        ),
        const Divider(height: 20),
        const Text(
          'Próximas entregas',
          style: TextStyle(fontSize: 12, color: Colors.black54),
        ),
        const SizedBox(height: 4),
        for (final f in fechas)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '•  ${FechaRecepcion.formatear(f)}',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        if (ctrl.vistaPreviaLimitada && fechas.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'La siguiente se agenda cuando cargues esta entrega.',
              style: TextStyle(fontSize: 11, color: Colors.orange.shade900),
            ),
          ),
      ]),
      _tarjeta([
        Text(
          'Insumos (${ctrl.items.length})',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        for (final it in ctrl.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    (it['nombre'] ?? 'Insumo').toString(),
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                  ),
                ),
                Text(
                  '${ControladorPedidoRecurrente.formatearCantidad((it['cantidadPedida'] as num?) ?? 0)} '
                          '${it['unidad'] ?? ''}'
                      .trim(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        // HU-060: el total sólo para quien puede ver finanzas.
        if (puedeVerFinanzas) ...[
          const Divider(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Total estimado por entrega: '
              '\$${ctrl.totalEstimado.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ]),
      _tarjeta([
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            '¿Requiere pago en efectivo?',
            style: TextStyle(fontSize: 13, color: Colors.black87),
          ),
          value: ctrl.tieneEfectivo,
          onChanged: ctrl.cambiarTieneEfectivo,
          activeThumbColor: InsumaColors.primaryBlue,
        ),
        TextFormField(
          // Se copia a cada entrega, así que la nota conviene que sea
          // permanente ("dejar en la puerta de atrás"), no de una vez.
          initialValue: ctrl.nota,
          style: const TextStyle(fontSize: 13, color: Colors.black87),
          decoration: const InputDecoration(
            labelText: 'Nota para todas las entregas (opcional)',
          ),
          onChanged: ctrl.cambiarNota,
        ),
      ]),
      // Recordatorio del modelo, justo antes de confirmar: es la única
      // confirmación de toda la serie.
      _Aviso(
        icono: Icons.info_outline,
        texto: ctrl.esEdicion
            ? 'Al guardar, las próximas entregas usan esta configuración. Las '
                  'que ya estén en Recepciones no se tocan.'
            : 'Se confirma UNA sola vez. Desde ahora, cada entrega aparece '
                  'directamente en Recepciones, ya confirmada.',
      ),
    ]);
  }

  // --- Botonera --------------------------------------------------------------

  Widget _botonera(ControladorPedidoRecurrente ctrl) {
    final bloqueo = _motivoBloqueo(ctrl);
    final esUltimo = _paso == _totalPasos - 1;
    final habilitado = bloqueo == null && !ctrl.guardando;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: InsumaColors.cardBorderLight)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _anchoMaximo),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // El motivo, a la vista y pegado al botón que está apagado. Que
                // el selector de días muestre además su propio aviso es
                // deliberado: en un slide largo ese texto puede quedar fuera de
                // pantalla justo cuando el usuario mira por qué no avanza.
                if (bloqueo != null) ...[
                  Text(
                    bloqueo,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _paso == 0 || ctrl.guardando
                            ? null
                            : _retroceder,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.black54,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Atrás'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: !habilitado
                            ? null
                            : (esUltimo ? () => _confirmar(ctrl) : _avanzar),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: InsumaColors.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: ctrl.guardando
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                esUltimo
                                    ? (ctrl.esEdicion
                                          ? 'Guardar cambios'
                                          : 'Confirmar')
                                    : 'Siguiente',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Por qué no se puede avanzar, o `null` si se puede.
  ///
  /// Los motivos NO se redactan acá: el del paso 1 lo devuelve
  /// `AgendaRecurrente.validar` (el mismo texto que usaría el Service) y el del
  /// paso 2 es la condición del contrato del controlador.
  String? _motivoBloqueo(ControladorPedidoRecurrente ctrl) {
    switch (_paso) {
      case 0:
        return ctrl.errorPaso1;
      case 1:
        return ctrl.puedeAvanzarPaso2
            ? null
            : 'Elegí al menos un insumo con su cantidad.';
      default:
        return null;
    }
  }

  // --- Piezas compartidas ----------------------------------------------------

  /// Cuerpo de un slide: UN solo scroll, centrado y con tope de ancho.
  Widget _slideScrolleable(List<Widget> hijos) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _anchoMaximo),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: hijos,
          ),
        ),
      ),
    );
  }

  /// La tarjeta de la casa: blanca, sin sombra, radio 16 y borde suave. Es la
  /// misma de `TarjetaPedido`, para que la pantalla se vea parte de la app.
  Widget _tarjeta(List<Widget> hijos) {
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: InsumaColors.cardBorderLight),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: hijos,
        ),
      ),
    );
  }

  Widget _fila(IconData icono, String texto) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 14, color: Colors.grey[600]),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              texto,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

/// Una de las tres frecuencias. Chip ancho, con el mismo lenguaje visual que los
/// días de la semana (radio 10, azul lleno cuando está elegido).
class _OpcionTipo extends StatelessWidget {
  final TipoFrecuencia tipo;
  final bool elegido;
  final VoidCallback onTap;

  const _OpcionTipo({
    required this.tipo,
    required this.elegido,
    required this.onTap,
  });

  static String _etiqueta(TipoFrecuencia t) => switch (t) {
    TipoFrecuencia.semanal => 'Semanal',
    TipoFrecuencia.mensual => 'Mensual',
    TipoFrecuencia.cadaNDias => 'Cada X días',
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: elegido,
      button: true,
      child: InkWell(
        key: ValueKey('tipo_${AgendaRecurrente.codigoDeTipo(tipo)}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: elegido ? InsumaColors.primaryBlue : Colors.grey[100],
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            _etiqueta(tipo),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: elegido ? FontWeight.bold : FontWeight.normal,
              color: elegido ? Colors.white : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }
}

/// Uno de los dos anclajes de "cada X días". Es una opción con explicación, no
/// un radio pelado: la diferencia entre las dos sólo se entiende con el ejemplo.
class _OpcionAncla extends StatelessWidget {
  final String etiqueta;
  final String detalle;
  final bool elegido;
  final VoidCallback onTap;

  const _OpcionAncla({
    required this.etiqueta,
    required this.detalle,
    required this.elegido,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: elegido ? InsumaColors.avatarBg : Colors.grey[100],
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: elegido ? InsumaColors.primaryBlue : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              elegido ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: elegido ? InsumaColors.primaryBlue : Colors.black38,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    etiqueta,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: elegido ? FontWeight.bold : FontWeight.normal,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detalle,
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Franja informativa ámbar, del mismo tono que la del selector del día del mes.
class _Aviso extends StatelessWidget {
  final IconData icono;
  final String texto;

  const _Aviso({required this.icono, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: InsumaColors.alertYellow,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 16, color: Colors.orange.shade900),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ),
        ],
      ),
    );
  }
}
