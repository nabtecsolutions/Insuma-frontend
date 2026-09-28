import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../utils/enlaces_externos.dart';
import '../widgets/fila_dato_copiable.dart';
import '../../controllers/controlador_proveedor_categorias.dart';
import '../../controllers/controlador_proveedores.dart';
import '../../database/database.dart';
import '../../services/servicio_pagos.dart';
import '../../theme/insuma_colors.dart';
import '../../utils/validador_datos.dart';
import '../recibir/acciones_pedido_mixin.dart';
import '../recurrentes/pedidos_recurrentes_screen.dart';
import 'widgets/historial_proveedor.dart';
import 'widgets/panel_financiero_proveedor.dart';
import '../pagos/widgets/formulario_pago_proveedor.dart';

/// Lo que la ficha le devuelve a la pantalla que la abrió.
///
/// El formulario de alta/edición de proveedor vive en `proveedores_tab.dart`
/// (es privado de esa pantalla), así que la ficha NO lo abre: hace lo mismo que
/// hacía el modal —cerrarse y delegar— sólo que ahora lo pide con un resultado
/// tipado en vez de llamar al método a mano. Duplicar acá esas ~230 líneas de
/// formulario sería la peor forma de resolverlo (DRY).
enum AccionFichaProveedor { editar }

/// Ficha completa del proveedor (HU-009).
///
/// Reemplaza al bottom sheet que había en `proveedores_tab.dart`: un solo lugar
/// por proveedor, con TODO lo que antes estaba repartido —datos de contacto,
/// editar/desactivar, insumos que suministra, pedidos recurrentes, alta de
/// insumo— más lo que la HU suma: el panel financiero y el historial de pedidos.
///
/// Es una VISTA: no calcula plata ni decide qué está vencido. El resumen
/// financiero se lo pide entero a [ServicioPagos] y el filtrado del historial
/// vive en el widget de historial, sobre las funciones puras de HU-151.
class FichaProveedorScreen extends StatefulWidget {
  const FichaProveedorScreen({super.key, required this.proveedor});

  final Proveedore proveedor;

  @override
  State<FichaProveedorScreen> createState() => _FichaProveedorScreenState();
}

/// `AccionesPedidoMixin` aporta `verDetallePedido` —el detalle con las
/// recepciones y su comentario (HU-146)— y `puedeVerFinanzas` (HU-060), que
/// respeta la elevación por PIN. Es exactamente lo que hace
/// `historial_pedidos_screen.dart`: la ficha no reimplementa ninguna de las dos.
class _FichaProveedorScreenState extends State<FichaProveedorScreen>
    with AccionesPedidoMixin {
  Proveedore get _proveedor => widget.proveedor;

  /// Resumen financiero YA PEDIDO. Se guarda el Future y no el resultado para
  /// poder mostrar el estado "cargando" sin un flag aparte.
  Future<ResumenFinancieroProveedor>? _resumen;

  @override
  void initState() {
    super.initState();
    // La carga de pedidos la dispara `HistorialProveedor`, no esta pantalla.
    // Estaba en los DOS y se pagaba dos veces `cargarSesion` (usuario +
    // proveedores + pedidos) y dos re-suscripciones al stream por cada apertura
    // de la ficha. Se dejó la del widget porque lo mantiene autónomo: es la
    // misma razón por la que recibe `alAbrirDetalle` en vez del mixin.
    //
    // #262: las categorías que suministra este proveedor se cargan una vez, tras
    // el primer frame (leer el Provider en initState no puede escuchar todavía).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ControladorProveedorCategorias>().cargar(_proveedor.id);
    });
  }

  /// Pide el resumen UNA sola vez y lo memoriza.
  ///
  /// Se llama desde `build`, pero la consulta NO se repite: de eso se encarga el
  /// `??=`. Cada repintado reusa el mismo Future en vez de volver a disparar las
  /// tres consultas que hace el servicio. Pedirlo acá y no en `initState`
  /// además evita evaluar el permiso de finanzas antes que la sesión.
  Future<ResumenFinancieroProveedor> _pedirResumen() => _resumen ??= context
      .read<ServicioPagos>()
      .resumenFinancieroProveedor(_proveedor.id);

  /// #264: registrar un pago desde la ficha. Reusa el mismo formulario que el
  /// módulo de Pagos (`abrirFormularioPagoProveedor`): no hay lógica de pago
  /// nueva. Al registrarse, tira el resumen guardado para que el `??=` de
  /// [_pedirResumen] lo vuelva a pedir y el panel financiero refleje el pago.
  void _abrirPagoProveedor() {
    abrirFormularioPagoProveedor(
      context,
      proveedorId: _proveedor.id,
      proveedorNombre: _proveedor.nombre,
      alRegistrar: () => setState(() => _resumen = null),
    );
  }

  @override
  Widget build(BuildContext context) {
    // `select` y no `watch`: lo único que la ficha necesita del controlador de
    // proveedores es el rol, y así no se repinta entera con cada recarga de la
    // lista de proveedores.
    final esAdmin = context.select<ControladorProveedores, bool>(
      (c) => c.usuarioRol == 'admin',
    );

    return Scaffold(
      backgroundColor: InsumaColors.backgroundLight,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: Colors.black87,
        title: Text(
          _proveedor.nombre,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        // #264: registrar un pago desde la ficha (arriba a la derecha). Gateado
        // por finanzas (respeta la elevación por PIN, HU-060), junto a las
        // acciones de admin. Reusa el mismo formulario que el módulo de Pagos.
        actions: [
          if (puedeVerFinanzas)
            IconButton(
              icon: const Icon(Icons.payments_outlined),
              tooltip: 'Registrar pago',
              onPressed: _abrirPagoProveedor,
            ),
          ...(esAdmin ? _accionesAdmin() : const <Widget>[]),
        ],
      ),
      // Tope de ancho para que en escritorio la ficha no se estire a lo largo de
      // toda la ventana; en 360px el ConstrainedBox no hace nada.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          // UN SOLO scroll en toda la pantalla: los widgets de adentro
          // (editor de vínculos, historial) NO scrollean por su cuenta, así la
          // rueda del mouse mueve una sola cosa en la web.
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            children: [
              if (!_proveedor.activo) _avisoDesactivado(),
              _tarjetaInformacion(),
              // Decisión del PO: el panel financiero va SIEMPRE VISIBLE, fuera
              // del desplegable. Es el dato por el que se entra a la ficha; si
              // hay algo vencido, esconderlo detrás de un toque anula la señal.
              //
              // HU-060: al que no ve finanzas no se le pide el resumen siquiera.
              // Ocultar el panel pero disparar igual las consultas sería trabajo
              // (y datos financieros en memoria) al pedo.
              if (puedeVerFinanzas) _panelFinanciero(),
              _tarjetaCategorias(esAdmin),
              _tarjetaRecurrentes(),
              _historial(),
            ],
          ),
        ),
      ),
    );
  }

  // ─── AppBar ────────────────────────────────────────────────────────────────

  /// Acciones de admin, portadas del modal: sobre un proveedor activo se edita
  /// o se desactiva; sobre uno desactivado la única acción es reactivarlo.
  ///
  /// La rama de "Reactivar" NO es opcional: esta ficha es el ÚNICO camino de la
  /// app para volver a activar un proveedor (se llega con "ver desactivados" en
  /// la pestaña). Si se perdiera acá, la reactivación quedaría sin puerta.
  List<Widget> _accionesAdmin() {
    if (!_proveedor.activo) {
      return [
        TextButton.icon(
          onPressed: _reactivarProveedor,
          icon: const Icon(Icons.restore, color: Colors.green),
          label: const Text('Reactivar', style: TextStyle(color: Colors.green)),
        ),
      ];
    }
    return [
      IconButton(
        tooltip: 'Editar',
        icon: const Icon(Icons.edit_outlined, color: InsumaColors.primaryBlue),
        // Mismo comportamiento que el modal: se cierra la ficha y el formulario
        // lo abre la pestaña de Proveedores, que es de quien es.
        onPressed: () => Navigator.pop(context, AccionFichaProveedor.editar),
      ),
      IconButton(
        tooltip: 'Desactivar',
        icon: const Icon(Icons.block, color: Colors.redAccent),
        onPressed: _confirmarDesactivarProveedor,
      ),
    ];
  }

  // ─── Secciones ─────────────────────────────────────────────────────────────

  /// Franja de "está desactivado". El modal no la tenía porque el botón
  /// "Reactivar" alcanzaba como pista, pero acá el cocinero no ve ese botón y
  /// se encontraría con toda la ficha en sólo lectura sin ninguna explicación.
  Widget _avisoDesactivado() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: InsumaColors.alertRed,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.block, size: 16, color: Colors.redAccent),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Proveedor desactivado. Se conserva todo su historial, pero no se '
              'puede editar ni cargarle pedidos nuevos.',
              style: TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// Datos de contacto, arrancando CERRADO: se consultan de vez en cuando y su
  /// lugar arriba de todo era lo que empujaba el saldo fuera de la pantalla.
  Widget _tarjetaInformacion() {
    final telefono = _proveedor.telefono ?? '';
    return _tarjeta(
      padding: EdgeInsets.zero,
      hijo: ExpansionTile(
        // Sin las líneas que ExpansionTile dibuja por defecto: la tarjeta ya
        // tiene su borde y quedarían dos bordes encimados.
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: const Text(
          'Información del proveedor',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        children: [
          _filaDato(
            Icons.category_outlined,
            'Rubro / Categoría',
            _proveedor.categoria ?? 'Varios',
          ),
          _filaDato(
            Icons.person_outline,
            'Contacto',
            (_proveedor.contacto?.trim().isNotEmpty ?? false)
                ? _proveedor.contacto!
                : 'No registrado',
          ),
          _filaDato(
            Icons.phone_outlined,
            'Teléfono',
            telefono.isNotEmpty ? telefono : 'No registrado',
          ),
          _filaDato(
            Icons.email_outlined,
            'Correo electrónico',
            _proveedor.email ?? 'No registrado',
          ),
          _filaDato(
            Icons.badge_outlined,
            'CUIT',
            _proveedor.cuit ?? 'No registrado',
          ),
          _filaDato(
            Icons.calendar_today_outlined,
            'Plazo de pago',
            _proveedor.plazoPago ?? 'Contado',
          ),
          // HU-047: contactar por WhatsApp, sólo si el teléfono da para armar el
          // link. El helper decide; acá no se valida nada.
          if (ValidadorDatos.urlWhatsapp(telefono) != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _contactarWhatsapp,
                icon: const Icon(
                  Icons.chat_bubble_outline,
                  color: Color(0xFF25D366),
                ),
                label: const Text(
                  'Contactar por WhatsApp',
                  style: TextStyle(
                    color: Color(0xFF25D366),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF25D366)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'Información de cobro',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          // #220: era una fila muerta que decía "Disponible próximamente".
          // Ahora muestra el dato real, y se copia de un toque: son valores que
          // nadie tipea a mano, y un dígito mal transcripto en un CBU es una
          // transferencia a otra persona.
          FilaDatoCopiable(
            icono: Icons.alternate_email,
            etiqueta: 'Alias',
            valor: _proveedor.aliasBancario,
          ),
          FilaDatoCopiable(
            icono: Icons.account_balance_outlined,
            etiqueta: 'CBU / CVU',
            valor: _proveedor.cbu,
          ),
        ],
      ),
    );
  }

  /// Panel financiero. La pantalla sólo resuelve cargando / error / dato: qué se
  /// muestra y qué se destaca lo decide el propio panel con lo que el servicio
  /// ya dejó calculado (`destacarSaldo`, `sinMovimientos`).
  Widget _panelFinanciero() {
    return FutureBuilder<ResumenFinancieroProveedor>(
      future: _pedirResumen(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return _errorFinanzas();
        // `null` mientras carga: es el contrato del panel.
        return PanelFinancieroProveedor(
          resumen: snapshot.data,
          puedeVerFinanzas: puedeVerFinanzas,
        );
      },
    );
  }

  /// Si el resumen falla no se muestra un cero: un saldo inventado en cero es
  /// peor que decir que no se pudo traer.
  Widget _errorFinanzas() {
    return _tarjeta(
      hijo: Row(
        children: [
          Icon(Icons.cloud_off, size: 20, color: Colors.grey[400]),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'No se pudo cargar el estado de cuenta.',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ),
          TextButton(
            // Tirar el Future guardado alcanza: el próximo build lo vuelve a
            // pedir por el `??=`.
            onPressed: () => setState(() => _resumen = null),
            child: const Text(
              'Reintentar',
              style: TextStyle(color: InsumaColors.primaryBlue, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// Insumos que suministra + alta de insumo, plegado para no empujar el
  /// historial fuera de la pantalla.
  ///
  /// El listado, los precios y las bajas son el MISMO widget que usa el
  /// formulario de insumo (HU-138): acá no hay ni una consulta propia.
  /// #262: qué CATEGORÍAS suministra el proveedor (reemplaza a la vieja lista de
  /// insumos). El admin las agrega/quita acá; el dato lo trae y persiste
  /// [ControladorProveedorCategorias]. Los insumos ya no cuelgan del proveedor:
  /// pertenecen a una categoría.
  Widget _tarjetaCategorias(bool esAdmin) {
    final soloLectura = !esAdmin || !_proveedor.activo;
    return _tarjeta(
      padding: EdgeInsets.zero,
      hijo: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        leading: const Icon(
          Icons.category_outlined,
          color: InsumaColors.primaryBlue,
        ),
        title: const Text(
          'Categorías que suministra',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        children: [
          Consumer<ControladorProveedorCategorias>(
            builder: (context, ctrl, _) {
              if (ctrl.cargando) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (ctrl.suministradas.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        soloLectura
                            ? 'Sin categorías asignadas.'
                            : 'Todavía no suministra ninguna categoría. Agregá '
                                  'las que correspondan.',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final c in ctrl.suministradas)
                          Chip(
                            label: Text(c.nombre),
                            labelStyle: const TextStyle(fontSize: 12),
                            backgroundColor: InsumaColors.backgroundLight,
                            side: BorderSide(
                              color: InsumaColors.cardBorderLight,
                            ),
                            onDeleted: soloLectura
                                ? null
                                : () => ctrl.desasignar(c.id),
                            deleteIconColor: Colors.redAccent,
                          ),
                      ],
                    ),
                  if (!soloLectura)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => _agregarCategoria(ctrl),
                        icon: const Icon(
                          Icons.add,
                          size: 18,
                          color: InsumaColors.primaryBlue,
                        ),
                        label: const Text(
                          'Agregar categoría',
                          style: TextStyle(
                            color: InsumaColors.primaryBlue,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// HU-013: entrada a los pedidos recurrentes de ESTE proveedor.
  ///
  /// Se muestra a todos los roles: el cocinero también tiene que poder ver qué
  /// entregas vienen. Quién puede crear o modificar lo decide la pantalla de
  /// destino.
  Widget _tarjetaRecurrentes() {
    return _tarjeta(
      padding: EdgeInsets.zero,
      hijo: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        leading: const Icon(
          Icons.event_repeat,
          color: InsumaColors.primaryBlue,
        ),
        title: const Text(
          'Pedidos recurrentes',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        subtitle: const Text(
          'Entregas fijas que se repiten solas',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        trailing: const Icon(Icons.chevron_right, size: 20, color: Colors.grey),
        // Ya no hace falta cerrar nada antes de navegar: la ficha es una
        // pantalla, así que al volver de recurrentes se vuelve acá.
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PantallaPedidosRecurrentes(
              negocioId: _proveedor.negocioId,
              proveedorId: _proveedor.id,
              proveedorNombre: _proveedor.nombre,
            ),
          ),
        ),
      ),
    );
  }

  /// Historial completo del proveedor. El widget filtra y lista; el detalle lo
  /// abre la pantalla, que es la que tiene el mixin (por eso el callback).
  ///
  /// Va SIN tarjeta ni encabezado propio: el bloque trae su título y sus
  /// tarjetas de pedido, y meterlo dentro de otra `Card` dejaría tarjetas
  /// adentro de una tarjeta.
  Widget _historial() {
    return HistorialProveedor(
      proveedorId: _proveedor.id,
      puedeVerFinanzas: puedeVerFinanzas,
      alAbrirDetalle: verDetallePedido,
    );
  }

  // ─── Piezas de presentación ────────────────────────────────────────────────

  /// Tarjeta de la casa: blanca, sin sombra, radio 16 y borde claro. Es la misma
  /// receta de `tarjeta_pedido.dart`, para que la ficha no desentone.
  Widget _tarjeta({
    required Widget hijo,
    EdgeInsets padding = const EdgeInsets.all(14),
  }) {
    return Card(
      color: Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: InsumaColors.cardBorderLight),
      ),
      child: Padding(padding: padding, child: hijo),
    );
  }

  /// Fila de dato del perfil (portada del modal).
  Widget _filaDato(IconData icono, String titulo, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icono, size: 18, color: Colors.grey[400]),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[400],
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  valor,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Acciones ──────────────────────────────────────────────────────────────

  /// #262: agrega una categoría a las que suministra el proveedor. Abre un
  /// selector con las categorías del negocio que todavía NO suministra; si no
  /// queda ninguna, avisa y ofrece ir al catálogo a crear una.
  Future<void> _agregarCategoria(ControladorProveedorCategorias ctrl) async {
    final disponibles = ctrl.disponibles;
    if (disponibles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No quedan categorías para agregar. Creá una nueva en '
            'Administración → Categorías.',
          ),
        ),
      );
      return;
    }
    final elegida = await showModalBottomSheet<Categoria>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Agregar categoría',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            for (final c in disponibles)
              ListTile(
                leading: const Icon(
                  Icons.category_outlined,
                  color: InsumaColors.primaryBlue,
                ),
                title: Text(c.nombre),
                onTap: () => Navigator.pop(context, c),
              ),
          ],
        ),
      ),
    );
    if (elegida != null) await ctrl.asignar(elegida.id);
  }

  /// Abre WhatsApp (wa.me) con el proveedor y un saludo genérico (HU-047).
  Future<void> _contactarWhatsapp() async {
    final mensaje =
        'Hola ${_proveedor.nombre}, te contacto para coordinar un pedido.';
    final url = ValidadorDatos.urlWhatsapp(
      _proveedor.telefono ?? '',
      mensaje: mensaje,
    );
    if (url == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // #220: la apertura del enlace vive en `EnlacesExternos`. Estaba escrita
    // igual acá, en el resumen del pedido y en el wizard de recurrentes.
    if (!await EnlacesExternos.abrir(url)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  /// Confirma y ejecuta la baja lógica del proveedor (HU-008).
  ///
  /// Si tiene operaciones vivas (pedidos abiertos, facturas impagas o saldo) lo
  /// advierte ANTES de pedir confirmación: quién tiene qué colgando lo evalúa el
  /// controlador, la pantalla sólo lo redacta.
  Future<void> _confirmarDesactivarProveedor() async {
    final ctrl = context.read<ControladorProveedores>();
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    final vinculos = await ctrl.evaluarVinculos(_proveedor.id);
    if (!mounted) return;

    final detalles = <String>[
      if (vinculos.pedidosAbiertos > 0)
        '• ${vinculos.pedidosAbiertos} pedido(s) abierto(s)',
      if (vinculos.facturasPendientes > 0)
        '• ${vinculos.facturasPendientes} factura(s) pendiente(s)',
      // HU-060: al que no ve finanzas tampoco se le cuenta el saldo acá.
      if (puedeVerFinanzas && vinculos.saldo.abs() > 0.001)
        '• Saldo de cuenta corriente: \$${vinculos.saldo.toStringAsFixed(2)}',
    ];

    final mensaje = StringBuffer(
      '¿Desactivar al proveedor "${_proveedor.nombre}"? Se conserva todo su historial y dejará de aparecer al crear nuevos pedidos. Sus insumos quedarán desvinculados.',
    );
    if (detalles.isNotEmpty) {
      mensaje.write('\n\n⚠️ Tiene operaciones vivas:\n');
      mensaje.write(detalles.join('\n'));
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Desactivar Proveedor',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        content: Text(mensaje.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirmar == true) {
      await ctrl.desactivarProveedor(
        proveedor: _proveedor,
        // Al desactivar se vuelve al listado: quedarse en la ficha mostraría un
        // proveedor activo que ya no lo está (el objeto es una foto del push).
        alCompletar: () => navigator.pop(),
        mostrarError: (err) {
          scaffoldMessenger.showSnackBar(
            SnackBar(content: Text(err), backgroundColor: Colors.redAccent),
          );
        },
      );
    }
  }

  /// Reactiva un proveedor desactivado (HU-008). Vuelve al listado por el mismo
  /// motivo que la baja: la ficha quedaría mostrando datos viejos.
  Future<void> _reactivarProveedor() async {
    final ctrl = context.read<ControladorProveedores>();
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    await ctrl.reactivarProveedor(
      proveedor: _proveedor,
      alCompletar: () => navigator.pop(),
      mostrarError: (err) {
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(err), backgroundColor: Colors.redAccent),
        );
      },
    );
  }
}
