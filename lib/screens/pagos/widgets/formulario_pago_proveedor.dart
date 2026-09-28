import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/fila_dato_copiable.dart';
import '../../../utils/enlaces_externos.dart';
import '../../../controllers/controlador_adjuntos.dart';
import '../../../controllers/controlador_pagos.dart';
import '../../../database/database.dart';
import '../../../services/servicio_adjuntos.dart';
import '../../../services/servicio_pagos.dart';
import '../../../services/servicio_permisos.dart';
import '../../../services/servicio_sesion.dart';
import '../../../theme/insuma_colors.dart';
import '../../../utils/adjuntos/selector_archivos_file_picker.dart';
import '../../../utils/formatos_entrada.dart';
import '../../../utils/sanitizador_texto.dart';
import '../../recibir/widgets/selector_remito_widget.dart';
import '../../widgets/campo_fecha.dart';
import '../../widgets/campo_numerico.dart';
import 'visor_remito.dart';

/// Formulario para registrar un pago a un proveedor (HU-024).
///
/// **Vive fuera de `pagos_screen.dart` a propósito, y ése es todo el punto.**
/// Lo montan DOS pantallas: el módulo de Pagos y la ficha del proveedor
/// (HU-009). El PO lo pidió así con todas las letras: *"esta acción de pagar la
/// factura pendiente debe reutilizar la forma de pagos que se usa en el módulo
/// de pagos, ya que este módulo va a ser modificado y cuando lo hagamos, no
/// quiero tener que volver a tocar esta funcionalidad de nuevo, sino que escale
/// con lo nuevo"*.
///
/// Concretamente: **HU-149** ("detalle del pago y total a pagar en el momento de
/// pagar") reescribe justo el bloque de imputación y los avisos de
/// sobrante/faltante que están acá adentro. El día que mergee, la ficha del
/// proveedor hereda el rediseño sin que nadie abra su archivo.
///
/// Toda la lógica de negocio sigue en [ControladorPagos] y en `ServicioPagos`:
/// este widget arma la pantalla y delega.
class FormularioPagoProveedor extends StatefulWidget {
  final String proveedorId;
  final String proveedorNombre;

  /// Facturas que arrancan tildadas. Es la ÚNICA pieza de API que el formulario
  /// no tenía: con ella, "pagar esta recepción" desde la ficha llega con su
  /// factura ya marcada y el monto autocompletado, que es lo que pidió el PO
  /// ("interactuando con esa recepción, eligiendo monto").
  ///
  /// Vacío = comportamiento histórico del módulo de Pagos: nada tildado.
  final Set<String> facturasPreseleccionadas;

  /// Se llama después de un pago exitoso, antes de cerrar. Cada pantalla lo usa
  /// para refrescar lo suyo.
  final VoidCallback? alRegistrar;

  /// #238: los archivos staged del comprobante de la transferencia. Lo arma y
  /// descarta `abrirFormularioPagoProveedor` (precedente: `_adjuntarFactura`);
  /// el adjunto queda ligado AL PAGO dentro de su misma transacción.
  final ControladorAdjuntos comprobantes;

  const FormularioPagoProveedor({
    super.key,
    required this.proveedorId,
    required this.proveedorNombre,
    required this.comprobantes,
    this.facturasPreseleccionadas = const {},
    this.alRegistrar,
  });

  @override
  State<FormularioPagoProveedor> createState() =>
      _FormularioPagoProveedorState();
}

class _FormularioPagoProveedorState extends State<FormularioPagoProveedor> {
  /// HU-123: el campo se AUTOCOMPLETA con el total de lo seleccionado, así que
  /// necesita un controller para poder reescribirlo. Sumar los saldos a mano era
  /// el paso donde el usuario se equivocaba.
  final _ctrlMonto = TextEditingController();

  late final List<Factura> _pendientes;
  late final Map<String, bool> _seleccion;

  /// HU-137: `null` = todavía no hay un monto válido escrito. Antes el `?? 0.0`
  /// dejaba pasar un pago de $0 sin decir nada.
  double? _monto;
  String _metodo = 'efectivo';
  String _referencia = '';
  DateTime _fecha = DateTime.now();
  String? _error;
  bool _guardando = false;

  ControladorPagos get _ctrl => context.read<ControladorPagos>();

  @override
  void initState() {
    super.initState();
    final ctrl = context.read<ControladorPagos>();
    _pendientes = ctrl.facturasPendientesDe(widget.proveedorId);
    _seleccion = {
      for (final f in _pendientes)
        f.id: widget.facturasPreseleccionadas.contains(f.id),
    };
    // Con facturas preseleccionadas, el monto arranca autocompletado igual que
    // si el usuario las hubiera tildado a mano.
    _autocompletarMonto();
  }

  @override
  void dispose() {
    _ctrlMonto.dispose();
    super.dispose();
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  String _fechaCorta(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// Los importes de una factura, en una línea (HU-149).
  ///
  /// "Pagado" aparece SÓLO cuando hubo un pago parcial: en el caso normal
  /// —factura entera pendiente— sería un "$0.00" que no aporta y que le come
  /// lugar a los dos números que sí importan.
  String _lineaImportes(Factura f) {
    final saldo = _ctrl.saldoFactura(f);
    final pagado = f.totalBruto - saldo;
    final partes = [
      'Total ${_money(f.totalBruto)}',
      if (pagado > 0.001) 'Pagado ${_money(pagado)}',
      'Saldo ${_money(saldo)}',
    ];
    return partes.join(' · ');
  }

  /// ¿La factura ya venció? (HU-149). Se compara por DÍA y no por instante: una
  /// factura que vence hoy no está vencida hasta que el día termine, y con
  /// `isBefore(DateTime.now())` lo estaría desde la primera hora de la mañana.
  bool _estaVencida(Factura f) {
    final hoy = DateTime.now();
    final vence = f.fechaVencimiento;
    return DateTime(
      vence.year,
      vence.month,
      vence.day,
    ).isBefore(DateTime(hoy.year, hoy.month, hoy.day));
  }

  static String _capitalizar(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  /// Las facturas tildadas (HU-149): se deriva de `_seleccion` en cada build,
  /// sin lista propia que mantener sincronizada.
  List<Factura> get _seleccionadas =>
      _pendientes.where((f) => _seleccion[f.id] == true).toList();

  double get _saldoSeleccionado =>
      _seleccionadas.fold<double>(0.0, (s, f) => s + _ctrl.saldoFactura(f));

  /// HU-123: el monto SIGUE a la selección. Se recalcula en cada marcado
  /// —también si el usuario ya había tipeado— porque el número que quiere es el
  /// de lo que acaba de elegir; y queda editable para pagos parciales.
  ///
  /// Sin NADA marcado no se toca el campo: un pago sin facturas imputadas es un
  /// anticipo a favor, un flujo válido de HU-124, y vaciarlo le borraría al
  /// usuario el importe que había tipeado.
  void _autocompletarMonto() {
    final total = _saldoSeleccionado;
    if (total <= 0) return;
    _ctrlMonto.text = CampoNumerico.textoDe(
      double.parse(total.toStringAsFixed(2)),
    );
    // Escribir en el controller NO dispara `onChanged`: el estado se actualiza
    // acá a mano.
    _monto = total;
  }

  @override
  Widget build(BuildContext context) {
    // Guarda PROPIA de finanzas. En el módulo de Pagos la protección está en el
    // árbol de la pantalla, pero la ficha del proveedor vive en la pestaña de
    // Proveedores, que NO la tiene: sin esto, montar el formulario desde ahí le
    // daría a un cocinero un formulario de pago funcional.
    final rol = context.read<ServicioSesion>().usuarioRol;
    if (!Permisos.puede(rol, Permiso.verFinanzas)) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No tenés permiso para registrar pagos.',
          style: TextStyle(fontSize: 13, color: Colors.black54),
        ),
      );
    }

    final montoIngresado = _monto;
    // Un monto vacío o inválido cuenta como 0 SOLO para el indicador de
    // sobrante/faltante de HU-124 (misma lectura visual que antes); para
    // registrar el pago, en cambio, se exige un monto válido.
    final excedente = (montoIngresado ?? 0.0) - _saldoSeleccionado;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        top: 16,
        left: 20,
        right: 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Registrar pago — ${widget.proveedorNombre}',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            Text(
              'Saldo actual: ${_money(_ctrl.saldo(widget.proveedorId))}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            // #220: los datos para transferir, acá y no en otra pantalla. Es el
            // momento exacto en que hacen falta —el admin está por pagar— y
            // antes había que salir de la app a buscarlos.
            //
            // Si el proveedor no los tiene cargados, las filas salen en gris
            // deshabilitadas. No es un pendiente disimulado: es el estado que
            // corresponde a un dato que falta, y deja dicho que a ese proveedor
            // hay que cargárselo.
            _BloqueCobro(proveedorId: widget.proveedorId),
            const SizedBox(height: 12),
            CampoNumerico(
              etiqueta: 'Monto (\$)',
              controlador: _ctrlMonto,
              alCambiar: (v) => setState(() => _monto = v),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // #215: sin esto el dropdown se mide por su ítem más ancho e
              // ignora el ancho disponible: desborda en pantalla de teléfono.
              isExpanded: true,
              initialValue: _metodo,
              decoration: const InputDecoration(labelText: 'Método *'),
              items: ControladorPagos.metodosPago
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(_capitalizar(m)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _metodo = v ?? 'efectivo'),
            ),
            const SizedBox(height: 8),
            // Se reusa el campo compartido de HU-142 en vez del selector privado
            // que tenía `pagos_screen`: es la adopción que quedó anotada cuando
            // se creó, y borra una duplicación en vez de mudarla.
            CampoFecha(
              etiqueta: 'Fecha de pago',
              valor: _fecha,
              primeraFecha: DateTime(2020),
              ultimaFecha: DateTime(2100),
              permiteBorrar: false,
              onCambiar: (d) {
                if (d != null) setState(() => _fecha = d);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              inputFormatters: FormatosEntrada.alfanumerico(),
              decoration: const InputDecoration(
                labelText: 'Referencia externa (opcional, evita duplicados)',
              ),
              style: const TextStyle(color: Colors.black),
              onChanged: (v) => _referencia = v,
            ),
            const SizedBox(height: 12),
            // #238: el comprobante de la transferencia, DONDE el pago ocurre.
            // Queda ligado AL PAGO — no a una recepción: un pago puede imputar
            // varias facturas o ser un anticipo sin factura. Se ve después en
            // la cuenta corriente, junto al movimiento del pago.
            SelectorRemitoWidget(
              controlador: widget.comprobantes,
              titulo: 'Comprobante de la transferencia (opcional)',
              textoVacio: 'Sin comprobante adjunto.',
            ),
            const SizedBox(height: 12),
            if (_pendientes.isNotEmpty) ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Imputar a facturas',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
              ..._pendientes.map(
                (f) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _seleccion[f.id] ?? false,
                  onChanged: (v) => setState(() {
                    _seleccion[f.id] = v ?? false;
                    _autocompletarMonto();
                  }),
                  // HU-149: el detalle de lo que se está por pagar. Los cinco
                  // datos salen de lo que ya está en memoria —no hay una sola
                  // consulta nueva— y son los que el admin necesita para no
                  // pagar de más ni de menos: cuándo vence, cuánto era el total
                  // y cuánto queda.
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Factura ${f.numeroFactura}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                      if (_estaVencida(f))
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'VENCIDA',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.redAccent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Emitida ${_fechaCorta(f.fechaFactura)} · '
                        'Vence ${_fechaCorta(f.fechaVencimiento)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      Text(
                        _lineaImportes(f),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  isThreeLine: true,
                  // HU-148: cotejar el importe contra el papel SIN salir del
                  // formulario. Abrir el visor pushea una ruta ENCIMA de este
                  // bottom sheet, así que el formulario sigue vivo debajo y al
                  // volver está todo como estaba.
                  secondary: _accesoDocumento(f),
                ),
              ),
              // HU-149: el TOTAL de lo tildado. Es un ESTADO ("esto es lo que
              // debés") y no una diferencia: el aviso de HU-124, más abajo, es
              // la resta contra el monto. Nunca se imprime el mismo importe dos
              // veces con dos rótulos — por eso este bloque no repite el monto
              // ingresado ni el excedente.
              //
              // Se calcula en cada build desde `_saldoSeleccionado`, sin estado
              // propio: guardarlo en una variable con memoria es exactamente el
              // bug que HU-124 vino a arreglar (#100), donde el aviso no
              // reaparecía al volver a tildar.
              if (_seleccionadas.isNotEmpty) ...[
                const Divider(height: 16),
                // Wrap y no Row: a 360 dp "2 facturas seleccionadas" y
                // "TOTAL A PAGAR $384350.00" no entran en la misma línea —
                // medido, desbordaba 246 px— y un Row no tiene a dónde achicar
                // sus hijos. Misma lección que #204 en la tarjeta de Pagos.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    Text(
                      _seleccionadas.length == 1
                          ? '1 factura seleccionada'
                          : '${_seleccionadas.length} facturas seleccionadas',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    Text(
                      'TOTAL A PAGAR ${_money(_saldoSeleccionado)}',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ],
              if (excedente > 0.001)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'El excedente de ${_money(excedente)} se registrará como anticipo a favor.',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              // HU-124: rama hermana del excedente — el FALTANTE para saldar lo
              // seleccionado. Aparece/desaparece/REAPARECE con cada cambio de
              // monto o de tildes. En |excedente| <= 0.001 no se muestra nada.
              if (excedente < -0.001)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Falta ${_money(-excedente)} para saldar las facturas seleccionadas.',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ] else
              const Text(
                'Sin facturas pendientes: el pago quedará como anticipo a favor.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: Colors.red,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: InsumaColors.primaryBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _guardando ? null : _registrar,
              child: _guardando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Registrar pago',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accesoDocumento(Factura f) {
    final recepcionId = f.recepcionId;
    return Tooltip(
      message: recepcionId == null
          ? 'Esta factura no tiene una recepción asociada, así que no hay '
                'documento que mostrar'
          : 'Ver la factura y el remito de esta recepción',
      child: IconButton(
        icon: const Icon(Icons.description_outlined, size: 20),
        onPressed: recepcionId == null
            ? null
            : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PantallaVisorRemito.deDocumentos(
                    // #209: el tooltip de arriba promete "la factura y el
                    // remito" desde HU-148, pero esto abría `.deFactura` y
                    // mostraba sólo facturas. La variante que cumple las dos
                    // cosas recién existe ahora.
                    documentosDeRecepcionId: recepcionId,
                    titulo: 'Documentos · Factura ${f.numeroFactura}',
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _registrar() async {
    final montoIngresado = _monto;
    // HU-137: sin monto válido no se registra el pago.
    if (montoIngresado == null || montoIngresado <= 0) {
      setState(() => _error = 'Ingresá un monto válido, mayor a 0.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    final imputaciones = _pendientes
        .where((f) => _seleccion[f.id] == true)
        .map((f) => SolicitudImputacion(f.id, _ctrl.saldoFactura(f)))
        .toList();
    final res = await _ctrl.registrarPago(
      proveedorId: widget.proveedorId,
      monto: montoIngresado,
      metodo: _metodo,
      fecha: _fecha,
      referenciaExterna: SanitizadorTexto.limpiar(_referencia),
      // La nota del pago va SIEMPRE en null: el formulario nunca tuvo un campo
      // para escribirla. Antes había una variable `nota` que se declaraba, se
      // leía y jamás se escribía — se borró por muerta, sin cambiar el
      // resultado.
      nota: null,
      imputaciones: imputaciones,
      comprobantes: widget.comprobantes,
    );
    if (!mounted) return;
    if (!res.ok) {
      setState(() {
        _guardando = false;
        _error = res.error;
      });
      return;
    }
    widget.alRegistrar?.call();
    Navigator.pop(context);
  }
}

/// Abre el formulario de pago en una hoja, desde CUALQUIER pantalla.
///
/// Es el único punto de contacto: quien quiera ofrecer "pagar" llama a esto y no
/// dibuja nada propio. Se encarga de las tres cosas que se olvidan al montar el
/// formulario fuera del módulo de Pagos:
///  1. **puentear los providers** con `.value`, porque una hoja modal se inserta
///     a la altura del Navigator y NO hereda el árbol de la pantalla que la abre;
///  2. **`asegurarCargado()`**, porque `cargar()` sólo se llamaba desde el
///     `initState` de la pantalla de Pagos: sin esto, abrirlo desde otro lado
///     mostraría "sin facturas pendientes" y saldo $0 EN SILENCIO;
///  3. el aviso de "Pago registrado", que antes vivía dentro del modal.
Future<void> abrirFormularioPagoProveedor(
  BuildContext context, {
  required String proveedorId,
  required String proveedorNombre,
  Set<String> facturasPreseleccionadas = const {},
  VoidCallback? alRegistrar,
}) async {
  final ctrlPagos = context.read<ControladorPagos>();
  final sesion = context.read<ServicioSesion>();
  // #238: el controlador del comprobante lo arma este punto de entrada
  // (precedente: `_adjuntarFactura` de pagos_screen) y lo descarta al cerrar
  // la hoja — su staging no debe sobrevivir entre pagos.
  final comprobantes = ControladorAdjuntos(
    const SelectorArchivosFilePicker(),
    context.read<ServicioAdjuntos>(),
  );
  await ctrlPagos.asegurarCargado();
  if (!context.mounted) {
    comprobantes.dispose();
    return;
  }

  final messenger = ScaffoldMessenger.of(context);
  var registro = false;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider<ControladorPagos>.value(value: ctrlPagos),
        ChangeNotifierProvider<ServicioSesion>.value(value: sesion),
      ],
      child: FormularioPagoProveedor(
        proveedorId: proveedorId,
        proveedorNombre: proveedorNombre,
        comprobantes: comprobantes,
        facturasPreseleccionadas: facturasPreseleccionadas,
        alRegistrar: () {
          registro = true;
          alRegistrar?.call();
        },
      ),
    ),
  );
  comprobantes.dispose();

  if (registro) {
    messenger.showSnackBar(const SnackBar(content: Text('Pago registrado.')));
  }
}

/// Los datos con los que se le transfiere al proveedor (#220).
///
/// Widget aparte y no líneas sueltas en el formulario: el formulario ya tiene
/// más de 400 líneas, y esto es un bloque con identidad propia que además va a
/// crecer cuando existan las columnas.
class _BloqueCobro extends StatelessWidget {
  const _BloqueCobro({required this.proveedorId});

  final String proveedorId;

  @override
  Widget build(BuildContext context) {
    // `watch` y no `read`: si el admin edita el alias en otra pantalla y vuelve,
    // esto tiene que mostrar el valor nuevo y no el de cuando se abrió.
    final proveedor = context.watch<ControladorPagos>().proveedorPorId(
      proveedorId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PARA TRANSFERIR',
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey[400],
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
        // Null cuando el proveedor no tiene el dato cargado, y también cuando no
        // está en la lista (inactivo). Los dos casos son "no hay con qué
        // transferirle", y la fila lo dice en gris en vez de esconderse.
        FilaDatoCopiable(
          icono: Icons.alternate_email,
          etiqueta: 'Alias',
          valor: proveedor?.aliasBancario,
        ),
        FilaDatoCopiable(
          icono: Icons.account_balance_outlined,
          etiqueta: 'CVU / CBU',
          valor: proveedor?.cbu,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _abrirMercadoPago(context),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Abrir Mercado Pago'),
          ),
        ),
      ],
    );
  }

  Future<void> _abrirMercadoPago(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await EnlacesExternos.abrirMercadoPago()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir Mercado Pago.')),
      );
    }
  }
}
