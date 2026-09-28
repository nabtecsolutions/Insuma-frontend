import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../constants/mensajes_operacion.dart';
import '../../../constants/unidades.dart';
import '../../../database/database.dart';
import '../../../theme/insuma_colors.dart';
import '../../../controllers/controlador_recibir.dart';
import '../../../services/servicio_permisos.dart';
import '../../../utils/estados_pedido.dart';
import '../../../utils/fecha_recepcion.dart';
import '../../widgets/campo_fecha.dart';
import '../../widgets/campo_numerico.dart';
import 'selector_insumos_pedido.dart';

/// Modal que administra el alta y persistencia de borradores de Pedidos.
class FormularioPedidoModal extends StatefulWidget {
  final String negocioId;
  final Pedido? pedidoExistente;
  final String nombreOperario;

  const FormularioPedidoModal({
    super.key,
    required this.negocioId,
    this.pedidoExistente,
    required this.nombreOperario,
  });

  @override
  State<FormularioPedidoModal> createState() => _FormularioPedidoModalState();
}

class _FormularioPedidoModalState extends State<FormularioPedidoModal> {
  final _formKey = GlobalKey<FormState>();
  String? _error;

  /// #176: hay un guardado en vuelo lanzado DESDE ESTA pantalla.
  ///
  /// Es estado de pantalla —lo que apaga el botón— y no reemplaza a la guarda
  /// del controlador: apagar el botón agenda un redibujado para el frame
  /// SIGUIENTE, así que dos toques del mismo frame llegan los dos con el botón
  /// todavía habilitado. Son dos capas, no una.
  bool _guardando = false;

  /// #176: se está abriendo el selector de insumos. `showDialog` es síncrono:
  /// sin esto, dos toques del mismo frame apilan dos diálogos encimados.
  bool _abriendoSelector = false;

  /// La pantalla está trabajando y no acepta cambios.
  ///
  /// Mira TAMBIÉN el controlador y no sólo su propio flag: el State muere si la
  /// hoja se cierra (el botón atrás no lo frena el `AbsorbPointer`), y el
  /// controlador es uno solo para toda la sesión. Un modal reabierto con
  /// `_guardando` en false volvería a llamar al controlador y caería en
  /// "Error al registrar pedido." mientras el pedido se está guardando bien,
  /// que es justo lo que la decisión A prohíbe.
  bool get _ocupado => _guardando || _ctrl.guardandoPedido;

  ControladorRecibir get _ctrl =>
      Provider.of<ControladorRecibir>(context, listen: false);

  String? get _proveedorSeleccionadoId =>
      Provider.of<ControladorRecibir>(context).proveedorSeleccionadoId;
  String get _nota => Provider.of<ControladorRecibir>(context).notaPedido;
  set _nota(String v) => _ctrl.actualizarNota(v);

  bool get _tieneEfectivo =>
      Provider.of<ControladorRecibir>(context).tieneEfectivo;
  set _tieneEfectivo(bool v) => _ctrl.actualizarTieneEfectivo(v);

  /// HU-142: día pedido de recepción. Vive en el controlador (no en el State)
  /// para que sobreviva a los rebuilds del modal, igual que la nota.
  DateTime? get _fechaRecepcion =>
      Provider.of<ControladorRecibir>(context).fechaRecepcionSolicitada;
  set _fechaRecepcion(DateTime? v) =>
      _ctrl.actualizarFechaRecepcionSolicitada(v);

  List<Map<String, dynamic>> get _itemsPedido =>
      Provider.of<ControladorRecibir>(context).itemsPedido;
  bool get _cargandoProv => Provider.of<ControladorRecibir>(context).cargando;

  /// HU-060: el cocinero no debe ver costos/precios. Usa usuarioRol para respetar
  /// la elevación por PIN (HU-043): un cocinero elevado a admin sí los ve.
  bool get _puedeVerFinanzas =>
      Permisos.puede(_ctrl.sesion.usuarioRol, Permiso.verFinanzas);

  /// HU-141: se está corrigiendo un pedido ya ENVIADO (no confirmado): no se
  /// ofrece "Guardar Borrador" (no se degrada) y el CTA pasa a "Re-enviar".
  bool get _editaEnviado =>
      widget.pedidoExistente?.estado == EstadosPedido.enviado;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.pedidoExistente != null) {
        _ctrl.cargarBorradorEnFormulario(widget.pedidoExistente!);
      } else {
        _ctrl.limpiarFormulario();
      }
    });
  }

  void _seleccionarProveedor(String proveedorId) {
    _ctrl.cambiarProveedorSeleccionado(proveedorId);
  }

  /// Buscador de proveedores (HU-058): filtra en tiempo real por nombre y categoría
  /// sobre la lista activa ya cargada; muestra un estado vacío si no hay coincidencias.
  /// Al tocar un resultado, lo carga en el pedido y cierra.
  void _abrirBuscadorProveedor(FormFieldState<String> field) {
    String query = '';
    String categoria = 'Todos';
    final categorias = _ctrl.categoriasProveedores;
    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setModalState) {
            final resultados = _ctrl.buscarProveedores(
              query: query,
              categoria: categoria,
            );
            return AlertDialog(
              backgroundColor: Colors.white,
              title: const Text(
                'Buscar proveedor',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 380,
                child: Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: 'Buscar por nombre...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onChanged: (v) => setModalState(() => query = v),
                    ),
                    if (categorias.length > 1) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        // #215: sin esto el dropdown se mide por su ítem más ancho e
                        // ignora el ancho disponible: desborda en pantalla de teléfono.
                        isExpanded: true,
                        initialValue: categoria,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: 'Categoría',
                        ),
                        items: categorias
                            .map(
                              (c) => DropdownMenuItem(value: c, child: Text(c)),
                            )
                            .toList(),
                        onChanged: (v) =>
                            setModalState(() => categoria = v ?? 'Todos'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Expanded(
                      child: resultados.isEmpty
                          ? const Center(
                              child: Text(
                                'Sin proveedores que coincidan.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            )
                          : ListView.builder(
                              itemCount: resultados.length,
                              itemBuilder: (context, i) {
                                final p = resultados[i];
                                final seleccionado =
                                    p.id == _proveedorSeleccionadoId;
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    p.nombre,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  subtitle: (p.categoria ?? '').trim().isEmpty
                                      ? null
                                      : Text(
                                          p.categoria!,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                  trailing: seleccionado
                                      ? const Icon(
                                          Icons.check,
                                          color: Colors.green,
                                        )
                                      : null,
                                  onTap: () {
                                    _seleccionarProveedor(p.id);
                                    field.didChange(p.id);
                                    Navigator.pop(dialogContext);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cerrar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  double get _calcularTotalPedido {
    double total = 0.0;
    for (final it in _itemsPedido) {
      total +=
          ((it['cantidad'] ?? 0.0) as double) *
          ((it['costoUnitario'] ?? 0.0) as double);
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final esEdicion = widget.pedidoExistente != null;

    if (_cargandoProv) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        top: 16,
        left: 20,
        right: 20,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          // #176 (decisión D): mientras el pedido se guarda, el formulario
          // ENTERO deja de aceptar cambios. No es cosmético: la foto del pedido
          // se arma en el instante del toque, así que corregir la harina de 5 a
          // 6 kg mientras guarda perdía la corrección sin ningún aviso.
          //
          // `AbsorbPointer` y no `IgnorePointer`: el segundo deja que el toque
          // caiga a través, y en una hoja modal eso significa que aterriza en
          // la pantalla de atrás. Absorberlo lo come acá y no pasa nada.
          //
          // La opacidad es la señal de que la pantalla está TRABAJANDO y no
          // colgada; el aviso de más abajo lo dice con palabras. Nada de
          // ruedita: un `CircularProgressIndicator` nunca se queda quieto y
          // colgaría el `pumpAndSettle` de los widget tests de este modal.
          return AbsorbPointer(
            absorbing: _ocupado,
            // `AbsorbPointer` frena el DEDO, no el TECLADO: con la hoja
            // "bloqueada", dos Tab bastaban para meter el foco en el campo de
            // cantidad y teclear (probado en widget test). Y el tecleo no es
            // cosmético: `alCambiar` llama a `actualizarItemPedido`, que pisa
            // `_itemsPedido` EN EL LUGAR, así que la persona ve un pedido que
            // no es el que se está guardando —y si el guardado falla, se queda
            // con ese número fantasma sin haberlo confirmado—. El `unfocus()`
            // de `_guardarPedido` suelta el foco UNA vez; esto impide que
            // vuelva.
            //
            // (La FOTO que viaja al Service sí está a salvo: `_formulario()`
            // copia los ítems. Son dos agujeros distintos y hay que tapar los
            // dos —uno protege lo que se guarda, este protege lo que se ve—.)
            child: ExcludeFocus(
              excluding: _ocupado,
              child: Opacity(
                opacity: _ocupado ? 0.55 : 1.0,
                child: Form(
                  key: _formKey,
                  child: ListView(
                    controller: scrollController,
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
                        esEdicion ? 'Editar Pedido / Borrador' : 'Nuevo Pedido',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Selección de proveedor con buscador (HU-058)
                      FormField<String>(
                        initialValue: _proveedorSeleccionadoId,
                        // listen:false: el validator corre en un callback (validate()), no en build.
                        validator: (_) => _ctrl.proveedorSeleccionadoId == null
                            ? 'Seleccione un proveedor'
                            : null,
                        builder: (field) {
                          final nombre = Provider.of<ControladorRecibir>(
                            context,
                          ).proveedorSeleccionadoNombre;
                          return InkWell(
                            onTap: () => _abrirBuscadorProveedor(field),
                            borderRadius: BorderRadius.circular(4),
                            child: InputDecorator(
                              decoration: InputDecoration(
                                labelText: 'Proveedor *',
                                errorText: field.errorText,
                                suffixIcon: const Icon(Icons.search),
                              ),
                              child: Text(
                                nombre ?? 'Buscar proveedor…',
                                style: TextStyle(
                                  color: nombre == null
                                      ? Colors.grey
                                      : Colors.black87,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 12),

                      // Nota adicional
                      TextFormField(
                        initialValue: _nota,
                        decoration: const InputDecoration(
                          labelText: 'Nota o comentario adicional',
                        ),
                        style: const TextStyle(color: Colors.black87),
                        onSaved: (v) => _nota = v ?? '',
                      ),
                      const SizedBox(height: 12),

                      // HU-142: fecha de recepción deseada. OPCIONAL (decisión del PO):
                      // se puede dejar vacía y se puede volver a vaciar con la X.
                      CampoFecha(
                        etiqueta: '¿Para cuándo lo necesitás?',
                        textoVacio: 'Sin fecha (opcional)',
                        valor: _fechaRecepcion,
                        primeraFecha: FechaRecepcion.minima(),
                        ultimaFecha: FechaRecepcion.maxima(),
                        onCambiar: (f) => _fechaRecepcion = f,
                      ),
                      const SizedBox(height: 12),

                      // Interruptor de efectivo
                      SwitchListTile(
                        title: const Text(
                          '¿Requiere pago en efectivo?',
                          style: TextStyle(fontSize: 13, color: Colors.black87),
                        ),
                        value: _tieneEfectivo,
                        onChanged: (v) => setState(() => _tieneEfectivo = v),
                        activeThumbColor: InsumaColors.primaryBlue,
                      ),

                      const Divider(height: 24),

                      // Cabecera items
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Items del Pedido',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.black54,
                            ),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text(
                              'Agregar Item manual',
                              style: TextStyle(fontSize: 11),
                            ),
                            // #176: dos toques abrían dos selectores encimados.
                            // Mira `_ocupado` también: un selector abierto en
                            // medio del guardado toca `itemsPedido`, que es la
                            // MISMA lista que el Service está por leer.
                            onPressed: (_ocupado || _abriendoSelector)
                                ? null
                                : _abrirSelectorInsumos,
                          ),
                        ],
                      ),

                      if (_itemsPedido.isEmpty)
                        Container(
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: InsumaColors.cardBorderLight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: Text(
                              'Seleccione un proveedor o agregue ítems.',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _itemsPedido.length,
                          itemBuilder: (context, idx) {
                            final item = _itemsPedido[idx];
                            final cant = (item['cantidad'] ?? 0.0) as double;
                            final precio =
                                (item['costoUnitario'] ?? 0.0) as double;
                            return Card(
                              elevation: 0,
                              color: Colors.grey[50],
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      item['nombre'] as String,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(
                                          // Key ESTABLE por ítem (HU-074): si incluye el valor, cada
                                          // tecla recrea el campo y pierde el foco tras un dígito.
                                          // HU-137: el campo ya no acepta letras; vaciarlo vale 0,
                                          // que es un ítem sin pedir (lo valida ValidadorPedido).
                                          child: CampoNumerico(
                                            key: ValueKey(
                                              'cant_${item['insumoId']}',
                                            ),
                                            etiqueta:
                                                'Cant (${item['unidad']})',
                                            valorInicial: cant,
                                            decimales: decimalesDeCantidad(
                                              item['unidad'] as String?,
                                              cant,
                                            ),
                                            paso: 1,
                                            obligatorio: false,
                                            permitirCero: true,
                                            denso: true,
                                            estilo: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.black87,
                                            ),
                                            alCambiar: (v) =>
                                                _ctrl.actualizarItemPedido(
                                                  idx,
                                                  cantidad: v ?? 0.0,
                                                ),
                                          ),
                                        ),
                                        if (_puedeVerFinanzas) ...[
                                          const SizedBox(width: 8),
                                          Expanded(
                                            // #213: el precio se MUESTRA, no se
                                            // tipea. Lo resuelve la cascada de
                                            // HU-138 —pactado con este proveedor,
                                            // último pagado a él, último pagado a
                                            // cualquiera, costo del insumo— y
                                            // dejar que se pise a mano competía
                                            // con esa única autoridad.
                                            //
                                            // Cuando no hay ningún precio
                                            // conocido dice "Sin precio" y no
                                            // "$0.00": un cero se lee como un
                                            // dato cargado, y acá significa que
                                            // no se sabe. El renglón entra en 0 y
                                            // el precio real se carga al recibir.
                                            child: Text(
                                              precio > 0
                                                  ? 'Precio est. \$${precio.toStringAsFixed(2)}'
                                                  : 'Sin precio: se carga al recibir',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: precio > 0
                                                    ? Colors.black87
                                                    : Colors.grey,
                                                fontStyle: precio > 0
                                                    ? FontStyle.normal
                                                    : FontStyle.italic,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            color: Colors.redAccent,
                                            size: 20,
                                          ),
                                          onPressed: () {
                                            _ctrl.removerItemPedido(idx);
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),

                      const Divider(height: 24),
                      if (_puedeVerFinanzas)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Total Estimado: \$${_calcularTotalPedido.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                          ],
                        ),

                      // #176 (decisión A): mientras guarda, la pantalla DICE que está
                      // guardando. En azul y no en rojo a propósito: no es un error
                      // —el pedido se está guardando bien—, así que el segundo toque
                      // encuentra este mismo texto ya en pantalla en vez del
                      // engañoso "Error al registrar pedido.".
                      if (_ocupado) ...[
                        const SizedBox(height: 12),
                        const Text(
                          MensajesOperacion.guardadoEnCurso,
                          style: TextStyle(
                            color: InsumaColors.primaryBlue,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],

                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],

                      const SizedBox(height: 24),
                      Row(
                        children: [
                          // HU-141: un pedido ya ENVIADO no se degrada a borrador;
                          // sólo se corrige y re-envía.
                          if (!_editaEnviado) ...[
                            Expanded(
                              child: OutlinedButton(
                                // #176: apagado mientras guarda (decisión B).
                                onPressed: _ocupado
                                    ? null
                                    : () => _guardarPedido(esBorrador: true),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: Text(
                                  _ocupado ? 'Guardando…' : 'Guardar Borrador',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _ocupado
                                  ? null
                                  : () => _guardarPedido(esBorrador: false),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                _ocupado
                                    ? 'Guardando…'
                                    : (_editaEnviado
                                          ? 'Re-enviar Pedido'
                                          : 'Confirmar Pedido'),
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
        },
      ),
    );
  }

  /// Modal secundario para agregar un insumo libremente al listado de la orden.
  ///
  /// #176: `showDialog` es síncrono, así que el segundo toque del mismo frame
  /// apilaba un segundo selector encima del primero. El flag se prende ANTES
  /// del `await` y se suelta recién cuando el diálogo se cierra.
  Future<void> _abrirSelectorInsumos() async {
    // `_ocupado` y no sólo `_abriendoSelector`: si en el MISMO frame entran el
    // toque de "Confirmar Pedido" y el de "Agregar Item manual", el segundo ya
    // pasó su propio chequeo con el flag en false y abriría el selector sobre
    // un formulario que quedó congelado a mitad de guardado.
    if (_ocupado || _abriendoSelector) return;
    setState(() => _abriendoSelector = true);
    try {
      await SelectorInsumosPedido.mostrar(context);
    } finally {
      // `mounted` porque el modal puede haberse cerrado con el selector abierto:
      // un setState sobre una ruta ya desmontada es una excepción en los tests.
      if (mounted) setState(() => _abriendoSelector = false);
    }
  }

  /// Guarda el pedido/borrador delegando al controlador.
  Future<void> _guardarPedido({required bool esBorrador}) async {
    // #176: segundo toque con el guardado en vuelo. El botón ya está apagado,
    // pero el redibujado que lo apaga llega recién en el frame siguiente: los
    // toques de ESTE frame entran igual. No hace falta setear ningún mensaje
    // acá —el aviso azul ya está en pantalla desde que arrancó el guardado—;
    // lo que importa es NO seguir, para no crear un segundo pedido ni pisar el
    // aviso con "Error al registrar pedido.".
    if (_ocupado) return;

    // Decisión D: se saca el foco antes de nada. El `AbsorbPointer` frena los
    // toques pero NO el tecleo en un campo que YA tenía el foco, así que sin
    // esto se puede seguir escribiendo sobre una pantalla que ya se ve apagada.
    // De paso baja el teclado, que en el celular es la señal más clara de que
    // la pantalla se puso a trabajar.
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    final errorItems = _ctrl.validarItemsPedido();
    if (errorItems != null) {
      setState(() => _error = errorItems);
      return;
    }

    // Recién acá se prende: antes de este punto no hay nada en vuelo, y apagar
    // el formulario por una validación que falló lo dejaría muerto.
    setState(() {
      _guardando = true;
      _error = null;
    });

    try {
      if (esBorrador) {
        final ok = await _ctrl.guardarBorrador();
        if (ok) {
          // HU-096: sin recarga manual. El listado de pedidos (HU-089) y el selector de
          // proveedores (HU-096) son reactivos: la UI se actualiza sola tras la mutación.
          if (mounted) Navigator.pop(context);
        } else {
          // `mounted` igual que arriba: la hoja se puede cerrar tocando afuera
          // con el guardado en vuelo (el AbsorbPointer no cubre la barrera),
          // y un setState sobre un State ya muerto es una excepción.
          if (mounted) setState(() => _error = 'Error al registrar pedido.');
        }
      } else {
        // HU-063: al confirmar, el pedido pasa a "en espera" y se devuelve para que
        // el tab abra la pantalla de Resumen y ofrezca el envío por WhatsApp.
        final pedido = await _ctrl.enviarPedido();
        if (pedido != null) {
          if (mounted) Navigator.pop(context, pedido);
        } else {
          if (mounted) setState(() => _error = 'Error al registrar pedido.');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Error al registrar pedido: $e');
    } finally {
      // `mounted`: el camino feliz hace `Navigator.pop` justo arriba, así que
      // este `finally` corre sobre una ruta que ya se está desarmando.
      if (mounted) setState(() => _guardando = false);
    }
  }
}
