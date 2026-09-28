import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/database.dart';
import '../../utils/estados_pedido.dart';
import '../../controllers/controlador_recibir.dart';
import '../../controllers/controlador_dashboard.dart';
import '../../controllers/controlador_adjuntos.dart';
import '../dashboard/navegacion_dashboard.dart';
import '../../services/servicio_permisos.dart';
import '../../services/servicio_motivos_recepcion.dart';
import '../../services/servicio_precios.dart';
import '../../services/servicio_trazabilidad_pedido.dart';
import '../../utils/trazabilidad_pedido.dart';
import '../../services/servicio_adjuntos.dart';
import '../../utils/adjuntos/selector_archivos_file_picker.dart';
import '../../utils/enlaces_externos.dart';
import '../../utils/acciones_tarjeta_pedido.dart';
import 'widgets/bloque_trazabilidad.dart';
import 'widgets/detalle_recepciones_pedido.dart';
import 'widgets/menu_pedido.dart';
import 'widgets/reprogramar_entrega_modal.dart';
import 'widgets/formulario_pedido_modal.dart';
import 'widgets/verificacion_recepcion_modal.dart';
import 'resumen_pedido_screen.dart';

/// Acciones de negocio compartidas por las pantallas del ciclo Pedido/Recepción
/// (Pedidos, Recepciones, Historial). Centraliza los diálogos y la navegación que
/// antes vivían en `PestanaRecibir`, para que las tres vistas las reutilicen sin
/// duplicar código (DRY). Toda la lógica sigue en `ControladorRecibir`; acá solo
/// hay orquestación de UI.
mixin AccionesPedidoMixin<T extends StatefulWidget> on State<T> {
  ControladorRecibir get ctrlRecibir =>
      Provider.of<ControladorRecibir>(context, listen: false);

  /// HU-060: el cocinero no ve costos/precios. usuarioRol respeta la elevación por PIN (HU-043).
  bool get puedeVerFinanzas =>
      Permisos.puede(ctrlRecibir.sesion.usuarioRol, Permiso.verFinanzas);

  // ─── Alta / edición de pedidos ──────────────────────────────────────────────

  /// Abre el formulario para crear un pedido o editar un borrador. Si el pedido se
  /// ENVÍA, el modal devuelve el [Pedido] persistido y se abre el Resumen (WhatsApp).
  /// Devuelve ese [Pedido] enviado (o `null` si se guardó como borrador / se canceló).
  Future<Pedido?> abrirFormularioPedido({Pedido? pedidoExistente}) async {
    final ctrl = ctrlRecibir;
    final creado = await showModalBottomSheet<Pedido>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return FormularioPedidoModal(
          negocioId: ctrl.negocioId,
          pedidoExistente: pedidoExistente,
          nombreOperario: ctrl.usuarioNombre,
        );
      },
    );
    if (creado != null && mounted) {
      await abrirResumen(creado);
    }
    return creado;
  }

  /// Abre el Resumen del pedido (HU-063): detalle + mensaje editable para el
  /// proveedor por WhatsApp (sin precios para quien no ve finanzas — HU-060).
  Future<void> abrirResumen(Pedido pedido) async {
    final ctrl = ctrlRecibir;
    final contacto = await ctrl.contactoDeProveedor(pedido.proveedorId);
    final items = (jsonDecode(pedido.items) as List)
        .cast<Map<String, dynamic>>();
    if (!mounted) return;
    final enviado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ResumenPedidoScreen(
          proveedorNombre: pedido.proveedorNombre,
          items: items,
          total: pedido.total ?? 0.0,
          telefonoProveedor: contacto.telefono,
          emailProveedor: contacto.email, // #235
          puedeVerFinanzas: puedeVerFinanzas,
          servicio: ctrl.envio,
          fechaRecepcionSolicitada: pedido.fechaRecepcionSolicitada, // HU-142
        ),
      ),
    );
    // #253: sólo tras un envío EXITOSO (el Resumen devuelve true; un back normal
    // devuelve null) se lleva al usuario a Pedidos › Activos. Como el dashboard
    // recrea la pantalla al cambiar de índice, saltar a Pedidos desde otra
    // pestaña ya deja el sub-tab en Activos (su default). Si el envío se hizo
    // estando YA en Pedidos, el índice no cambia y el sub-tab se conserva.
    if (enviado == true && mounted) {
      final messenger = ScaffoldMessenger.of(context);
      final indicePedidos = pestanasVisibles(
        puedeVerFinanzas: puedeVerFinanzas,
      ).indexOf(PestanaDashboard.pedidos);
      context.read<ControladorDashboard>().actualizarIndice(indicePedidos);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Pedido enviado.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// #256: abre el chat de WhatsApp con el proveedor, SIN mensaje precargado.
  ///
  /// El icono de mensaje de las tarjetas abría el Resumen (que reenvía el
  /// pedido); el PO pidió que sea un contacto directo con el proveedor, con el
  /// chat en blanco. La construcción de la URL vive en [ServicioEnvioPedido];
  /// acá solo se resuelve el contacto y se abre el enlace.
  Future<void> abrirChatWhatsApp(Pedido ped) async {
    final messenger = ScaffoldMessenger.of(context);
    final contacto = await ctrlRecibir.contactoDeProveedor(ped.proveedorId);
    final url = ctrlRecibir.envio.construirUrlChatVacio(
      telefonoProveedor: contacto.telefono,
    );
    if (url == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'El proveedor no tiene un teléfono válido para WhatsApp.',
          ),
        ),
      );
      return;
    }
    if (!await EnlacesExternos.abrir(url)) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir WhatsApp.')),
      );
    }
  }

  // ─── Confirmación / cancelación ─────────────────────────────────────────────

  /// Marca el pedido como confirmado por el proveedor (HU-064): enviado → en_espera
  /// (pasa a Recepciones).
  Future<void> confirmarPedido(Pedido ped) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await ctrlRecibir.confirmarPedido(ped);
    if (!mounted) return;
    messenger.showSnackBar(
      error == null
          ? const SnackBar(
              content: Text(
                'Pedido confirmado: ya podés recibirlo en «Recepciones».',
              ),
              backgroundColor: Colors.green,
            )
          : SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
    );
  }

  /// Edita un pedido ya ENVIADO (HU-141): el proveedor todavía no lo confirmó,
  /// así que el contenido se puede corregir y re-enviar. Desde en_espera en
  /// adelante el servicio lo rechaza (la matriz no lo permite).
  Future<void> editarPedidoEnviado(Pedido ped) =>
      abrirFormularioPedido(pedidoExistente: ped);

  /// Cancela un pedido (previa confirmación).
  Future<void> cancelarPedido(Pedido pedido) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          'Cancelar Pedido',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '¿Está seguro de que desea cancelar el pedido a "${pedido.proveedorNombre}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Cancelar Pedido'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmar == true) {
      final messenger = ScaffoldMessenger.of(context);
      final error = await ctrlRecibir.cancelarPedido(pedido);
      if (!mounted || error == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
      );
    }
  }

  /// Mueve la fecha de entrega de un pedido, o se la quita (#269).
  ///
  /// La advertencia de quitar la fecha la muestra el diálogo, no acá: es parte
  /// de la decisión, tiene que estar a la vista ANTES de confirmar y no después.
  Future<void> reprogramarPedido(Pedido pedido) async {
    final (eligio, fecha) = await pedirNuevaFechaEntrega(context, pedido);
    if (!mounted || !eligio) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await ctrlRecibir.reprogramarPedido(pedido, fecha);
    if (!mounted) return;
    messenger.showSnackBar(
      error == null
          ? SnackBar(
              content: Text(
                fecha == null
                    ? 'La entrega quedó sin fecha.'
                    : 'Entrega reprogramada.',
              ),
            )
          // El motivo llega del Service: estado que ya no admite el cambio,
          // fecha fuera de la ventana, o choque con otra entrega de la misma
          // serie recurrente.
          : SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
    );
  }

  /// El menú de tres puntos de una tarjeta, o `null` si este pedido no admite
  /// ninguna acción (#269).
  ///
  /// Devolver `null` —y no un menú vacío— es lo que hace que la tarjeta no
  /// dibuje los tres puntos: un menú que se abre sin nada adentro es peor que
  /// no tenerlo.
  ///
  /// El gate del superadministrador sale de `sesion.esSuperAdmin` y NUNCA de
  /// `esAdmin`: ese getter compara contra el literal "admin" y al
  /// superadministrador le da `false`, así que lo dejaría pasar justo donde no
  /// puede escribir. La regla vive en `opcionesDeMenu`, que es puro y testeado.
  Widget? menuDePedido(Pedido pedido) {
    final opciones = opcionesDeMenu(
      pedido.estado,
      esSuperAdmin: ctrlRecibir.sesion.esSuperAdmin,
    );
    if (opciones.isEmpty) return null;
    return MenuPedido(
      opciones: opciones,
      alElegir: (accion) {
        switch (accion) {
          case AccionTarjeta.reprogramar:
            reprogramarPedido(pedido);
          case AccionTarjeta.cancelar:
            cancelarPedido(pedido);
        }
      },
    );
  }

  /// Elimina definitivamente un borrador local (HU-141: sólo borradores; si la
  /// transición es inválida, el servicio lo rechaza y se muestra el motivo).
  Future<void> eliminarPedido(Pedido pedido) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await ctrlRecibir.eliminarPedido(pedido);
    if (!mounted || error == null) return;
    messenger.showSnackBar(
      SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
    );
  }

  // ─── Recepción física ───────────────────────────────────────────────────────

  /// Abre el modal de verificación con DESENLACE por ítem (HU-064): Correcto /
  /// Diferencias / Rechazado + motivo/comentario, y adjuntar remito (HU-066). La
  /// validación y la persistencia las hace el controlador vía `onConfirmar`.
  Future<void> abrirVerificacionRecepcion(Pedido pedido) async {
    final ctrl = ctrlRecibir;
    final messenger = ScaffoldMessenger.of(context);
    final servicioMotivos = Provider.of<ServicioMotivosRecepcion>(
      context,
      listen: false,
    );
    final servicioAdjuntos = Provider.of<ServicioAdjuntos>(
      context,
      listen: false,
    );
    final motivos = await servicioMotivos.listar(ctrl.negocioId);
    if (!mounted) return;
    final ctrlAdjuntos = ControladorAdjuntos(
      const SelectorArchivosFilePicker(),
      servicioAdjuntos,
    );
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => VerificacionRecepcionModal(
        pedido: pedido,
        motivos: motivos,
        controladorAdjuntos: ctrlAdjuntos,
        puedeVerFinanzas: puedeVerFinanzas,
        onConfirmar:
            (
              items,
              total, {
              double? totalManual,
              String? nota,
              required bool pagarEfectivo,
            }) async {
              // Discrepancias (alertas) por diferencia de cantidad pedida vs recibida.
              final discrepancias = <Map<String, dynamic>>[];
              for (final it in items) {
                final pedida = it['cantidadPedida'] as double;
                final recibida = it['cantidadRecibida'] as double;
                if (pedida != recibida) {
                  discrepancias.add({
                    'insumoId': it['insumoId'],
                    'nombre': it['nombre'],
                    'pedida': pedida,
                    'recibida': recibida,
                  });
                }
              }
              // HU-145 (revisión): validar ANTES del diálogo de decisión — que el
              // usuario no decida sobre una recepción que después no pasa la
              // validación (y le repregunte al reintentar).
              final errorValidacion = ctrl.validarRecepcion(
                items,
                ctrlAdjuntos,
              );
              if (errorValidacion != null) return errorValidacion;

              // HU-145: ante faltantes, el cierre pregunta EXPLÍCITAMENTE si el
              // faltante genera parcial o si el pedido se cierra sin parcial (la
              // diferencia queda igual como observación del ítem).
              var cerrarSinParcial = false;
              if (await ctrl.recepcionQuedariaParcial(pedido, items)) {
                if (!mounted) return 'Recepción no registrada.';
                {
                  // #229: acá había una rama especial para el efectivo (RN-014:
                  // "cierra FACTURADO, no existe Parciales"). Se cayó con el
                  // rediseño: el efectivo ya no salta de estado al recibir y
                  // pasa por Procesar como todos, así que un faltante se decide
                  // igual que en cualquier pedido.
                  final decision = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text(
                        'Quedó mercadería sin recibir',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      content: const Text(
                        '¿Qué hacemos con el faltante?\n\n'
                        '• Registrar parcial: el pedido queda en «Parciales» para re-pedir o reclamar.\n'
                        '• Cerrar sin parcial: el pedido pasa al Historial; la diferencia queda '
                        'registrada como observación de cada ítem.',
                        style: TextStyle(fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('Cerrar sin parcial'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('Registrar parcial'),
                        ),
                      ],
                    ),
                  );
                  if (decision == null) {
                    // Cerró el diálogo sin decidir: no se registra nada.
                    return 'Recepción no registrada: elegí qué hacer con el faltante.';
                  }
                  cerrarSinParcial = decision;
                }
              }
              final error = await ctrl.registrarRecepcionFisica(
                pedido: pedido,
                itemsVerificados: items,
                alertas: discrepancias,
                // #229: lo que quedó decidido EN el modal, no lo que traía el
                // pedido — es lo que hace que destildar el efectivo persista.
                pagarEfectivo: pagarEfectivo,
                adjuntos: ctrlAdjuntos,
                totalManual: totalManual,
                cerrarSinParcial: cerrarSinParcial,
                nota: nota,
              );
              if (error == null) {
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      'Recepción registrada. Operario: ${ctrl.usuarioNombre}',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              }
              return error;
            },
      ),
    );
    ctrlAdjuntos.dispose();
  }

  // ─── Parciales ──────────────────────────────────────────────────────────────

  /// Re-pide la mercadería FALTANTE de un pedido parcial (HU-064, punto 4): crea un
  /// borrador con el faltante, lo abre en el formulario para ajustar cantidades/ítems
  /// y, al ENVIARLO, pasa a «Activos» (esperando confirmación) y el parcial original
  /// queda resuelto en el Historial.
  Future<void> repedirParcial(Pedido ped) async {
    final ctrl = ctrlRecibir;
    final messenger = ScaffoldMessenger.of(context);
    final borrador = await ctrl.crearBorradorRepedidoParcial(ped);
    if (!mounted) return;
    if (borrador == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Este pedido no tiene faltantes.')),
      );
      return;
    }
    final enviado = await abrirFormularioPedido(pedidoExistente: borrador);
    // Solo cerramos el parcial si el re-pedido efectivamente se envió.
    if (enviado != null) {
      final error = await ctrl.cerrarParcialPorRepedido(ped);
      if (!mounted) return;
      messenger.showSnackBar(
        error == null
            ? const SnackBar(
                content: Text(
                  'Re-pedido enviado. Lo ves en «Pedidos › Activos».',
                ),
                backgroundColor: Colors.green,
              )
            : SnackBar(
                content: Text(
                  'Re-pedido enviado, pero el parcial no se pudo cerrar: $error',
                ),
                backgroundColor: Colors.redAccent,
              ),
      );
    }
  }

  /// Descarta un parcial que no se va a reclamar (HU-145): el pedido pasa al
  /// Historial como `parcial_cerrado`. La recepción y su evidencia se conservan.
  Future<void> descartarParcial(Pedido ped) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text(
          'Descartar parcial',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '¿Descartar el parcial de "${ped.proveedorNombre}"? El pedido pasa al '
          'Historial y el faltante no se reclama. La recepción registrada y su '
          'evidencia (motivos, comentarios, remitos) se conservan.\n\n'
          'Si habías creado un re-pedido del faltante y no lo enviaste, quedó '
          'en «Borradores»: revisalo y eliminalo si ya no corresponde.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Volver'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (!mounted || confirmar != true) return;
    final messenger = ScaffoldMessenger.of(context);
    final error = await ctrlRecibir.descartarParcial(ped);
    if (!mounted) return;
    messenger.showSnackBar(
      error == null
          ? const SnackBar(
              content: Text('Parcial descartado: el pedido pasó al Historial.'),
              backgroundColor: Colors.green,
            )
          : SnackBar(content: Text(error), backgroundColor: Colors.redAccent),
    );
  }

  // ─── Historial ──────────────────────────────────────────────────────────────

  /// Repite un pedido (HU-012): crea un NUEVO borrador con los mismos ítems, usando
  /// el catálogo/precios ACTUALES. Muestra un resumen con cambios de precio.
  Future<void> repetirPedido(Pedido pedido) async {
    final ctrl = ctrlRecibir;
    final resultado = await ctrl.repetirPedido(pedido);
    if (!mounted) return;
    final lineas = <String>[
      'Se creó un nuevo borrador con los ítems del pedido. Lo ves en la solapa "Borradores".',
    ];
    if (resultado.omitidos.isNotEmpty) {
      lineas.add(
        '\nNo se copiaron (insumos desactivados): ${resultado.omitidos.join(', ')}.',
      );
    }
    if (puedeVerFinanzas && resultado.cambios.isNotEmpty) {
      lineas.add('\nCambios de precio desde el pedido anterior:');
      for (final c in resultado.cambios) {
        lineas.add(
          '• ${c.nombre}: \$${c.anterior.toStringAsFixed(2)} → \$${c.actual.toStringAsFixed(2)}',
        );
      }
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Pedido repetido',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        content: Text(
          lineas.join('\n'),
          style: const TextStyle(fontSize: 13, color: Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  /// Guard de reentrada de [verDetallePedido]: la carga previa es async y sin
  /// esto un doble tap abriría dos sheets apilados.
  bool _abriendoDetalle = false;

  /// Muestra el detalle de un pedido (ítems pedidos/recibidos y total), con la
  /// sección "Recepciones" (HU-146): número, fecha, desenlace y nota de cada
  /// evento. Las recepciones se cargan ANTES de abrir el sheet.
  Future<void> verDetallePedido(Pedido pedido) async {
    if (_abriendoDetalle) return;
    _abriendoDetalle = true;
    // #242: la autoridad del costo real se captura ANTES del primer await
    // (leer el context tras un gap async es el lint de siempre). El cocinero
    // ni consulta: no ve importes (HU-060).
    final precios = puedeVerFinanzas ? context.read<ServicioPrecios>() : null;
    // #273: sólo se pide la trazabilidad si este rol la puede ver. Con
    // `Permisos.puede` y NUNCA con `esAdmin`, que compara contra el literal
    // "admin" y dejaría afuera al superadmin —que lee todo por diseño—.
    final trazador =
        Permisos.puede(ctrlRecibir.sesion.usuarioRol, Permiso.verTrazabilidad)
        ? context.read<ServicioTrazabilidadPedido>()
        : null;
    final List<Recepcion> recepciones;
    final Map<String, double> costosReales;
    try {
      recepciones = await ctrlRecibir.recepcionesDePedido(pedido);
      costosReales = precios == null
          ? const {}
          : await precios.costosRealesDelPedido(pedido.id);
    } catch (_) {
      _abriendoDetalle = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo cargar el detalle. Intentá de nuevo.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    // #273: try APARTE, después del que carga lo principal. Hasta acá un solo
    // fallo abortaba el sheet ENTERO —el usuario se quedaba sin ver los ítems ni
    // los costos por culpa de un bloque secundario—. Ahora el detalle se abre
    // igual y sólo este bloque avisa que no se pudo.
    List<PasoTrazabilidad>? trazabilidad;
    var falloTrazabilidad = false;
    if (trazador != null) {
      try {
        trazabilidad = await trazador.de(pedido);
      } catch (_) {
        falloTrazabilidad = true;
      }
    }
    _abriendoDetalle = false;
    if (!mounted) return;
    final itemsList = jsonDecode(pedido.items) as List<dynamic>;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                'Detalle: ${pedido.proveedorNombre}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                // #273: acá esta línea terminaba en "· Por:" seguido del
                // `recepcionadoPor`, o sea el UUID CRUDO del recepcionador —no su nombre—, se
                // mostraba incluso en borradores (donde no hay recepción) y
                // guardaba sólo al ÚLTIMO receptor de un pedido con varias
                // recepciones parciales. Lo reemplaza el bloque de trazabilidad,
                // que dice quién hizo CADA paso y con nombre.
                'Estado: ${EstadosPedido.etiqueta(pedido.estado)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const Divider(height: 24),
              const Text(
                'Items',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 250),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: itemsList.length,
                  itemBuilder: (context, idx) {
                    final item = itemsList[idx];
                    final cantPedida = item['cantidadPedida'] ?? 0.0;
                    final cantRecibida = item['cantidadRecibida'] ?? cantPedida;
                    // #242: manda el costo REAL cargado al procesar; la
                    // estimación de al crear el pedido solo aparece si aún no
                    // hay renglón procesado, y ROTULADA — presentarla como si
                    // fuera el costo real era exactamente el reporte del PO.
                    final real = costosReales[item['insumoId']];
                    final precio = real ?? (item['precioUnitario'] ?? 0.0);
                    final esEstimado = real == null;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        (item['nombre'] as String?) ?? 'Insumo',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      subtitle: Text(
                        'Cantidad Recibida: $cantRecibida ${item['unidad']} (Pedido: $cantPedida)',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: puedeVerFinanzas
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '\$${(cantRecibida * precio).toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (esEstimado)
                                  const Text(
                                    'estimado',
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.grey,
                                    ),
                                  ),
                              ],
                            )
                          : null,
                    );
                  },
                ),
              ),
              if (recepciones.isNotEmpty) ...[
                const Divider(height: 24),
                DetalleRecepcionesPedido(recepciones: recepciones),
              ],
              // #273: al final y detrás de un Divider. Es contexto, no la
              // información principal del detalle —que son los ítems y sus
              // costos— y no tiene por qué empujarlos hacia abajo.
              if (trazabilidad != null) ...[
                const Divider(height: 24),
                BloqueTrazabilidad(pasos: trazabilidad),
              ] else if (falloTrazabilidad) ...[
                const Divider(height: 24),
                const TrazabilidadNoDisponible(),
              ],
              if (puedeVerFinanzas) ...[
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Total Final: \$${(pedido.total ?? 0.0).toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
